// SPDX-License-Identifier: GPL-3.0-or-later
// Headless checks use the exact conversion, owned image, and drawing functions
// that the app shares through its ordinary AppKit window.
static CVPixelBufferRef DMTestPixel(size_t width,size_t height,OSType format) {
    CVPixelBufferRef pixel=nullptr;
    NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferBytesPerRowAlignmentKey:@64};
    CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,(__bridge CFDictionaryRef)attributes,&pixel);
    return pixel;
}
static void DMTestFillBGRA(CVPixelBufferRef pixel,uint8_t blue,uint8_t green,uint8_t red,uint8_t alpha=0) {
    CVPixelBufferLockBaseAddress(pixel,0);
    size_t width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel),stride=CVPixelBufferGetBytesPerRow(pixel);
    uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddress(pixel);
    for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x) {
        uint8_t *p=base+y*stride+x*4; p[0]=blue;p[1]=green;p[2]=red;p[3]=alpha;
    }
    CVPixelBufferUnlockBaseAddress(pixel,0);
}
static bool DMTestImagePixel(CGImageRef image,uint8_t blue,uint8_t green,uint8_t red,int tolerance=0) {
    if(!image) return false;
    CFDataRef copy=CGDataProviderCopyData(CGImageGetDataProvider(image));
    if(!copy) return false;
    const uint8_t *bytes=CFDataGetBytePtr(copy);
    bool ok=CFDataGetLength(copy)>=4 && abs(bytes[0]-blue)<=tolerance &&
        abs(bytes[1]-green)<=tolerance && abs(bytes[2]-red)<=tolerance;
    CFRelease(copy); return ok;
}
static bool DMTestNV12(uint8_t yValue,uint8_t cb,uint8_t cr,CFStringRef matrix,bool full,
                      uint8_t expectedB,uint8_t expectedG,uint8_t expectedR) {
    CVPixelBufferRef pixel=DMTestPixel(66,38,full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if(!pixel) return false;
    CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,matrix,kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferLockBaseAddress(pixel,0);
    size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,0);
    uint8_t *base=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel,0);
    for(size_t y=0;y<38;++y) memset(base+y*stride,yValue,66);
    stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,1);
    base=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel,1);
    for(size_t y=0;y<19;++y) for(size_t x=0;x<33;++x) {base[y*stride+x*2]=cb;base[y*stride+x*2+1]=cr;}
    CVPixelBufferUnlockBaseAddress(pixel,0);
    NSString *error=nil; CGImageRef image=DMCreateFrameImage(pixel,&error); CVPixelBufferRelease(pixel);
    bool ok=DMTestImagePixel(image,expectedB,expectedG,expectedR,4);
    if(!ok) fprintf(stderr,"NV12 color conversion failed for Y=%u Cb=%u Cr=%u full=%d: %s\n",yValue,cb,cr,full,error.UTF8String?:"");
    if(image) CGImageRelease(image); return ok;
}
static void DMTestPump(double duration) {
    double until=CFAbsoluteTimeGetCurrent()+duration;
    do { CFRunLoopRunInMode(kCFRunLoopDefaultMode,.005,true); } while(CFAbsoluteTimeGetCurrent()<until);
}
static bool DMTestHighResolutionScrolling() {
    double started=CFAbsoluteTimeGetCurrent(); bool passed=true;
    for(int segment=0;segment<2;++segment) {
        size_t width=segment?1440:1920,height=segment?1920:1440;
        CVPixelBufferRef pixel=DMTestPixel(width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if(!pixel) return false;
        CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        for(int frame=0;frame<90;++frame) { @autoreleasepool {
            size_t line=(frame*17)%(height-8);
            CVPixelBufferLockBaseAddress(pixel,0);
            uint8_t *luma=(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel,0);
            size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,0);
            for(size_t row=0;row<height;++row) memset(luma+row*stride,row>=line && row<line+8?16:235,width);
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel,1),128,CVPixelBufferGetBytesPerRowOfPlane(pixel,1)*height/2);
            CVPixelBufferUnlockBaseAddress(pixel,0);
            NSString *error=nil; CGImageRef image=DMCreateFrameImage(pixel,&error);
            CVPixelBufferLockBaseAddress(pixel,0);
            memset(luma+line*stride,235,width); // Reuse the decoder surface after conversion.
            CVPixelBufferUnlockBaseAddress(pixel,0);
            if(!image) {passed=false;continue;}
            CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));
            const uint8_t *bytes=data?CFDataGetBytePtr(data):nullptr;
            size_t imageStride=CGImageGetBytesPerRow(image);
            size_t other=(line+16)%height;
            passed &= bytes && bytes[line*imageStride+4]<3 && bytes[other*imageStride+4]>252;
            if(data) CFRelease(data); CGImageRelease(image);
        }}
        CVPixelBufferRelease(pixel);
    }
    printf("180 NV12 scrolling frames at 1920x1440/1440x1920 with source reuse: %s (%.3fs)\n",passed?"PASS":"FAIL",CFAbsoluteTimeGetCurrent()-started);
    return passed;
}
static int DMRenderTest() {
    bool ownership=false,colors=true,drawing=false,motion=true,presenterOK=false;
    NSString *error=nil;
    CVPixelBufferRef pixel=DMTestPixel(66,38,kCVPixelFormatType_32BGRA);
    if(!pixel) return 1;
    DMTestFillBGRA(pixel,11,22,233);
    CGImageRef retained=DMCreateFrameImage(pixel,&error);
    DMTestFillBGRA(pixel,0,0,0); CVPixelBufferRelease(pixel);
    ownership=DMTestImagePixel(retained,11,22,233) && CGImageGetWidth(retained)==66 && CGImageGetHeight(retained)==38;
    printf("Owned BGRA image survives source overwrite/release and padded rows: %s\n",ownership?"PASS":"FAIL");

    colors &= DMTestNV12(16,128,128,kCVImageBufferYCbCrMatrix_ITU_R_601_4,false,0,0,0);
    colors &= DMTestNV12(235,128,128,kCVImageBufferYCbCrMatrix_ITU_R_709_2,false,255,255,255);
    colors &= DMTestNV12(81,90,240,kCVImageBufferYCbCrMatrix_ITU_R_601_4,false,0,0,254);
    colors &= DMTestNV12(63,102,240,kCVImageBufferYCbCrMatrix_ITU_R_709_2,false,0,0,255);
    colors &= DMTestNV12(74,97,240,kCVImageBufferYCbCrMatrix_ITU_R_2020,false,0,0,255);
    colors &= DMTestNV12(76,85,255,kCVImageBufferYCbCrMatrix_ITU_R_601_4,true,0,0,254);
    colors &= DMTestNV12(0,128,128,kCVImageBufferYCbCrMatrix_ITU_R_709_2,true,0,0,0);
    colors &= DMTestNV12(255,128,128,kCVImageBufferYCbCrMatrix_ITU_R_709_2,true,255,255,255);
    printf("NV12 limited/full range, 601/709/2020 matrices and opaque colors: %s\n",colors?"PASS":"FAIL");

    if(retained) {
        const size_t width=100,height=100; uint8_t bytes[width*height*4]={};
        CGContextRef context=CGBitmapContextCreate(bytes,width,height,8,width*4,DMFrameColorSpace(),
            kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
        DMDrawFrame(context,CGRectMake(0,0,width,height),retained);
        const uint8_t *center=bytes+(50*width+50)*4;
        const uint8_t *edge=bytes+(2*width+50)*4;
        CGRect landscape=DMFrameFitRect(CGRectMake(0,0,100,100),64,32);
        CGRect portrait=DMFrameFitRect(CGRectMake(0,0,100,100),32,64);
        drawing=center[2]>225 && center[1]>15 && center[0]>5 && center[3]==255 &&
            edge[0]==0 && edge[1]==0 && edge[2]==0 && edge[3]==255 &&
            CGRectEqualToRect(landscape,CGRectMake(0,25,100,50)) && CGRectEqualToRect(portrait,CGRectMake(25,0,50,100));
        CGContextRelease(context); CGImageRelease(retained);
    }
    printf("Ordinary Quartz capture path, opaque image and aspect-fit/letterboxing: %s\n",drawing?"PASS":"FAIL");

    pixel=DMTestPixel(64,48,kCVPixelFormatType_32BGRA);
    DMTestFillBGRA(pixel,0,0,230);
    CVPixelBufferLockBaseAddress(pixel,0);
    uint8_t *rows=(uint8_t *)CVPixelBufferGetBaseAddress(pixel);
    size_t sourceStride=CVPixelBufferGetBytesPerRow(pixel);
    for(size_t y=24;y<48;++y) for(size_t x=0;x<64;++x) {rows[y*sourceStride+x*4]=230;rows[y*sourceStride+x*4+2]=0;}
    CVPixelBufferUnlockBaseAddress(pixel,0);
    CGImageRef direction=DMCreateFrameImage(pixel,&error); CVPixelBufferRelease(pixel);
    uint8_t raster[64*48*4]={};
    CGContextRef rasterContext=CGBitmapContextCreate(raster,64,48,8,64*4,DMFrameColorSpace(),
        kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    DMDrawFrame(rasterContext,CGRectMake(0,0,64,48),direction);
    bool orientation=raster[2]>225 && raster[0]<3 && raster[(47*64)*4]>225 && raster[(47*64)*4+2]<3;
    CGContextRelease(rasterContext); if(direction) CGImageRelease(direction);
    printf("Quartz drawing preserves top/bottom orientation: %s\n",orientation?"PASS":"FAIL");

    double started=CFAbsoluteTimeGetCurrent();
    for(int frame=0;frame<600;++frame) { @autoreleasepool {
        bool portrait=(frame/100)%2;
        CVPixelBufferRef current=DMTestPixel(portrait?240:320,portrait?320:240,kCVPixelFormatType_32BGRA);
        DMTestFillBGRA(current,frame%200,40,220);
        CGImageRef image=DMCreateFrameImage(current,&error);
        CVPixelBufferRelease(current);
        motion &= DMTestImagePixel(image,frame%200,40,220);
        if(image) CGImageRelease(image);
    }}
    printf("600 updating frames with six landscape/portrait segments: %s (%.3fs)\n",motion?"PASS":"FAIL",CFAbsoluteTimeGetCurrent()-started);
    bool scrolling=DMTestHighResolutionScrolling();

    DMFramePresenter *presenter=[[DMFramePresenter alloc] init];
    __block int count=0,last=-1,errorCount=0;
    presenter.onImage=^(CGImageRef image) {
        ++count;
        CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));
        if(data) {last=CFDataGetBytePtr(data)[0];CFRelease(data);}
    };
    presenter.onError=^(NSString *) {++errorCount;};
    pixel=DMTestPixel(64,48,kCVPixelFormatType_32BGRA); DMTestFillBGRA(pixel,1,0,255);
    [presenter presentPixel:pixel]; CVPixelBufferRelease(pixel); [presenter clear];
    DMTestPump(.06); bool canceled=count==0;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for(int frame=0;frame<1000;++frame) { @autoreleasepool {
            CVPixelBufferRef input=DMTestPixel(64,48,kCVPixelFormatType_32BGRA);
            DMTestFillBGRA(input,frame%256,0,255); [presenter presentPixel:input]; CVPixelBufferRelease(input);
        }}
        dispatch_semaphore_signal(done);
    });
    bool finished=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
    DMTestPump(.20); presenterOK=canceled && finished && count>0 && count<10 && last==999%256 && errorCount==0;
    [presenter clear]; int previous=count; DMTestPump(.05); presenterOK &= count==previous;
    printf("Latest-frame delivery under 1000-frame burst, slow main queue and clear/cancel: %s (%d delivered)\n",presenterOK?"PASS":"FAIL",count);
    return ownership && colors && drawing && orientation && motion && scrolling && presenterOK ? 0 : 1;
}
