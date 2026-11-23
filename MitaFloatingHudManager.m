#import "MitaFloatingHudManager.h"
#import "MitaConfigStore.h"
#import "MitaAiGroupEngine.h"
#import "MitaKeepAliveAndControl.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface MitaFloatingHudManager () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) UIView *anchorView;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *sampleLayer;
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) NSTimer *renderTimer;
@property (nonatomic, assign) BOOL pulseToggle;
@property (nonatomic, assign) BOOL curRunning;
@property (nonatomic, copy) NSString *curPhase;
@property (nonatomic, copy) NSString *curModel;
@property (nonatomic, assign) NSInteger curRepliedCount;
@property (nonatomic, copy) NSString *curStatusLine;
@property (nonatomic, strong) NSLock *stateLock;
@end

@implementation MitaFloatingHudManager

+ (instancetype)shared {
    static MitaFloatingHudManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[MitaFloatingHudManager alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _stateLock = [[NSLock alloc] init];
        _curRunning = NO;
        _curPhase = @"idle";
        _curModel = @"grok-4.7";
        _curRepliedCount = 0;
        _curStatusLine = @"点击 APP 内「立即启动」开启微信自动回复";
    }
    return self;
}

- (BOOL)isSupported {
    return [AVPictureInPictureController isPictureInPictureSupported];
}

- (BOOL)isActive {
    return self.pipController != nil && self.pipController.isPictureInPictureActive;
}

- (void)attachToHostView:(UIView *)hostView {
    if (!hostView || self.pipController != nil) return;
    if (![AVPictureInPictureController isPictureInPictureSupported]) return;

    // 確保 AudioSession 處於 Playback + MixWithOthers 以允許後台 PiP 自動激活且不搶聲音
    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];

    // 置於 WebView 底層的可見區域宿主視圖（必須在屏幕 bounds 內且 hidden=NO、alpha=1 才能 100% 觸發 iOS 15 自動 PiP）
    UIView *anchor = [[UIView alloc] initWithFrame:CGRectMake(12.0, 56.0, 260.0, 84.0)];
    anchor.userInteractionEnabled = NO;
    anchor.backgroundColor = [UIColor clearColor];
    [hostView insertSubview:anchor atIndex:0];
    self.anchorView = anchor;

    AVSampleBufferDisplayLayer *layer = [[AVSampleBufferDisplayLayer alloc] init];
    layer.frame = anchor.bounds;
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.opaque = YES;
    [anchor.layer addSublayer:layer];
    self.sampleLayer = layer;

    // 先推入首幀高清狀態畫面，讓 SampleBufferDisplayLayer 立即就緒
    [self enqueueHudSampleFrame];

    if (@available(iOS 15.0, *)) {
        AVPictureInPictureControllerContentSource *src =
            [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:layer
                                                                               playbackDelegate:self];
        AVPictureInPictureController *pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
        pip.delegate = self;
        pip.canStartPictureInPictureAutomaticallyFromInline = ([MitaConfigStore shared].floatingHudEnabled && self.curRunning);
        if ([pip respondsToSelector:@selector(setRequiresLinearPlayback:)]) {
            pip.requiresLinearPlayback = YES;
        }
        self.pipController = pip;
    }

    if (!self.renderTimer) {
        self.renderTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(onRenderTick)
                                                          userInfo:nil
                                                           repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.renderTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)onRenderTick {
    self.pulseToggle = !self.pulseToggle;
    [self enqueueHudSampleFrame];
}

- (void)updateWithRunning:(BOOL)running
                    phase:(NSString *)phase
                    model:(NSString *)model
             repliedCount:(NSInteger)repliedCount
               statusLine:(NSString *)statusLine {
    [self.stateLock lock];
    BOOL changedRun = (_curRunning != running);
    _curRunning = running;
    _curPhase = [phase ?: @"idle" copy];
    if (model.length > 0) _curModel = [model copy];
    _curRepliedCount = repliedCount;
    if (statusLine.length > 0) _curStatusLine = [statusLine copy];
    [self.stateLock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pipController) {
            self.pipController.canStartPictureInPictureAutomaticallyFromInline =
                ([MitaConfigStore shared].floatingHudEnabled && running);
            if (changedRun) {
                [self.pipController invalidatePlaybackState];
            }
        }
        [self enqueueHudSampleFrame];
    });
}

- (void)syncPlaybackState {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pipController) {
            self.pipController.canStartPictureInPictureAutomaticallyFromInline =
                ([MitaConfigStore shared].floatingHudEnabled && self.curRunning);
            [self.pipController invalidatePlaybackState];
        }
        [self enqueueHudSampleFrame];
    });
}

- (BOOL)startFloatingWindow {
    if (!self.pipController) return NO;
    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];
    [self enqueueHudSampleFrame];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        if (!self.pipController.isPictureInPictureActive) {
            [self.pipController startPictureInPicture];
        }
    });
    return YES;
}

- (void)stopFloatingWindow {
    if (!self.pipController) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
        if (self.pipController.isPictureInPictureActive) {
            [self.pipController stopPictureInPicture];
        }
    });
}

#pragma mark - High-DPI HUD Frame Renderer (520x168 Compact Capsule)

- (void)enqueueHudSampleFrame {
    if (!self.sampleLayer) return;
    if (self.sampleLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.sampleLayer flush];
    }

    [self.stateLock lock];
    BOOL running = self.curRunning;
    NSString *phase = self.curPhase ?: @"idle";
    NSString *model = self.curModel ?: @"grok-4.7";
    NSInteger repliedCnt = self.curRepliedCount;
    NSString *line = self.curStatusLine ?: @"等待启动";
    BOOL pulse = self.pulseToggle;
    [self.stateLock unlock];

    const int width = 520;
    const int height = 168;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pxBuf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pxBuf);
    if (status != kCVReturnSuccess || !pxBuf) return;

    CVPixelBufferLockBaseAddress(pxBuf, 0);
    void *baseAddr = CVPixelBufferGetBaseAddress(pxBuf);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxBuf);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        baseAddr, width, height, 8, bytesPerRow, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );

    if (ctx) {
        // 翻轉為標準 UIKit 左上角原點坐標系
        CGContextTranslateCTM(ctx, 0, height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        UIGraphicsPushContext(ctx);

        // 背景深色通透質感
        UIColor *bgCol = running
            ? [UIColor colorWithRed:0.06 green:0.09 blue:0.13 alpha:1.0]
            : [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:1.0];
        [bgCol setFill];
        UIRectFill(CGRectMake(0, 0, width, height));

        // 頂部狀態強調細線
        BOOL isThinking = ([phase isEqualToString:@"replying"] || [phase isEqualToString:@"analyzing"]);
        UIColor *accentCol = !running
            ? [UIColor colorWithRed:0.58 green:0.64 blue:0.72 alpha:1.0]
            : (isThinking
                ? [UIColor colorWithRed:0.22 green:0.74 blue:0.97 alpha:1.0]
                : [UIColor colorWithRed:0.06 green:0.76 blue:0.44 alpha:1.0]);

        [accentCol setFill];
        UIRectFill(CGRectMake(0, 0, width, 5.0));

        // 呼吸圓點
        CGFloat dotAlpha = running ? (pulse ? 1.0 : 0.45) : 0.7;
        if (running && pulse) {
            [[accentCol colorWithAlphaComponent:0.24] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(20.0, 22.0, 26.0, 26.0)] fill];
        }
        [[accentCol colorWithAlphaComponent:dotAlpha] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(26.0, 28.0, 14.0, 14.0)] fill];

        // 主標題
        NSString *headline = !running
            ? @"米塔 · 自动回复已暂停"
            : (isThinking ? @"米塔 · API 正在回复中" : @"米塔 · 自动回复运行中");
        NSDictionary *headAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:23.0],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [headline drawInRect:CGRectMake(50.0, 20.0, 300.0, 32.0) withAttributes:headAttrs];

        // 右上角計數膠囊
        NSString *badgeTxt = [NSString stringWithFormat:@"已回 %ld", (long)repliedCnt];
        NSDictionary *badgeAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: accentCol
        };
        CGSize bSz = [badgeTxt sizeWithAttributes:badgeAttrs];
        CGRect pillRect = CGRectMake(width - bSz.width - 42.0, 20.0, bSz.width + 22.0, 30.0);
        [[accentCol colorWithAlphaComponent:0.16] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:pillRect cornerRadius:15.0] fill];
        [badgeTxt drawAtPoint:CGPointMake(pillRect.origin.x + 11.0, pillRect.origin.y + 4.0) withAttributes:badgeAttrs];

        // 副標題：當前模型
        NSString *subModel = [NSString stringWithFormat:@"API 模型：%@", model];
        NSDictionary *subAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:17.5 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.62 green:0.69 blue:0.78 alpha:1.0]
        };
        [subModel drawInRect:CGRectMake(24.0, 62.0, width - 48.0, 25.0) withAttributes:subAttrs];

        // 底部實況文字（單行省略或雙行）
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        ps.lineSpacing = 2.0;
        NSDictionary *lineAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:19.0 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.91 green:0.95 blue:0.99 alpha:1.0],
            NSParagraphStyleAttributeName: ps
        };
        [line drawInRect:CGRectMake(24.0, 96.0, width - 48.0, 56.0) withAttributes:lineAttrs];

        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pxBuf, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pxBuf, &fmt) == noErr && fmt) {
        CMSampleTimingInfo timing;
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.duration = CMTimeMake(1, 1);
        timing.decodeTimeStamp = kCMTimeInvalid;

        CMSampleBufferRef sbuf = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pxBuf, fmt, &timing, &sbuf) == noErr && sbuf) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, true);
            if (attachments && CFArrayGetCount(attachments) > 0) {
                CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
            [self.sampleLayer enqueueSampleBuffer:sbuf];
            CFRelease(sbuf);
        }
        CFRelease(fmt);
    }
    CVPixelBufferRelease(pxBuf);
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing {
    [[MitaAiGroupEngine shared] setAutoReplyRunning:playing launchWeChat:NO triggerSource:@"pip_hud"];
    [pictureInPictureController invalidatePlaybackState];
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController {
    return !self.curRunning;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
         didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    if (completionHandler) completionHandler(YES);
}

@end
