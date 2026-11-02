// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises real H.264 encode/decode, orientation changes, malformed input,
// Core Audio decoder creation, and the AirPlay HTTP listener without an iPad.
struct DMTestState {
    __unsafe_unretained DMVideoDecoder *decoder;
    int encoded = 0;
    int errors = 0;
};
static void DMTestEncoded(void *context, void *, OSStatus status, VTEncodeInfoFlags,
                          CMSampleBufferRef sample) {
    auto *state = (DMTestState *)context;
    if (status || !sample) { fprintf(stderr, "H264 encode callback: %d\n", (int)status); ++state->errors; return; }
    NSMutableData *annexB = [NSMutableData data];
    const uint8_t prefix[] = {0,0,0,1};
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    for (size_t i = 0; i < 2; ++i) {
        const uint8_t *param = nullptr; size_t size = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &param, &size, nullptr, nullptr)) {
            ++state->errors; return;
        }
        [annexB appendBytes:prefix length:4]; [annexB appendBytes:param length:size];
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = CMBlockBufferGetDataLength(block);
    std::vector<uint8_t> bytes(length);
    CMBlockBufferCopyDataBytes(block, 0, length, bytes.data());
    size_t offset = 0;
    while (offset + 4 <= length) {
        uint32_t size = 0; memcpy(&size, bytes.data()+offset, 4); size = CFSwapInt32BigToHost(size);
        offset += 4;
        if (!size || size > length-offset) { ++state->errors; return; }
        [annexB appendBytes:prefix length:4]; [annexB appendBytes:bytes.data()+offset length:size];
        offset += size;
    }
    [state->decoder consume:(const uint8_t *)annexB.bytes length:annexB.length];
    ++state->encoded;
}
static bool DMEncodeTestFrames(DMTestState *state, int width, int height) {
    VTCompressionSessionRef encoder = nullptr;
    OSStatus creation = VTCompressionSessionCreate(kCFAllocatorDefault, width, height, kCMVideoCodecType_H264,
        nullptr, nullptr, nullptr, DMTestEncoded, state, &encoder);
    if (creation) { fprintf(stderr, "H264 encoder creation: %d\n", (int)creation); return false; }
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTCompressionSessionPrepareToEncodeFrames(encoder);
    for (int frame = 0; frame < 4; ++frame) {
        CVPixelBufferRef pixel = nullptr;
        NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &pixel)) return false;
        CVPixelBufferLockBaseAddress(pixel, 0);
        uint8_t *data = (uint8_t *)CVPixelBufferGetBaseAddress(pixel);
        size_t stride = CVPixelBufferGetBytesPerRow(pixel);
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            uint8_t *p = data + y*stride + x*4;
            p[0] = 200; p[1] = 100; p[2] = 40; p[3] = 255;
        }
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        OSStatus status = VTCompressionSessionEncodeFrame(encoder, pixel, CMTimeMake(frame, 30),
            CMTimeMake(1,30), nullptr, nullptr, nullptr);
        CVPixelBufferRelease(pixel);
        if (status) { fprintf(stderr, "H264 encode frame: %d\n", (int)status); ++state->errors; }
    }
    VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
    VTCompressionSessionInvalidate(encoder); CFRelease(encoder);
    return true;
}
static void DMTestAudioNoop(void *, raop_ntp_t *, audio_decode_struct *) {}
static void DMTestVideoNoop(void *, raop_ntp_t *, video_decode_struct *) {}
static int DMSelfTest() {
    __block int decoded = 0, errors = 0;
    __block BOOL landscape = NO, portrait = NO;
    DMVideoDecoder *decoder = [[DMVideoDecoder alloc] init];
    decoder.onFrame = ^(CVPixelBufferRef pixel) {
        ++decoded;
        size_t w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel);
        if (w == 640 && h == 480) landscape = YES;
        else if (w == 480 && h == 640) portrait = YES;
        else ++errors;
        CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
        const uint8_t *luma = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel, 0);
        // Blue/green test image must produce a populated, nonblack luma plane.
        if (!luma || luma[64] < 40 || luma[64] > 160) ++errors;
        CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
    };
    decoder.onError = ^(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); ++errors; };
    DMTestState state = {decoder};
    bool encoded = DMEncodeTestFrames(&state, 640, 480) && DMEncodeTestFrames(&state, 480, 640);
    const uint8_t invalid[][8] = {{1,2,3,4,5,6,7,8},{0,0,0,1,0xff,0,0,0},{0,0,1,0x67,0,0,0,0}};
    for (const auto &packet : invalid) [decoder consume:packet length:sizeof(packet)];
    [decoder consume:nullptr length:0]; [decoder reset];
    bool videoOK = encoded && decoded == 8 && state.encoded == 8 && !state.errors && !errors && landscape && portrait;
    printf("H264 encode/decode + landscape/portrait + invalid input: %s (%d frames)\n", videoOK ? "PASS" : "FAIL", decoded);

    DMAudioDecoder *audio = [[DMAudioDecoder alloc] init];
    bool audioOK = true;
    for (uint8_t codec : {1,2,4,8}) {
        bool ok = [audio configure:codec frames:0]; audioOK &= ok;
        printf("Audio codec %u initialization: %s\n", codec, ok ? "PASS" : "FAIL");
    }
    [audio reset];
    printf("PCM/ALAC/AAC/AAC-ELD decoder initialization: %s\n", audioOK ? "PASS" : "FAIL");

    raop_callbacks_t callbacks = {}; callbacks.audio_process = DMTestAudioNoop;
    callbacks.video_process = DMTestVideoNoop;
    bool serverOK = true;
    for (int i = 0; i < 3; ++i) {
        raop_t *server = raop_init(&callbacks);
        if (!server || raop_init2(server, 0, "02:23:45:67:89:AB", "")) { serverOK = false; break; }
        raop_set_log_level(server, LOGGER_ERR);
        unsigned short port = 0;
        serverOK &= raop_start_httpd(server, &port) == 1 && port > 0;
        raop_destroy(server);
    }
    printf("AirPlay listener start/stop x3: %s\n", serverOK ? "PASS" : "FAIL");
    return videoOK && audioOK && serverOK ? 0 : 1;
}
