// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#include <vector>
#include <atomic>
#include <cmath>
#include <mutex>
#import "FrameRenderer.mm"

@interface DMVideoDecoder : NSObject {
    NSData *_sps, *_pps;
    CMVideoFormatDescriptionRef _format;
    VTDecompressionSessionRef _decoder;
}
@property(copy) void (^onFrame)(CVPixelBufferRef);
@property(copy) void (^onError)(NSString *);
- (void)consume:(const uint8_t *)bytes length:(size_t)length;
- (void)reset;
@end

static void DMDecoded(void *context, void *, OSStatus status, VTDecodeInfoFlags,
                      CVImageBufferRef image, CMTime, CMTime) {
    DMVideoDecoder *decoder = (__bridge DMVideoDecoder *)context;
    if (!status && image && decoder.onFrame) decoder.onFrame(image);
}

@implementation DMVideoDecoder
- (void)reset {
    if (_decoder) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
        VTDecompressionSessionInvalidate(_decoder);
        CFRelease(_decoder); _decoder = nullptr;
    }
    if (_format) { CFRelease(_format); _format = nullptr; }
    _sps = nil; _pps = nil;
}
- (void)dealloc { [self reset]; }
- (void)consume:(const uint8_t *)bytes length:(size_t)length {
    if (!bytes || length < 5 || length > 32 * 1024 * 1024) return;
    std::vector<std::pair<size_t, size_t>> starts;
    for (size_t i = 0; i + 3 <= length;) {
        size_t prefix = 0;
        if (i + 4 <= length && !bytes[i] && !bytes[i+1] && !bytes[i+2] && bytes[i+3] == 1) prefix = 4;
        else if (!bytes[i] && !bytes[i+1] && bytes[i+2] == 1) prefix = 3;
        if (prefix) { starts.emplace_back(i, prefix); i += prefix; } else ++i;
    }
    if (starts.empty() || starts[0].first != 0) return;
    NSMutableData *avcc = [NSMutableData data];
    bool changed = false, hasSlice = false;
    for (size_t n = 0; n < starts.size(); ++n) {
        size_t start = starts[n].first + starts[n].second;
        size_t end = n + 1 < starts.size() ? starts[n+1].first : length;
        if (end <= start || end - start > UINT32_MAX) continue;
        uint8_t type = bytes[start] & 31;
        if (bytes[start] & 0x80) return;
        if (type == 7 || type == 8) {
            NSData *param = [NSData dataWithBytes:bytes+start length:end-start];
            NSData *old = type == 7 ? _sps : _pps;
            changed |= ![param isEqualToData:old];
            if (type == 7) _sps = param; else _pps = param;
        } else {
            hasSlice |= type >= 1 && type <= 5;
            uint32_t size = CFSwapInt32HostToBig((uint32_t)(end-start));
            [avcc appendBytes:&size length:4];
            [avcc appendBytes:bytes+start length:end-start];
        }
    }
    if ((changed || !_decoder) && _sps && _pps) {
        const uint8_t *params[] = {(const uint8_t *)_sps.bytes, (const uint8_t *)_pps.bytes};
        size_t sizes[] = {_sps.length, _pps.length};
        CMVideoFormatDescriptionRef format = nullptr;
        OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, 2, params, sizes, 4, &format);
        if (status) return;
        if (_decoder) {
            VTDecompressionSessionWaitForAsynchronousFrames(_decoder);
            VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); _decoder = nullptr;
        }
        if (_format) CFRelease(_format);
        _format = format;
        VTDecompressionOutputCallbackRecord callback = {DMDecoded, (__bridge void *)self};
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        status = VTDecompressionSessionCreate(kCFAllocatorDefault, format, nullptr,
            (__bridge CFDictionaryRef)attributes, &callback, &_decoder);
        if (status) {
            if (self.onError) self.onError([NSString stringWithFormat:@"视频解码器启动失败（%d）", (int)status]);
            return;
        }
        VTSessionSetProperty(_decoder, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    }
    if (!_decoder || !hasSlice || !avcc.length) return;
    CMBlockBufferRef block = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
        avcc.length, kCFAllocatorDefault, nullptr, 0, avcc.length, 0, &block);
    if (status) return;
    CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    size_t sampleSize = avcc.length;
    CMSampleBufferRef sample = nullptr;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1,
        0, nullptr, 1, &sampleSize, &sample);
    CFRelease(block);
    if (status) return;
    status = VTDecompressionSessionDecodeFrame(_decoder, sample, 0, nullptr, nullptr);
    CFRelease(sample);
    if (status && self.onError)
        self.onError([NSString stringWithFormat:@"视频解码失败（%d），请重新连接", (int)status]);
}
@end

@interface DMVideoView : NSView {
    CGImageRef _image;
}
@property(strong) DMFramePresenter *presenter;
@property(copy) void (^onFirstFrame)(size_t, size_t);
@property(copy) void (^onError)(NSString *);
@property BOOL showingFrame;
- (void)presentPixel:(CVPixelBufferRef)pixel;
- (void)clear;
@end

@implementation DMVideoView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy=NSViewLayerContentsRedrawOnSetNeedsDisplay;
        self.presenter=[[DMFramePresenter alloc] init];
        __weak DMVideoView *weakSelf=self;
        self.presenter.onImage=^(CGImageRef image) {
            DMVideoView *view=weakSelf; if(!view) return;
            CGImageRef next=CGImageRetain(image);
            if(view->_image) CGImageRelease(view->_image); view->_image=next;
            [view setNeedsDisplay:YES];
            if(!view.showingFrame) {
                view.showingFrame=YES;
                if(view.onFirstFrame) view.onFirstFrame(CGImageGetWidth(image),CGImageGetHeight(image));
            }
        };
        self.presenter.onError=^(NSString *error) { if(weakSelf.onError) weakSelf.onError(error); };
    }
    return self;
}
- (BOOL)isOpaque { return YES; }
- (void)layout { [super layout]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)rect { DMDrawFrame(NSGraphicsContext.currentContext.CGContext,self.bounds,_image); }
- (void)presentPixel:(CVPixelBufferRef)pixel {
    [self.presenter presentPixel:pixel];
}
- (void)clear {
    [self.presenter clear];
    if(_image) { CGImageRelease(_image); _image=nullptr; }
    self.showingFrame=NO; [self setNeedsDisplay:YES];
}
- (void)dealloc { if(_image) CGImageRelease(_image); }
@end

@interface DMAudioPlayer : NSObject {
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;
    AVAudioFormat *_format;
    std::atomic<int> _queued;
    std::atomic<bool> _muted;
    std::atomic<uint64_t> _generation;
}
- (void)playPCM:(const int16_t *)samples frames:(uint32_t)frames;
- (void)setMuted:(BOOL)muted;
- (void)stop;
@end

@implementation DMAudioPlayer
- (void)setMuted:(BOOL)muted { _muted.store(muted); }
- (void)playPCM:(const int16_t *)samples frames:(uint32_t)frames {
    if (!frames || !samples || _muted.load() || _queued.load() > 12) return;
    if (!_engine) {
        _engine = [[AVAudioEngine alloc] init];
        _player = [[AVAudioPlayerNode alloc] init];
        _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        [_engine attachNode:_player]; [_engine connect:_player to:_engine.mainMixerNode format:_format];
        NSError *error = nil;
        if (![_engine startAndReturnError:&error]) { _engine = nil; _player = nil; return; }
        [_player play];
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:frames];
    buffer.frameLength = frames;
    float *const *planes = buffer.floatChannelData;
    for (uint32_t i = 0; i < frames; ++i) {
        planes[0][i] = samples[2*i] / 32768.0f;
        planes[1][i] = samples[2*i+1] / 32768.0f;
    }
    ++_queued;
    uint64_t generation = _generation.load();
    [_player scheduleBuffer:buffer completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
        completionHandler:^(AVAudioPlayerNodeCompletionCallbackType) {
            if (self->_generation.load() == generation) --self->_queued;
        }];
}
- (void)stop {
    ++_generation; [_player stop]; [_engine stop];
    _player = nil; _engine = nil; _queued.store(0);
}
- (void)dealloc { [self stop]; }
@end

struct DMAudioInput {
    const uint8_t *bytes; UInt32 length; bool consumed;
    AudioStreamPacketDescription packet;
};
static OSStatus DMAudioSupply(AudioConverterRef, UInt32 *packets, AudioBufferList *buffers,
                              AudioStreamPacketDescription **descriptions, void *context) {
    auto *input = (DMAudioInput *)context;
    if (input->consumed) { *packets = 0; return 0; }
    input->consumed = true; *packets = 1;
    buffers->mNumberBuffers = 1;
    buffers->mBuffers[0] = {2, input->length, const_cast<uint8_t *>(input->bytes)};
    input->packet = {0, 0, input->length};
    if (descriptions) *descriptions = &input->packet;
    return 0;
}

@interface DMAudioDecoder : NSObject {
    AudioConverterRef _converter;
    uint8_t _compression;
    bool _reportedError;
}
@property(strong) DMAudioPlayer *player;
@property(copy) void (^onError)(NSString *);
- (BOOL)configure:(uint8_t)compression frames:(uint32_t)frames;
- (void)consume:(const uint8_t *)bytes length:(uint32_t)length;
- (void)reset;
@end

@implementation DMAudioDecoder
- (BOOL)configure:(uint8_t)compression frames:(uint32_t)frames {
    [self reset]; _compression = compression;
    if (compression == 1) return YES;
    AudioStreamBasicDescription source = {}, dest = {};
    source.mSampleRate = 44100; source.mChannelsPerFrame = 2;
    source.mFramesPerPacket = frames ?: (compression == 8 ? 480 : compression == 2 ? 352 : 1024);
    source.mFormatID = compression == 8 ? kAudioFormatMPEG4AAC_ELD :
        compression == 2 ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC;
    if (compression == 2) source.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData;
    dest.mSampleRate = 44100; dest.mFormatID = kAudioFormatLinearPCM;
    dest.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    dest.mBitsPerChannel = 16; dest.mChannelsPerFrame = 2;
    dest.mFramesPerPacket = 1; dest.mBytesPerPacket = dest.mBytesPerFrame = 4;
    OSStatus status = AudioConverterNew(&source, &dest, &_converter);
    if (status) { fprintf(stderr, "Audio decoder %u unavailable: %d\n", compression, (int)status); return NO; }
    const uint8_t alac[] = {0,0,1,0x60,0,0x10,0x28,0x0a,0x0e,2,0,0xff,0,0,0,0,0,0,0,0,0,0,0xac,0x44};
    const uint8_t eld[] = {0xf8,0xe8,0x50,0};
    const uint8_t lc[] = {0x12,0x10};
    const void *cookie = compression == 2 ? (const void *)alac : compression == 8 ? (const void *)eld : lc;
    UInt32 cookieSize = compression == 2 ? sizeof(alac) : compression == 8 ? sizeof(eld) : sizeof(lc);
    // Core Audio accepts the codec-specific configuration as its decompression cookie.
    AudioConverterSetProperty(_converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie);
    return YES;
}
- (void)consume:(const uint8_t *)bytes length:(uint32_t)length {
    if (!length || !bytes) return;
    if (_compression == 1) { [self.player playPCM:(const int16_t *)bytes frames:length/4]; return; }
    if (!_converter) return;
    DMAudioInput input = {bytes, length, false, {}};
    int16_t pcm[8192];
    AudioBufferList output = {1, {{2, sizeof(pcm), pcm}}};
    UInt32 frames = 4096;
    OSStatus status = AudioConverterFillComplexBuffer(_converter, DMAudioSupply, &input, &frames, &output, nullptr);
    if (!status && frames) [self.player playPCM:pcm frames:frames];
    else if (status && !_reportedError && self.onError) {
        _reportedError = true; self.onError(@"声音暂不可用，画面仍可继续显示");
    }
}
- (void)reset {
    if (_converter) { AudioConverterDispose(_converter); _converter = nullptr; }
    [self.player stop]; _compression = 0; _reportedError = false;
}
- (void)dealloc { [self reset]; }
@end
