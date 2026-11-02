// SPDX-License-Identifier: GPL-3.0-or-later
#import "Media.mm"
#import <CoreMediaIO/CoreMediaIO.h>
#include "raop.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>

@interface DMApp : NSObject <NSApplicationDelegate, NSWindowDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate> {
    raop_t *_server;
    dnssd_t *_bonjour;
    dispatch_queue_t _serverQueue, _videoQueue, _audioQueue, _usbQueue;
    std::atomic<int> _mode;
    std::atomic<bool> _acceptFrames;
    std::atomic<uint64_t> _generation;
    AVCaptureSession *_capture;
    NSArray<AVCaptureDevice *> *_devices;
    NSString *_usbDeviceID;
    BOOL _usbStarting;
    BOOL _smokeTesting;
    BOOL _usbAuthorized;
    NSString *_supportPath;
    int _instanceLock;
    std::atomic<bool> _videoReported;
    NSMutableArray<NSString *> *_diagnostics;
    NSUInteger _progressSerial;
}
@property(strong) NSWindow *window;
@property(strong) DMVideoView *video;
@property(strong) NSView *placeholder;
@property(strong) NSTextField *headline, *hint, *status, *pin;
@property(strong) NSSegmentedControl *modeSelector;
@property(strong) NSButton *pinButton, *muteButton;
@property(strong) NSPopUpButton *deviceMenu;
@property(strong) DMVideoDecoder *decoder;
@property(strong) DMAudioDecoder *audio;
@property(strong) NSTimer *usbTimer;
- (void)receiveVideo:(video_decode_struct *)data;
- (void)receiveAudio:(audio_decode_struct *)data;
- (void)audioFormat:(unsigned char)ct frames:(unsigned short)frames;
- (void)showPairingPIN:(NSString *)code;
- (void)streamEnded;
- (void)resetConnection;
- (void)receiverEvent:(NSInteger)event;
- (void)recordDiagnostic:(NSString *)message;
@end

static void DMVideo(void *ctx, raop_ntp_t *, video_decode_struct *data) {
    @autoreleasepool { [(__bridge DMApp *)ctx receiveVideo:data]; }
}
static void DMAudio(void *ctx, raop_ntp_t *, audio_decode_struct *data) {
    @autoreleasepool { [(__bridge DMApp *)ctx receiveAudio:data]; }
}
static void DMFormat(void *ctx, unsigned char *ct, unsigned short *spf, bool *, bool *, uint64_t *) {
    @autoreleasepool { [(__bridge DMApp *)ctx audioFormat:*ct frames:*spf]; }
}
static void DMNoop(void *) {}
static double DMVolume(void *) { return 0.0; }
static void DMSetVolume(void *, float) {}
static void DMReset(void *ctx, reset_type_t) {
    @autoreleasepool { [(__bridge DMApp *)ctx streamEnded]; }
}
static void DMRunning(void *ctx, bool running) {
    if (!running) { @autoreleasepool { [(__bridge DMApp *)ctx streamEnded]; } }
}
static void DMConnReset(void *ctx, int) {
    @autoreleasepool { [(__bridge DMApp *)ctx resetConnection]; }
}
static int DMCodec(void *, video_codec_t codec) { return codec == VIDEO_CODEC_H264 ? 0 : -1; }
static void DMPin(void *ctx, char *pin) {
    @autoreleasepool { [(__bridge DMApp *)ctx showPairingPIN:[NSString stringWithUTF8String:pin]]; }
}
static void DMReport(void *, char *, char *, char *, bool *admit) { *admit = true; }
static void DMLog(void *context, int level, const char *message) {
    // Only fixed event codes leave the protocol logger. Never retain raw messages,
    // which can include pairing codes, cryptographic material or device identities.
    NSInteger event=0;
    if (strstr(message,"DeviceMirror pairing: challenge sent")) event=1;
    else if (strstr(message,"DeviceMirror pairing: client proof verified")) event=2;
    else if (strstr(message,"DeviceMirror pairing: trusted keys exchanged")) event=3;
    else if (strstr(message,"DeviceMirror pairing: verification complete")) event=4;
    else if (strstr(message,"client proof not validated")) event=-1;
    else if (strstr(message,"client_proof_len") || strstr(message,"invalid encrypted key lengths")) event=-2;
    else if (strstr(message,"Incorrect pair-verify signature") || strstr(message,"client authentication failed")) event=-3;
    else if (strstr(message,"rejecting new connection request")) event=-4;
    if (context && event) [(__bridge DMApp *)context receiverEvent:event];
}

static raop_callbacks_t DMReceiverCallbacks(void *context) {
    raop_callbacks_t cb = {};
    cb.cls = context; cb.video_process = DMVideo; cb.audio_process = DMAudio;
    cb.conn_feedback = DMNoop; cb.conn_init = DMNoop; cb.conn_destroy = DMNoop;
    cb.video_pause = DMNoop; cb.video_resume = DMNoop;
    cb.video_reset = DMReset; cb.conn_reset = DMConnReset; cb.mirror_video_running = DMRunning;
    cb.audio_set_client_volume = DMVolume; cb.audio_set_volume = DMSetVolume;
    cb.audio_get_format = DMFormat; cb.video_set_codec = DMCodec;
    cb.display_pin = DMPin; cb.report_client_request = DMReport;
    // No optional client allowlist is configured. Keep UxPlay's normal PIN pairing
    // behavior; returning false from check_register rejects every resumed handshake.
    return cb;
}

static NSTextField *DMLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = NSColor.labelColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@implementation DMApp
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [self.window makeKeyAndOrderFront:nil]; return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _smokeTesting = [NSProcessInfo.processInfo.arguments containsObject:@"--ui-smoke-test"];
    // One receiver per user avoids duplicate Bonjour entries after double-clicking twice.
    NSURL *support = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Device Mirror" isDirectory:YES];
    NSString *testDirectory = NSProcessInfo.processInfo.environment[@"DM_TEST_OUTPUT_DIR"];
    if (_smokeTesting && testDirectory.length) support = [NSURL fileURLWithPath:testDirectory isDirectory:YES];
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:support withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:&directoryError];
    if (directoryError) { [NSApp terminate:nil]; return; }
    _supportPath = support.path;
    _diagnostics=[NSMutableArray array];
    _instanceLock = open([[support URLByAppendingPathComponent:@"receiver.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (_instanceLock < 0 || flock(_instanceLock, LOCK_EX | LOCK_NB) != 0) {
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.devicemirror.mac"])
            if (app.processIdentifier != getpid()) [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        [NSApp terminate:nil]; return;
    }
    _serverQueue = dispatch_queue_create("local.devicemirror.receiver", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("local.devicemirror.video", DISPATCH_QUEUE_SERIAL);
    _audioQueue = dispatch_queue_create("local.devicemirror.audio", DISPATCH_QUEUE_SERIAL);
    _usbQueue = dispatch_queue_create("local.devicemirror.usb", DISPATCH_QUEUE_SERIAL);
    self.decoder = [[DMVideoDecoder alloc] init];
    self.audio = [[DMAudioDecoder alloc] init]; self.audio.player = [[DMAudioPlayer alloc] init];
    [self createMenu]; [self createWindow];
    __weak DMApp *weakSelf = self;
    self.decoder.onFrame = ^(CVPixelBufferRef pixel) {
        DMApp *app = weakSelf;
        if (app && app->_mode.load() == 0 && app->_acceptFrames.load()) [app.video presentPixel:pixel];
    };
    self.decoder.onError = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DMApp *app=weakSelf; if(!app) return;
            app.status.stringValue=message; app.headline.stringValue=@"配对已通过，画面解码遇到问题";
            app.hint.stringValue=message; ++app->_progressSerial;
            [app recordDiagnostic:message];
        });
    };
    self.video.onError=self.decoder.onError;
    self.audio.onError = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DMApp *app = weakSelf;
            if (app.video.showingFrame) app.status.stringValue = message;
        });
    };
    self.video.onFirstFrame = ^(size_t width, size_t height) {
        DMApp *app = weakSelf; if (!app) return;
        app.placeholder.hidden = YES; app.pin.hidden = YES;
        app.status.stringValue = [NSString stringWithFormat:@"%@ 已连接 · %zu × %zu",
            app->_mode.load() == 0 ? @"AirPlay" : @"USB", width, height];
        ++app->_progressSerial; [app recordDiagnostic:@"画面已显示（普通窗口绘图）"];
    };
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self switchMode:nil];
    self.usbTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *) {
        DMApp *app = weakSelf;
        if (app && app->_mode.load() == 1) [app refreshUSB];
    }];
    if (_smokeTesting) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.window.contentView layoutSubtreeIfNeeded];
            NSBitmapImageRep *bitmap = [self.window.contentView bitmapImageRepForCachingDisplayInRect:self.window.contentView.bounds];
            [self.window.contentView cacheDisplayInRect:self.window.contentView.bounds toBitmapImageRep:bitmap];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[testDirectory stringByAppendingPathComponent:@"window.png"] atomically:YES];
            BOOL before = self.window.level == NSFloatingWindowLevel;
            [self togglePin:nil]; BOOL toggled = self.window.level == NSFloatingWindowLevel;
            [self togglePin:nil];
            fprintf(stderr, "Window resize/pin: %s\n", before != toggled ? "PASS" : "FAIL");
            [NSApp terminate:nil];
        });
    }
}
- (void)createMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init]; [menu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Device Mirror"];
    [appMenu addItemWithTitle:@"关于 Device Mirror" action:@selector(about:) keyEquivalent:@""];
    NSMenuItem *copy=[appMenu addItemWithTitle:@"复制连接诊断" action:@selector(copyDiagnostics:) keyEquivalent:@""];
    copy.target=self;
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"隐藏 Device Mirror" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 Device Mirror" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *windowItem = [[NSMenuItem alloc] init]; [menu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    NSMenuItem *top = [windowMenu addItemWithTitle:@"切换置顶" action:@selector(togglePin:) keyEquivalent:@"t"];
    top.target = self;
    NSMenuItem *reconnect = [windowMenu addItemWithTitle:@"重新连接" action:@selector(reconnect:) keyEquivalent:@"r"];
    reconnect.target = self;
    [windowMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    windowItem.submenu = windowMenu; NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu;
}
- (void)createWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Device Mirror · 0.1.4"; self.window.delegate = self;
    self.window.minSize = NSMakeSize(640, 460); self.window.releasedWhenClosed = NO;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [self.window setFrameAutosaveName:@"DeviceMirrorWindow"];
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"NSWindow Frame DeviceMirrorWindow"]) [self.window center];
    NSView *root = self.window.contentView;
    NSVisualEffectView *toolbar = [[NSVisualEffectView alloc] init];
    toolbar.material = NSVisualEffectMaterialHeaderView; toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:toolbar];
    self.modeSelector = [NSSegmentedControl segmentedControlWithLabels:@[@"无线 AirPlay", @"USB 数据线"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(switchMode:)];
    self.modeSelector.selectedSegment = 0; self.modeSelector.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:self.modeSelector];
    self.pinButton = [NSButton buttonWithTitle:@"置顶" target:self action:@selector(togglePin:)];
    self.pinButton.buttonType = NSButtonTypePushOnPushOff;
    self.pinButton.image = [NSImage imageWithSystemSymbolName:@"pin" accessibilityDescription:@"窗口置顶"];
    self.pinButton.imagePosition = NSImageLeading;
    self.pinButton.imageScaling = NSImageScaleProportionallyDown;
    self.pinButton.translatesAutoresizingMaskIntoConstraints = NO; [toolbar addSubview:self.pinButton];
    self.muteButton = [NSButton buttonWithTitle:@"静音" target:self action:@selector(toggleMute:)];
    self.muteButton.buttonType = NSButtonTypePushOnPushOff;
    self.muteButton.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2" accessibilityDescription:@"静音"];
    self.muteButton.imagePosition = NSImageLeading;
    self.muteButton.imageScaling = NSImageScaleProportionallyDown;
    self.muteButton.translatesAutoresizingMaskIntoConstraints = NO; [toolbar addSubview:self.muteButton];
    NSButton *retry = [NSButton buttonWithTitle:@"重新连接" target:self action:@selector(reconnect:)];
    retry.translatesAutoresizingMaskIntoConstraints = NO; [toolbar addSubview:retry];
    self.deviceMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.deviceMenu.target = self; self.deviceMenu.action = @selector(selectUSB:);
    self.deviceMenu.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceMenu.hidden = YES; [toolbar addSubview:self.deviceMenu];
    self.video = [[DMVideoView alloc] initWithFrame:NSZeroRect];
    self.video.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:self.video];
    self.placeholder = [[NSView alloc] init]; self.placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.video addSubview:self.placeholder];
    NSImageView *symbol = [[NSImageView alloc] init];
    symbol.image = [NSImage imageWithSystemSymbolName:@"ipad.and.arrow.forward" accessibilityDescription:@"iPad 投屏"];
    symbol.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:60 weight:NSFontWeightLight];
    symbol.contentTintColor = [NSColor colorWithRed:.48 green:.65 blue:1 alpha:1];
    symbol.translatesAutoresizingMaskIntoConstraints = NO; [self.placeholder addSubview:symbol];
    self.headline = DMLabel(@"让 iPad 留在一个窗口里", 26, NSFontWeightMedium);
    self.headline.textColor = NSColor.whiteColor; self.headline.alignment = NSTextAlignmentCenter;
    self.headline.maximumNumberOfLines=2; self.headline.lineBreakMode=NSLineBreakByWordWrapping;
    [self.placeholder addSubview:self.headline];
    self.hint = DMLabel(@"", 15, NSFontWeightRegular);
    self.hint.textColor = [NSColor colorWithWhite:.68 alpha:1];
    self.hint.alignment = NSTextAlignmentCenter; self.hint.maximumNumberOfLines = 0;
    self.hint.lineBreakMode = NSLineBreakByWordWrapping; [self.placeholder addSubview:self.hint];
    self.pin = DMLabel(@"", 22, NSFontWeightSemibold); self.pin.alignment = NSTextAlignmentCenter;
    self.pin.textColor = [NSColor colorWithRed:.48 green:.65 blue:1 alpha:1];
    self.pin.hidden = YES; [self.placeholder addSubview:self.pin];
    self.status = DMLabel(@"正在启动…", 12, NSFontWeightRegular);
    self.status.textColor = NSColor.secondaryLabelColor; self.status.lineBreakMode = NSLineBreakByTruncatingTail;
    [root addSubview:self.status];
    NSButton *diagnostic=[NSButton buttonWithTitle:@"复制连接诊断" target:self action:@selector(copyDiagnostics:)];
    diagnostic.bezelStyle=NSBezelStyleInline; diagnostic.font=[NSFont systemFontOfSize:12];
    diagnostic.translatesAutoresizingMaskIntoConstraints=NO; [root addSubview:diagnostic];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor], [toolbar.heightAnchor constraintEqualToConstant:54],
        [self.modeSelector.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor constant:16],
        [self.modeSelector.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [retry.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor constant:-16],
        [retry.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.pinButton.trailingAnchor constraintEqualToAnchor:retry.leadingAnchor constant:-8],
        [self.pinButton.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.pinButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],
        [self.muteButton.trailingAnchor constraintEqualToAnchor:self.pinButton.leadingAnchor constant:-8],
        [self.muteButton.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.muteButton.widthAnchor constraintGreaterThanOrEqualToConstant:88],
        [self.deviceMenu.leadingAnchor constraintEqualToAnchor:self.modeSelector.trailingAnchor constant:10],
        [self.deviceMenu.trailingAnchor constraintLessThanOrEqualToAnchor:self.muteButton.leadingAnchor constant:-10],
        [self.deviceMenu.widthAnchor constraintLessThanOrEqualToConstant:180],
        [self.deviceMenu.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.video.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor],
        [self.video.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.video.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.video.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-32],
        [self.status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:diagnostic.leadingAnchor constant:-10],
        [self.status.centerYAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],
        [diagnostic.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [diagnostic.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.placeholder.centerXAnchor constraintEqualToAnchor:self.video.centerXAnchor],
        [self.placeholder.centerYAnchor constraintEqualToAnchor:self.video.centerYAnchor],
        [self.placeholder.widthAnchor constraintEqualToAnchor:self.video.widthAnchor constant:-48],
        [self.placeholder.heightAnchor constraintEqualToConstant:260],
        [symbol.centerXAnchor constraintEqualToAnchor:self.placeholder.centerXAnchor],
        [symbol.topAnchor constraintEqualToAnchor:self.placeholder.topAnchor],
        [symbol.widthAnchor constraintEqualToConstant:80], [symbol.heightAnchor constraintEqualToConstant:76],
        [self.headline.topAnchor constraintEqualToAnchor:symbol.bottomAnchor constant:16],
        [self.headline.leadingAnchor constraintEqualToAnchor:self.placeholder.leadingAnchor],
        [self.headline.trailingAnchor constraintEqualToAnchor:self.placeholder.trailingAnchor],
        [self.hint.topAnchor constraintEqualToAnchor:self.headline.bottomAnchor constant:18],
        [self.hint.leadingAnchor constraintEqualToAnchor:self.placeholder.leadingAnchor],
        [self.hint.trailingAnchor constraintEqualToAnchor:self.placeholder.trailingAnchor],
        [self.pin.topAnchor constraintEqualToAnchor:self.hint.bottomAnchor constant:18],
        [self.pin.centerXAnchor constraintEqualToAnchor:self.placeholder.centerXAnchor]
    ]];
}
- (void)togglePin:(id)sender {
    BOOL pinned = self.window.level == NSFloatingWindowLevel;
    self.window.level = pinned ? NSNormalWindowLevel : NSFloatingWindowLevel;
    self.pinButton.state = pinned ? NSControlStateValueOff : NSControlStateValueOn;
    self.pinButton.title = pinned ? @"置顶" : @"已置顶";
}
- (void)toggleMute:(id)sender {
    BOOL mute = self.muteButton.state == NSControlStateValueOn;
    [self.audio.player setMuted:mute]; self.muteButton.title = mute ? @"已静音" : @"静音";
}
- (void)about:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Device Mirror 0.1.4";
    alert.informativeText = @"iPad → Mac 独立窗口投屏\n\n无线 AirPlay · USB 数据线 · 窗口置顶\n\n基于 UxPlay 和 Apple 原生媒体框架。\nGPL-3.0-or-later；完整源码随 App 提供。";
    [alert runModal];
}
- (void)recordDiagnostic:(NSString *)message {
    if (!message || !_diagnostics) return;
    NSDateFormatter *format=[[NSDateFormatter alloc] init]; format.dateFormat=@"HH:mm:ss";
    [_diagnostics addObject:[NSString stringWithFormat:@"%@ %@",[format stringFromDate:NSDate.date],message]];
    while (_diagnostics.count>40) [_diagnostics removeObjectAtIndex:0];
    NSString *text=[NSString stringWithFormat:@"Device Mirror 0.1.4\nmacOS %@\n%@\n",
        NSProcessInfo.processInfo.operatingSystemVersionString,[_diagnostics componentsJoinedByString:@"\n"]];
    NSString *path=[_supportPath stringByAppendingPathComponent:@"connection.log"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(path.fileSystemRepresentation,0600);
}
- (void)copyDiagnostics:(id)sender {
    NSString *text=[NSString stringWithFormat:@"Device Mirror 0.1.4\nmacOS %@\n当前状态：%@\n%@",
        NSProcessInfo.processInfo.operatingSystemVersionString,self.status.stringValue,
        [_diagnostics componentsJoinedByString:@"\n"] ?: @""];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    if ([sender isKindOfClass:NSButton.class]) {
        NSButton *button=sender; button.title=@"已复制";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{button.title=@"复制连接诊断";});
    }
}
- (void)receiverEvent:(NSInteger)event {
    uint64_t generation=_generation.load();
    dispatch_async(dispatch_get_main_queue(),^{
        if (generation!=self->_generation.load() || self->_mode.load()!=0) return;
        NSString *text=nil;
        switch(event) {
            case 1: text=@"已收到配对请求，等待验证配对码"; break;
            case 2: text=@"配对码已通过，正在建立安全连接…"; break;
            case 3: text=@"配对信息已交换，正在完成连接…"; break;
            case 4: text=@"配对已完成，等待 iPad 画面…"; break;
            case 7: text=@"已收到 iPad 画面，正在准备显示…"; break;
            case -1: text=@"配对码验证失败，请停止镜像后重新输入新配对码"; break;
            case -2: text=@"配对数据不兼容，请复制连接诊断"; break;
            case -3: text=@"连接验证失败，请点击重新连接"; break;
            case -4: text=@"还有连接未断开，请先停止 iPad 镜像再重新连接"; break;
        }
        if(!text) return;
        [self recordDiagnostic:text];
        NSUInteger serial=++self->_progressSerial;
        if(self.video.showingFrame) return;
        self.status.stringValue=text;
        if(event>=2 || event<0) {
            self.pin.hidden=YES; self.headline.stringValue=text;
            self.hint.stringValue=event>0 ? @"请保持 iPad 解锁，并等待画面出现" : @"需要继续排查时，点击右下角「复制连接诊断」";
        }
        if(event==4 || event==7) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(generation!=self->_generation.load() || serial!=self->_progressSerial || self.video.showingFrame) return;
            NSString *timeout=event==4 ? @"配对已完成，但尚未收到画面；可复制连接诊断继续排查" :
                @"已收到画面数据，但还没有显示；可复制连接诊断继续排查";
            self.status.stringValue=timeout; self.hint.stringValue=timeout; [self recordDiagnostic:timeout];
        });
    });
}
- (void)showWaiting {
    [self.video clear]; self.placeholder.hidden = NO; self.pin.hidden = YES;
    self.headline.stringValue = @"让 iPad 留在一个窗口里";
    self.hint.stringValue = _mode.load() == 0 ?
        @"1. iPad 和 Mac 连接同一 Wi-Fi\n2. 在 iPad 打开「控制中心 → 屏幕镜像」\n3. 选择 Device Mirror" :
        @"用 USB 数据线连接 iPad 和 Mac\n解锁 iPad，轻点「信任此电脑」\n在上方选择你的 iPad 即可显示画面";
}
- (void)switchMode:(id)sender {
    _mode.store((int)self.modeSelector.selectedSegment); _acceptFrames.store(false);
    uint64_t generation = ++_generation;
    _usbDeviceID = nil;
    _usbAuthorized = NO;
    _videoReported.store(false); ++_progressSerial;
    [self recordDiagnostic:_mode.load()==0 ? @"启动无线 AirPlay 接收" : @"切换到 USB"];
    self.deviceMenu.hidden = _mode.load() == 0;
    self.muteButton.enabled = _mode.load() == 0;
    if (_mode.load() == 1) self.deviceMenu.toolTip = @"USB 版当前显示画面；声音保留在 iPad";
    [self showWaiting]; self.status.stringValue = @"正在切换连接方式…";
    dispatch_async(_serverQueue, ^{
        [self stopAirPlay];
        dispatch_sync(self->_videoQueue, ^{ [self.decoder reset]; });
        dispatch_sync(self->_audioQueue, ^{ [self.audio reset]; });
        if (generation == self->_generation.load() && self->_mode.load() == 0)
            [self startAirPlay:generation];
    });
    dispatch_async(_usbQueue, ^{
        [self stopUSB];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation.load() && self->_mode.load() == 1)
                [self prepareUSB];
        });
    });
}
- (void)reconnect:(id)sender { [self switchMode:nil]; }
- (void)stopAirPlay {
    if (_bonjour) {
        dnssd_unregister_airplay(_bonjour); dnssd_unregister_raop(_bonjour);
    }
    if (_server) { raop_destroy(_server); _server = nullptr; }
    if (_bonjour) { dnssd_destroy(_bonjour); _bonjour = nullptr; }
}
- (void)startAirPlay:(uint64_t)generation {
    raop_callbacks_t cb = DMReceiverCallbacks((__bridge void *)self);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *deviceID = [defaults stringForKey:@"ReceiverDeviceID"];
    if (!deviceID) {
        uint8_t bytes[6]; arc4random_buf(bytes, sizeof(bytes)); bytes[0] = (bytes[0] | 2) & 0xfe;
        deviceID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
        if (!_smokeTesting) [defaults setObject:deviceID forKey:@"ReceiverDeviceID"];
    }
    int error = 0; uint8_t address[6]; unsigned int parsed[6];
    sscanf(deviceID.UTF8String, "%x:%x:%x:%x:%x:%x", &parsed[0], &parsed[1], &parsed[2], &parsed[3], &parsed[4], &parsed[5]);
    for (int i = 0; i < 6; ++i) address[i] = parsed[i];
    const char *name = "Device Mirror";
    _bonjour = dnssd_init(name, (int)strlen(name), (const char *)address, 6, &error, 1);
    if (!_bonjour || error) { [self receiverFailed:@"无法发布 AirPlay 服务，请检查本地网络权限" generation:generation]; return; }
    // Mirror and audio only. HLS and HEVC are not advertised by this version.
    dnssd_set_airplay_features(_bonjour, 0, 0);
    dnssd_set_airplay_features(_bonjour, 4, 0);
    dnssd_set_airplay_features(_bonjour, 42, 0);
    _server = raop_init(&cb);
    if (!_server) { [self receiverFailed:@"AirPlay 接收器初始化失败" generation:generation]; return; }
    raop_set_log_callback(_server, DMLog, (__bridge void *)self); raop_set_log_level(_server, LOGGER_INFO);
    NSString *keyPath = [_supportPath stringByAppendingPathComponent:@"pairing.pem"];
    if (raop_init2(_server, 0, deviceID.UTF8String, keyPath.fileSystemRepresentation) != 0) {
        // raop_destroy assumes init2 succeeded; avoid calling it on a partial instance.
        free(_server); _server = nullptr;
        [self receiverFailed:@"AirPlay 配对初始化失败" generation:generation]; return;
    }
    chmod(keyPath.fileSystemRepresentation, 0600);
    raop_set_dnssd(_server, _bonjour);
    raop_set_plist(_server, "width", 1920); raop_set_plist(_server, "height", 1440);
    raop_set_plist(_server, "maxFPS", 60); raop_set_plist(_server, "pin", 0);
    unsigned short tcp[2] = {0,0}, udp[3] = {0,0,0};
    raop_set_tcp_ports(_server, tcp); raop_set_udp_ports(_server, udp);
    unsigned short port = 0;
    if (raop_start_httpd(_server, &port) != 1) {
        [self receiverFailed:@"无法打开 AirPlay 接收端口，请点击重新连接" generation:generation]; return;
    }
    raop_set_port(_server, port);
    if (dnssd_register_raop(_bonjour, port) || dnssd_register_airplay(_bonjour, port)) {
        [self receiverFailed:@"AirPlay 服务发布失败，请检查本地网络权限" generation:generation]; return;
    }
    if (generation != _generation.load() || _mode.load() != 0) { [self stopAirPlay]; return; }
    _acceptFrames.store(true);
    fprintf(stderr, "Device Mirror ready on port %hu\n", port);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self->_generation.load()) self.status.stringValue = @"等待 iPad · 屏幕镜像中选择 Device Mirror";
    });
}
- (void)receiverFailed:(NSString *)message generation:(uint64_t)generation {
    [self stopAirPlay];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self->_generation.load()) self.status.stringValue = message;
    });
}
- (void)receiveVideo:(video_decode_struct *)data {
    if (!_acceptFrames.load() || _mode.load() != 0 || data->is_h265) return;
    if(!_videoReported.exchange(true)) [self receiverEvent:7];
    dispatch_sync(_videoQueue, ^{ [self.decoder consume:data->data length:data->data_len]; });
}
- (void)receiveAudio:(audio_decode_struct *)data {
    if (!_acceptFrames.load() || _mode.load() != 0) return;
    dispatch_sync(_audioQueue, ^{ [self.audio consume:data->data length:data->data_len]; });
}
- (void)audioFormat:(unsigned char)ct frames:(unsigned short)frames {
    dispatch_sync(_audioQueue, ^{ [self.audio configure:ct frames:frames]; });
}
- (void)showPairingPIN:(NSString *)code {
    uint64_t generation = _generation.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation.load() || self->_mode.load() != 0) return;
        self.placeholder.hidden = NO; self.pin.hidden = NO;
        self.headline.stringValue=@"请在 iPad 输入配对码";
        self.hint.stringValue=@"配对码用于连接验证，请输入下方显示的四位数字";
        self.pin.stringValue = [@"在 iPad 输入配对码：" stringByAppendingString:code ?: @""];
        self.status.stringValue = @"等待在 iPad 上完成配对";
        ++self->_progressSerial; [self recordDiagnostic:@"已显示配对码，等待 iPad 完成输入"];
    });
}
- (void)streamEnded {
    if (!_acceptFrames.load() || _mode.load() != 0) return;
    uint64_t generation = _generation.load();
    _videoReported.store(false);
    dispatch_async(_videoQueue, ^{ [self.decoder reset]; });
    dispatch_async(_audioQueue, ^{ [self.audio reset]; });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation.load() || self->_mode.load() != 0) return;
        [self showWaiting]; self.status.stringValue = @"iPad 已断开 · 可以重新选择 Device Mirror";
        ++self->_progressSerial; [self recordDiagnostic:@"iPad 已断开"];
    });
}
- (void)resetConnection {
    uint64_t generation = _generation.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self->_generation.load() && self->_mode.load() == 0) [self reconnect:nil];
    });
}
- (void)prepareUSB {
    CMIOObjectPropertyAddress property = {kCMIOHardwarePropertyAllowScreenCaptureDevices,
        kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    UInt32 enable = 1;
    OSStatus result = CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &property, 0, nullptr, sizeof(enable), &enable);
    if (result) { self.status.stringValue = @"无法启用 USB 屏幕捕获，请重新连接 iPad"; return; }
    AVAuthorizationStatus authorization = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (authorization == AVAuthorizationStatusNotDetermined) {
        self.status.stringValue = @"请允许使用视频设备，以读取 USB 连接的 iPad 屏幕";
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (self->_mode.load() == 1) [self prepareUSB]; });
        }];
        return;
    }
    if (authorization != AVAuthorizationStatusAuthorized) {
        self.status.stringValue = @"请在「系统设置 → 隐私与安全性 → 相机」中允许 Device Mirror"; return;
    }
    _usbAuthorized = YES;
    [self refreshUSB];
}
- (void)refreshUSB {
    if (_mode.load() != 1 || _usbStarting || !_usbAuthorized) return;
    // A muxed iOS screen source is distinct from the Mac webcam and Continuity Camera.
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
        mediaType:AVMediaTypeMuxed position:AVCaptureDevicePositionUnspecified];
    _devices = discovery.devices;
    NSString *selected = self.deviceMenu.selectedItem.representedObject;
    [self.deviceMenu removeAllItems];
    if (!_devices.count) {
        [self.deviceMenu addItemWithTitle:@"尚未发现 iPad"]; self.deviceMenu.enabled = NO;
        if (_usbDeviceID) {
            _usbDeviceID = nil; _acceptFrames.store(false);
            dispatch_async(_usbQueue, ^{ [self stopUSB]; });
            [self showWaiting];
        }
        self.status.stringValue = @"等待 USB 设备 · 请解锁 iPad 并信任此电脑（仅画面）";
        return;
    }
    self.deviceMenu.enabled = YES;
    for (AVCaptureDevice *device in _devices) {
        [self.deviceMenu addItemWithTitle:device.localizedName];
        self.deviceMenu.lastItem.representedObject = device.uniqueID;
    }
    for (NSMenuItem *item in self.deviceMenu.itemArray)
        if ([item.representedObject isEqual:selected]) [self.deviceMenu selectItem:item];
    NSString *current = self.deviceMenu.selectedItem.representedObject;
    if (![_usbDeviceID isEqualToString:current]) [self selectUSB:nil];
}
- (void)selectUSB:(id)sender {
    if (_mode.load() != 1) return;
    NSString *identifier = self.deviceMenu.selectedItem.representedObject;
    AVCaptureDevice *chosen = nil;
    for (AVCaptureDevice *device in _devices) if ([device.uniqueID isEqualToString:identifier]) chosen = device;
    if (!chosen) return;
    _usbStarting = YES; _usbDeviceID = identifier; _acceptFrames.store(false);
    uint64_t generation = _generation.load();
    self.status.stringValue = @"正在连接 iPad 屏幕…"; [self.video clear];
    dispatch_async(_usbQueue, ^{
        [self stopUSB];
        if (generation != self->_generation.load() || self->_mode.load() != 1) {
            dispatch_async(dispatch_get_main_queue(), ^{ self->_usbStarting = NO; }); return;
        }
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:chosen error:&error];
        self->_capture = [[AVCaptureSession alloc] init];
        [self->_capture beginConfiguration];
        if ([self->_capture canSetSessionPreset:AVCaptureSessionPresetHigh])
            self->_capture.sessionPreset = AVCaptureSessionPresetHigh;
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        [output setSampleBufferDelegate:self queue:self->_usbQueue];
        BOOL configured = input && [self->_capture canAddInput:input] && [self->_capture canAddOutput:output];
        if (configured) { [self->_capture addInput:input]; [self->_capture addOutput:output]; }
        [self->_capture commitConfiguration];
        if (configured) {
            self->_acceptFrames.store(true); [self->_capture startRunning];
            configured = self->_capture.running;
        }
        if (!configured) {
            self->_acceptFrames.store(false); [self stopUSB];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == self->_generation.load()) {
                    self->_usbDeviceID = nil;
                    self.status.stringValue = @"USB 连接失败，请解锁 iPad、确认信任并点击重新连接";
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == self->_generation.load() && !self.video.showingFrame)
                    self.status.stringValue = @"USB 已连接，等待 iPad 画面（声音保留在 iPad）";
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self->_usbStarting = NO; });
    });
}
- (void)stopUSB {
    if (_capture) { [_capture stopRunning]; _capture = nil; }
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    if (_mode.load() == 1 && _acceptFrames.load())
        [self.video presentPixel:CMSampleBufferGetImageBuffer(sample)];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    _acceptFrames.store(false); ++_generation; [self.usbTimer invalidate];
    if (!_serverQueue) return NSTerminateNow;
    dispatch_async(_serverQueue, ^{
        [self stopAirPlay];
        dispatch_sync(self->_usbQueue, ^{ [self stopUSB]; });
        dispatch_sync(self->_videoQueue, ^{ [self.decoder reset]; });
        dispatch_sync(self->_audioQueue, ^{ [self.audio reset]; });
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp replyToApplicationShouldTerminate:YES]; });
    });
    return NSTerminateLater;
}
@end

#import "SelfTest.mm"
#import "ProtocolTest.mm"
#import "FrameRendererTest.mm"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return DMSelfTest();
        if (argc > 1 && strcmp(argv[1], "--protocol-test") == 0) return DMProtocolTest();
        if (argc > 1 && strcmp(argv[1], "--render-test") == 0) return DMRenderTest();
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        static DMApp *delegate;
        delegate = [[DMApp alloc] init]; application.delegate = delegate;
        [application run];
    }
    return 0;
}
