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
@property (nonatomic, assign) double flowPhase;
@property (nonatomic, assign) BOOL curRunning;
@property (nonatomic, assign) NSTimeInterval curStartedAtTs;
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
        _flowPhase = 0.0;
        _curRunning = NO;
        _curStartedAtTs = 0.0;
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

    [[MitaKeepAliveAndControl shared] startSilentKeepAlive];

    UIView *anchor = [[UIView alloc] initWithFrame:CGRectMake(12.0, 56.0, 260.0, 88.0)];
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
        // 10fps 丝滑驱动四周控制流光边缘与实时秒表跳动
        self.renderTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                            target:self
                                                          selector:@selector(onRenderTick)
                                                          userInfo:nil
                                                           repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.renderTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)onRenderTick {
    [self.stateLock lock];
    BOOL running = self.curRunning;
    BOOL thinking = ([self.curPhase isEqualToString:@"replying"] || [self.curPhase isEqualToString:@"analyzing"]);
    if (running) {
        self.flowPhase += (thinking ? 0.048 : 0.024);
        if (self.flowPhase >= 1.0) self.flowPhase -= 1.0;
    }
    [self.stateLock unlock];

    // 运行中每 0.1s 刷新流光边缘动画；未运行时每 1.0s 低功耗保活刷新
    static int idleSkip = 0;
    if (!running) {
        idleSkip = (idleSkip + 1) % 10;
        if (idleSkip != 0) return;
    }
    [self enqueueHudSampleFrame];
}

- (void)updateWithRunning:(BOOL)running
              startedAtTs:(NSTimeInterval)startedAtTs
                    phase:(NSString *)phase
                    model:(NSString *)model
             repliedCount:(NSInteger)repliedCount
               statusLine:(NSString *)statusLine {
    [self.stateLock lock];
    BOOL changedRun = (_curRunning != running);
    _curRunning = running;
    if (running) {
        if (startedAtTs > 0) _curStartedAtTs = startedAtTs;
        else if (_curStartedAtTs <= 0) _curStartedAtTs = [[NSDate date] timeIntervalSince1970];
    } else {
        _curStartedAtTs = 0.0;
    }
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

static CGPoint pointOnRectPerimeter(CGRect r, double t) {
    while (t < 0.0) t += 1.0;
    while (t >= 1.0) t -= 1.0;
    double w = r.size.width;
    double h = r.size.height;
    double perim = 2.0 * (w + h);
    double d = t * perim;
    if (d <= w) return CGPointMake(r.origin.x + d, r.origin.y);
    d -= w;
    if (d <= h) return CGPointMake(r.origin.x + w, r.origin.y + d);
    d -= h;
    if (d <= w) return CGPointMake(r.origin.x + w - d, r.origin.y + h);
    d -= w;
    return CGPointMake(r.origin.x, r.origin.y + h - d);
}

static NSString *formatDurationText(NSInteger sec) {
    if (sec < 0) sec = 0;
    NSInteger h = sec / 3600;
    NSInteger m = (sec % 3600) / 60;
    NSInteger s = sec % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

#pragma mark - High-DPI Animated Edge & Timer Renderer (520x176)

- (void)enqueueHudSampleFrame {
    if (!self.sampleLayer) return;
    if (self.sampleLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.sampleLayer flush];
    }

    [self.stateLock lock];
    BOOL running = self.curRunning;
    NSTimeInterval startTs = self.curStartedAtTs;
    NSString *phase = self.curPhase ?: @"idle";
    NSString *model = self.curModel ?: @"grok-4.7";
    NSInteger repliedCnt = self.curRepliedCount;
    NSString *line = self.curStatusLine ?: @"等待启动";
    double flow = self.flowPhase;
    [self.stateLock unlock];

    NSInteger elapsedSec = (running && startTs > 0) ? MAX(0, (NSInteger)llround([[NSDate date] timeIntervalSince1970] - startTs)) : 0;
    NSString *timerStr = formatDurationText(elapsedSec);

    const int width = 520;
    const int height = 176;

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
        CGContextTranslateCTM(ctx, 0, height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        UIGraphicsPushContext(ctx);

        UIColor *bgCol = running
            ? [UIColor colorWithRed:0.05 green:0.08 blue:0.13 alpha:1.0]
            : [UIColor colorWithRed:0.11 green:0.13 blue:0.17 alpha:1.0];
        [bgCol setFill];
        UIRectFill(CGRectMake(0, 0, width, height));

        BOOL isThinking = ([phase isEqualToString:@"replying"] || [phase isEqualToString:@"analyzing"] || [phase isEqualToString:@"entering"]);
        UIColor *accentCol = !running
            ? [UIColor colorWithRed:0.56 green:0.63 blue:0.72 alpha:1.0]
            : (isThinking
                ? [UIColor colorWithRed:0.22 green:0.74 blue:0.98 alpha:1.0]
                : [UIColor colorWithRed:0.04 green:0.82 blue:0.46 alpha:1.0]);

        CGRect edgeRect = CGRectMake(3.5, 3.5, width - 7.0, height - 7.0);
        if (running) {
            // 1. 柔和发光边缘底轨
            UIBezierPath *baseTrack = [UIBezierPath bezierPathWithRoundedRect:edgeRect cornerRadius:18.0];
            baseTrack.lineWidth = 4.5;
            [[accentCol colorWithAlphaComponent:0.24] setStroke];
            [baseTrack stroke];

            // 2. 四周旋转追光控制动画（28 段渐变彗星灯带顺时针游走整圈边缘）
            const int segs = 28;
            const double tailSpan = 0.42;
            for (int i = 0; i < segs; i++) {
                double frac0 = (double)i / (double)segs;
                double frac1 = (double)(i + 1) / (double)segs;
                double t0 = flow - tailSpan * (1.0 - frac0);
                double t1 = flow - tailSpan * (1.0 - frac1);
                CGPoint p0 = pointOnRectPerimeter(edgeRect, t0);
                CGPoint p1 = pointOnRectPerimeter(edgeRect, t1);

                UIBezierPath *segPath = [UIBezierPath bezierPath];
                [segPath moveToPoint:p0];
                [segPath addLineToPoint:p1];
                segPath.lineWidth = 5.5 + 2.5 * frac1;
                segPath.lineCapStyle = kCGLineCapRound;

                UIColor *segCol = isThinking
                    ? [UIColor colorWithRed:(0.15 + 0.30 * frac1) green:(0.62 + 0.28 * frac1) blue:0.99 alpha:(0.12 + 0.88 * frac1)]
                    : [UIColor colorWithRed:(0.03 + 0.15 * frac1) green:(0.72 + 0.25 * frac1) blue:(0.42 + 0.42 * frac1) alpha:(0.12 + 0.88 * frac1)];
                [segCol setStroke];
                [segPath stroke];
            }

            // 追光头部高光星点
            CGPoint headPt = pointOnRectPerimeter(edgeRect, flow);
            [[accentCol colorWithAlphaComponent:0.35] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(headPt.x - 9.0, headPt.y - 9.0, 18.0, 18.0)] fill];
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(headPt.x - 3.5, headPt.y - 3.5, 7.0, 7.0)] fill];
        } else {
            UIBezierPath *idleBorder = [UIBezierPath bezierPathWithRoundedRect:edgeRect cornerRadius:18.0];
            idleBorder.lineWidth = 2.0;
            [[UIColor colorWithWhite:1.0 alpha:0.12] setStroke];
            [idleBorder stroke];
        }

        // 左侧状态呼吸灯
        double pulseWave = 0.55 + 0.45 * sin(flow * M_PI * 2.0);
        if (running) {
            [[accentCol colorWithAlphaComponent:(0.18 + 0.18 * pulseWave)] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(20.0, 22.0, 26.0, 26.0)] fill];
        }
        [[accentCol colorWithAlphaComponent:(running ? (0.75 + 0.25 * pulseWave) : 0.65)] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(26.0, 28.0, 14.0, 14.0)] fill];

        // 主标题
        NSString *headline = !running
            ? @"米塔 · 控制未启动"
            : (isThinking ? @"AI 控制回复中" : @"AI 控制启动中");
        NSDictionary *headAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:23.0],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [headline drawInRect:CGRectMake(50.0, 20.0, 240.0, 32.0) withAttributes:headAttrs];

        // 右上角醒目实时计时 + 回复数胶囊
        NSString *badgeTxt = running
            ? [NSString stringWithFormat:@"⏱ %@ · 已回 %ld", timerStr, (long)repliedCnt]
            : [NSString stringWithFormat:@"待命 · 已回 %ld", (long)repliedCnt];
        NSDictionary *badgeAttrs = @{
            NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:17.5 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: running ? [UIColor whiteColor] : accentCol
        };
        CGSize bSz = [badgeTxt sizeWithAttributes:badgeAttrs];
        CGRect pillRect = CGRectMake(width - bSz.width - 42.0, 19.0, bSz.width + 22.0, 32.0);
        [[accentCol colorWithAlphaComponent:(running ? 0.30 : 0.15)] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:pillRect cornerRadius:16.0] fill];
        [badgeTxt drawAtPoint:CGPointMake(pillRect.origin.x + 11.0, pillRect.origin.y + 5.0) withAttributes:badgeAttrs];

        // 副标题：实时 API 模型
        NSString *subModel = [NSString stringWithFormat:@"实时 API：%@", model];
        NSDictionary *subAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: accentCol
        };
        [subModel drawInRect:CGRectMake(24.0, 62.0, width - 48.0, 24.0) withAttributes:subAttrs];

        // 底部实况文字
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        ps.lineSpacing = 2.0;
        NSDictionary *lineAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:18.5 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.92 green:0.95 blue:0.99 alpha:1.0],
            NSParagraphStyleAttributeName: ps
        };
        [line drawInRect:CGRectMake(24.0, 96.0, width - 48.0, 60.0) withAttributes:lineAttrs];

        UIGraphicsPopContext();
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pxBuf, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pxBuf, &fmt) == noErr && fmt) {
        CMSampleTimingInfo timing;
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.duration = CMTimeMake(1, 10);
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
