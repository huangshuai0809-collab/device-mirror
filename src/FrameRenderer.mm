// SPDX-License-Identifier: GPL-3.0-or-later
// Convert decoded frames into owned CPU bitmaps. AppKit draws these as ordinary
// window content, with no AVSampleBufferDisplayLayer or video-overlay surface.
#import <Accelerate/Accelerate.h>
#include <time.h>

static CGColorSpaceRef DMFrameColorSpace() {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t once;
    dispatch_once(&once,^{ colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return colorSpace;
}
static void DMFreeFrame(void *, const void *bytes, size_t) { free((void *)bytes); }
static CGImageRef DMCreateFrameImage(CVPixelBufferRef pixel, NSString **error) CF_RETURNS_RETAINED;
static CGImageRef DMCreateFrameImage(CVPixelBufferRef pixel, NSString **error) {
    if(!pixel) return nullptr;
    size_t width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel);
    if(!width || !height || width>8192 || height>8192) {
        if(error) *error=@"画面尺寸不支持，请重新连接"; return nullptr;
    }
    OSType type=CVPixelBufferGetPixelFormatType(pixel);
    bool bgra=type==kCVPixelFormatType_32BGRA;
    bool nv12=type==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        type==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if(!bgra && !nv12) { if(error) *error=@"画面像素格式不支持，请复制连接诊断"; return nullptr; }
    size_t stride=width*4,size=stride*height;
    uint8_t *bytes=(uint8_t *)malloc(size);
    if(!bytes) { if(error) *error=@"画面缓冲区分配失败"; return nullptr; }
    CVReturn locked=CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    if(locked) { free(bytes); if(error) *error=@"无法读取画面缓冲区"; return nullptr; }
    bool converted=false;
    if(bgra && !CVPixelBufferIsPlanar(pixel)) {
        const uint8_t *source=(const uint8_t *)CVPixelBufferGetBaseAddress(pixel);
        size_t sourceStride=CVPixelBufferGetBytesPerRow(pixel);
        if(source && sourceStride>=stride) {
            for(size_t y=0;y<height;++y) memcpy(bytes+y*stride,source+y*sourceStride,stride);
            converted=true;
        }
    } else if(nv12 && CVPixelBufferGetPlaneCount(pixel)==2 && !(width&1) && !(height&1)) {
        vImage_Buffer yPlane={CVPixelBufferGetBaseAddressOfPlane(pixel,0),height,width,
            CVPixelBufferGetBytesPerRowOfPlane(pixel,0)};
        vImage_Buffer uvPlane={CVPixelBufferGetBaseAddressOfPlane(pixel,1),height/2,width/2,
            CVPixelBufferGetBytesPerRowOfPlane(pixel,1)};
        vImage_Buffer destination={bytes,height,width,stride};
        bool full=type==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        vImage_YpCbCrPixelRange range={full?0:16,128,full?255:235,full?255:240,255,0,255,0};
        CFTypeRef tag=CVBufferGetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,nullptr);
        const vImage_YpCbCrToARGBMatrix *matrix=width>=1280 ?
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2 : kvImage_YpCbCrToARGBMatrix_ITU_R_601_4;
        if(tag && CFEqual(tag,kCVImageBufferYCbCrMatrix_ITU_R_601_4)) matrix=kvImage_YpCbCrToARGBMatrix_ITU_R_601_4;
        if(tag && CFEqual(tag,kCVImageBufferYCbCrMatrix_ITU_R_709_2)) matrix=kvImage_YpCbCrToARGBMatrix_ITU_R_709_2;
        vImage_YpCbCrToARGBMatrix rec2020={};
        rec2020.Yp=1.f; rec2020.Cr_R=1.4746f; rec2020.Cr_G=-.571353f;
        rec2020.Cb_G=-.164553f; rec2020.Cb_B=1.8814f;
        if(tag && CFEqual(tag,kCVImageBufferYCbCrMatrix_ITU_R_2020)) matrix=&rec2020;
        vImage_YpCbCrToARGB conversion={};
        vImage_Error status=vImageConvert_YpCbCrToARGB_GenerateConversion(matrix,&range,&conversion,
            kvImage420Yp8_CbCr8,kvImageARGB8888,kvImageNoFlags);
        const uint8_t bgraOrder[]={3,2,1,0};
        if(!status && yPlane.data && uvPlane.data)
            status=vImageConvert_420Yp8_CbCr8ToARGB8888(&yPlane,&uvPlane,&destination,&conversion,bgraOrder,255,kvImageNoFlags);
        converted=status==kvImageNoError && yPlane.data && uvPlane.data;
    }
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    if(!converted) { free(bytes); if(error) *error=@"画面颜色转换失败，请复制连接诊断"; return nullptr; }
    CGDataProviderRef provider=CGDataProviderCreateWithData(nullptr,bytes,size,DMFreeFrame);
    if(!provider) { free(bytes); return nullptr; }
    // Video is opaque. Ignoring its alpha also avoids transparent/black captures.
    CGBitmapInfo bitmap=(CGBitmapInfo)(kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
    CGImageRef image=CGImageCreate(width,height,8,32,stride,DMFrameColorSpace(),bitmap,
        provider,nullptr,false,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if(!image && error) *error=@"普通窗口画面创建失败";
    return image;
}
static CGRect DMFrameFitRect(CGRect bounds,size_t width,size_t height) {
    if(!width || !height || bounds.size.width<=0 || bounds.size.height<=0) return CGRectZero;
    CGFloat scale=std::min(bounds.size.width/width,bounds.size.height/height);
    CGSize size=CGSizeMake(width*scale,height*scale);
    return CGRectMake(bounds.origin.x+(bounds.size.width-size.width)/2,
        bounds.origin.y+(bounds.size.height-size.height)/2,size.width,size.height);
}
static void DMDrawFrame(CGContextRef context,CGRect bounds,CGImageRef image) {
    if(!context) return;
    CGContextSaveGState(context);
    CGContextSetRGBFillColor(context,0,0,0,1); CGContextFillRect(context,bounds);
    if(image) {
        CGContextSetInterpolationQuality(context,kCGInterpolationMedium);
        CGContextDrawImage(context,DMFrameFitRect(bounds,CGImageGetWidth(image),CGImageGetHeight(image)),image);
    }
    CGContextRestoreGState(context);
}
static uint64_t DMFrameNow() {
    timespec time={}; clock_gettime(CLOCK_MONOTONIC,&time);
    return (uint64_t)time.tv_sec*NSEC_PER_SEC+time.tv_nsec;
}

@interface DMFramePresenter : NSObject {
    dispatch_queue_t _queue;
    CVPixelBufferRef _pending;
    CGImageRef _ready;
    std::mutex _mutex;
    uint64_t _generation,_nextTime;
    bool _scheduled,_deliveryScheduled,_reportedError;
}
@property(copy) void (^onImage)(CGImageRef);
@property(copy) void (^onError)(NSString *);
- (void)presentPixel:(CVPixelBufferRef)pixel;
- (void)clear;
@end

@implementation DMFramePresenter
- (instancetype)init {
    if((self=[super init])) _queue=dispatch_queue_create("local.devicemirror.bitmap",DISPATCH_QUEUE_SERIAL);
    return self;
}
// Caller owns the mutex. A single pending source and a single pending bitmap
// bound memory even while a screen-sharing app slows down the main thread.
- (void)scheduleLocked {
    uint64_t generation=_generation,now=DMFrameNow();
    int64_t delay=_nextTime>now ? (int64_t)(_nextTime-now) : 0;
    _scheduled=true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay),_queue,^{ [self render:generation]; });
}
- (void)presentPixel:(CVPixelBufferRef)pixel {
    if(!pixel) return;
    std::lock_guard<std::mutex> lock(_mutex);
    if(_pending) CVPixelBufferRelease(_pending);
    _pending=CVPixelBufferRetain(pixel);
    if(!_scheduled) [self scheduleLocked];
}
- (void)render:(uint64_t)generation {
    @autoreleasepool {
        CVPixelBufferRef pixel=nullptr;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            if(generation!=_generation) return;
            pixel=_pending; _pending=nullptr;
            if(!pixel) { _scheduled=false; return; }
            _nextTime=DMFrameNow()+NSEC_PER_SEC/30;
        }
        NSString *error=nil; CGImageRef image=DMCreateFrameImage(pixel,&error);
        CVPixelBufferRelease(pixel);
        std::lock_guard<std::mutex> lock(_mutex);
        if(generation!=_generation) { if(image) CGImageRelease(image); return; }
        if(image) {
            if(_ready) CGImageRelease(_ready); _ready=image;
            if(!_deliveryScheduled) {
                _deliveryScheduled=true;
                dispatch_async(dispatch_get_main_queue(),^{
                    CGImageRef next=nullptr;
                    {
                        std::lock_guard<std::mutex> inner(self->_mutex);
                        if(generation!=self->_generation) return;
                        next=self->_ready; self->_ready=nullptr; self->_deliveryScheduled=false;
                    }
                    if(next) { if(self.onImage) self.onImage(next); CGImageRelease(next); }
                });
            }
        } else if(error && !_reportedError) {
            _reportedError=true;
            dispatch_async(dispatch_get_main_queue(),^{
                { std::lock_guard<std::mutex> inner(self->_mutex); if(generation!=self->_generation) return; }
                if(self.onError) self.onError(error);
            });
        }
        if(_pending) [self scheduleLocked]; else _scheduled=false;
    }
}
- (void)clear {
    std::lock_guard<std::mutex> lock(_mutex);
    ++_generation; _nextTime=0; _scheduled=false; _deliveryScheduled=false; _reportedError=false;
    if(_pending) { CVPixelBufferRelease(_pending); _pending=nullptr; }
    if(_ready) { CGImageRelease(_ready); _ready=nullptr; }
}
- (void)dealloc {
    if(_pending) CVPixelBufferRelease(_pending);
    if(_ready) CGImageRelease(_ready);
}
@end
