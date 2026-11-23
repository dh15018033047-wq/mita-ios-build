#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <sys/stat.h>
#import <math.h>

#define MITA_NOTIFY_EDGE_CHANGED "com.mita.phoneagent.edge.changed"
#define MITA_NOTIFY_EDGE_EXIT    "com.mita.phoneagent.edge.exit"
#define MITA_NOTIFY_LOCKSTATE    "com.apple.springboard.lockstate"

static NSString *gStateFilePath = nil;
static NSString *gDiagFilePath  = nil;
static NSString *gPidFilePath   = nil;

#pragma mark - Jetsam Priority Helper (Dynamic Safe Lookup)

typedef struct {
    int32_t priority;
    uint64_t user_data;
} mita_memorystatus_priority_props_t;

static void MitaRelaxJetsamLimits(pid_t pid) {
    typedef int (*MemCtlFn)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
    MemCtlFn fn = (MemCtlFn)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!fn) return;
    mita_memorystatus_priority_props_t props = { 19 /* JETSAM_PRIORITY_CRITICAL */, 0 };
    fn(1 /* MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES */, pid, 0, &props, sizeof(props));
    fn(5 /* MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK */, pid, (uint32_t)-1, NULL, 0);
    fn(6 /* MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT */, pid, 0, NULL, 0);
}

#pragma mark - Passthrough System-Wide Overlay Window

@interface MitaEdgeWindow : UIWindow
@end

@implementation MitaEdgeWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }

@end

#pragma mark - Pocket-Style Flowing Blue Ocean Wave Edge View

@interface MitaEdgeWaveView : UIView
@property (nonatomic, assign) double phase;
@property (nonatomic, assign) BOOL activeControl;
@property (nonatomic, assign) BOOL activeReplying;
@property (nonatomic, assign) NSTimeInterval startedAtTs;
@property (nonatomic, assign) CGFloat masterOpacity;
@property (nonatomic, assign) uint64_t renderedFrames;
@end

@implementation MitaEdgeWaveView {
    CGGradientRef _ambientGrad;
    CGGradientRef _replyAmbientGrad;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        _phase = 0.0;
        _masterOpacity = 0.0;

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat locs[3] = { 0.0, 0.42, 1.0 };
        // 常态控制：深海皇家蓝 -> 电光天青蓝 -> 完全透明
        CGFloat compsNormal[12] = {
            0.00, 0.48, 1.00, 0.64,
            0.06, 0.72, 1.00, 0.25,
            0.20, 0.85, 1.00, 0.00
        };
        _ambientGrad = CGGradientCreateWithColorComponents(cs, compsNormal, locs, 3);

        // API 实时回复/高频控机：高亮电光冰蓝 -> 霓虹青蓝 -> 完全透明
        CGFloat compsReply[12] = {
            0.04, 0.62, 1.00, 0.76,
            0.16, 0.84, 1.00, 0.32,
            0.35, 0.92, 1.00, 0.00
        };
        _replyAmbientGrad = CGGradientCreateWithColorComponents(cs, compsReply, locs, 3);
        CGColorSpaceRelease(cs);
    }
    return self;
}

- (void)dealloc {
    if (_ambientGrad) CGGradientRelease(_ambientGrad);
    if (_replyAmbientGrad) CGGradientRelease(_replyAmbientGrad);
}

static NSString *MitaFormatTimer(NSInteger sec) {
    if (sec < 0) sec = 0;
    NSInteger h = sec / 3600;
    NSInteger m = (sec % 3600) / 60;
    NSInteger s = sec % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

// 计算沿着某条边坐标 s 处的双波叠加深度
static inline CGFloat WaveDepthPrimary(CGFloat s, double ph, BOOL lively) {
    double base = lively ? 10.5 : 8.6;
    double a1   = lively ? 5.2  : 4.1;
    double a2   = lively ? 2.9  : 2.2;
    double v = base
             + a1 * sin((double)s * 0.048 - ph * 4.2)
             + a2 * cos((double)s * 0.108 - ph * 2.5 + 1.15);
    return (CGFloat)MAX(2.5, v);
}

static inline CGFloat WaveDepthSecondary(CGFloat s, double ph, BOOL lively) {
    double base = lively ? 6.4 : 5.2;
    double a1   = lively ? 3.5 : 2.8;
    double a2   = lively ? 1.9 : 1.4;
    double v = base
             + a1 * sin((double)s * 0.074 + ph * 3.6 + 0.75)
             + a2 * sin((double)s * 0.155 - ph * 5.6);
    return (CGFloat)MAX(1.8, v);
}

- (void)drawWaveRibbonInContext:(CGContextRef)ctx
                         bounds:(CGRect)b
                      secondary:(BOOL)isSecondary
                         lively:(BOOL)lively
                          alpha:(CGFloat)alphaMul {
    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    CGFloat step = 6.0;
    double ph = self.phase;

    // 1. 顶部波浪带 (y: 0 -> depth)
    CGMutablePathRef topPath = CGPathCreateMutable();
    CGPathMoveToPoint(topPath, NULL, 0, 0);
    CGPathAddLineToPoint(topPath, NULL, W, 0);
    for (CGFloat x = W; x >= 0; x -= step) {
        CGFloat s = x;
        CGFloat d = isSecondary ? WaveDepthSecondary(s, ph, lively) : WaveDepthPrimary(s, ph, lively);
        CGPathAddLineToPoint(topPath, NULL, x, d);
    }
    CGPathAddLineToPoint(topPath, NULL, 0, isSecondary ? WaveDepthSecondary(0, ph, lively) : WaveDepthPrimary(0, ph, lively));
    CGPathCloseSubpath(topPath);

    // 2. 右侧波浪带 (x: W -> W - depth)
    CGMutablePathRef rightPath = CGPathCreateMutable();
    CGPathMoveToPoint(rightPath, NULL, W, 0);
    CGPathAddLineToPoint(rightPath, NULL, W, H);
    for (CGFloat y = H; y >= 0; y -= step) {
        CGFloat s = W + y;
        CGFloat d = isSecondary ? WaveDepthSecondary(s, ph, lively) : WaveDepthPrimary(s, ph, lively);
        CGPathAddLineToPoint(rightPath, NULL, W - d, y);
    }
    CGPathCloseSubpath(rightPath);

    // 3. 底部波浪带 (y: H -> H - depth*0.72，保护微信底部 y=708~714 输入与绿发送键采样点)
    CGMutablePathRef botPath = CGPathCreateMutable();
    CGPathMoveToPoint(botPath, NULL, W, H);
    CGPathAddLineToPoint(botPath, NULL, 0, H);
    for (CGFloat x = 0; x <= W; x += step) {
        CGFloat s = W + H + (W - x);
        CGFloat rawD = isSecondary ? WaveDepthSecondary(s, ph, lively) : WaveDepthPrimary(s, ph, lively);
        CGFloat d = MIN(13.5, rawD * 0.72);
        CGPathAddLineToPoint(botPath, NULL, x, H - d);
    }
    CGPathCloseSubpath(botPath);

    // 4. 左侧波浪带 (x: 0 -> depth)
    CGMutablePathRef leftPath = CGPathCreateMutable();
    CGPathMoveToPoint(leftPath, NULL, 0, H);
    CGPathAddLineToPoint(leftPath, NULL, 0, 0);
    for (CGFloat y = 0; y <= H; y += step) {
        CGFloat s = 2.0 * W + H + (H - y);
        CGFloat d = isSecondary ? WaveDepthSecondary(s, ph, lively) : WaveDepthPrimary(s, ph, lively);
        CGPathAddLineToPoint(leftPath, NULL, d, y);
    }
    CGPathCloseSubpath(leftPath);

    CGContextSaveGState(ctx);
    if (isSecondary) {
        // 冰晶亮青蓝波峰层
        CGContextSetRGBFillColor(ctx, 0.24, 0.82, 1.00, 0.62 * alphaMul);
    } else {
        // 主力深海电光蓝海浪层
        CGContextSetRGBFillColor(ctx, 0.02, 0.56, 1.00, 0.52 * alphaMul);
    }
    CGContextAddPath(ctx, topPath);
    CGContextFillPath(ctx);
    CGContextAddPath(ctx, rightPath);
    CGContextFillPath(ctx);
    CGContextAddPath(ctx, botPath);
    CGContextFillPath(ctx);
    CGContextAddPath(ctx, leftPath);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);

    CGPathRelease(topPath);
    CGPathRelease(rightPath);
    CGPathRelease(botPath);
    CGPathRelease(leftPath);
}

- (void)drawRect:(CGRect)rect {
    if (self.masterOpacity <= 0.01) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGRect b = self.bounds;
    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    if (W < 10 || H < 10) return;

    BOOL lively = self.activeReplying;
    CGFloat op = self.masterOpacity;
    double breath = 0.86 + 0.14 * sin(self.phase * 2.4);
    CGFloat glowDepth = (CGFloat)((lively ? 26.0 : 21.0) * breath);
    CGFloat botGlowDepth = MIN(16.0, glowDepth * 0.70);

    CGGradientRef grad = lively ? _replyAmbientGrad : _ambientGrad;
    if (grad) {
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, op);

        // Top glow
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, 0, W, glowDepth));
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(W * 0.5, 0), CGPointMake(W * 0.5, glowDepth), 0);
        CGContextRestoreGState(ctx);

        // Bottom glow
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, H - botGlowDepth, W, botGlowDepth));
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(W * 0.5, H), CGPointMake(W * 0.5, H - botGlowDepth), 0);
        CGContextRestoreGState(ctx);

        // Left glow
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, 0, glowDepth, H));
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, H * 0.5), CGPointMake(glowDepth, H * 0.5), 0);
        CGContextRestoreGState(ctx);

        // Right glow
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(W - glowDepth, 0, glowDepth, H));
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(W, H * 0.5), CGPointMake(W - glowDepth, H * 0.5), 0);
        CGContextRestoreGState(ctx);

        CGContextRestoreGState(ctx);
    }

    // 绘制双层交错流动的蓝色海浪（主海浪 + 冰晶高光次海浪）
    [self drawWaveRibbonInContext:ctx bounds:b secondary:NO lively:lively alpha:op];
    [self drawWaveRibbonInContext:ctx bounds:b secondary:YES lively:lively alpha:op];

    // 最外圈屏幕玻璃霓虹冰蓝能量细边
    CGContextSaveGState(ctx);
    UIBezierPath *outerRim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 1.2, 1.2) cornerRadius:8.0];
    outerRim.lineWidth = 2.6;
    [[UIColor colorWithRed:0.42 green:0.89 blue:1.00 alpha:(0.92 * op)] setStroke];
    [outerRim stroke];
    CGContextRestoreGState(ctx);

    // 顶部状态栏中央极简融波计时微章 (y: 1.5 ~ 18.5，严格位于 20pt 状态栏内，绝不挡任何应用标题)
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger elapsed = (self.startedAtTs > 1000000) ? MAX(0, (NSInteger)llround(now - self.startedAtTs)) : 0;
    NSString *timeTxt = [NSString stringWithFormat:@"%@ %@",
                         lively ? @"⚡ 控制回复" : @"● 控制中",
                         MitaFormatTimer(elapsed)];
    NSDictionary *txtAttrs = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.93 green:0.98 blue:1.00 alpha:op]
    };
    CGSize tSz = [timeTxt sizeWithAttributes:txtAttrs];
    CGFloat pillW = tSz.width + 16.0;
    CGFloat pillH = 16.5;
    CGRect pillRect = CGRectMake((W - pillW) * 0.5, 2.0, pillW, pillH);

    UIBezierPath *pillPath = [UIBezierPath bezierPathWithRoundedRect:pillRect cornerRadius:pillH * 0.5];
    [[UIColor colorWithRed:0.01 green:0.15 blue:0.38 alpha:(0.84 * op)] setFill];
    [pillPath fill];
    pillPath.lineWidth = 1.0;
    [[UIColor colorWithRed:0.45 green:0.88 blue:1.00 alpha:(0.82 * op)] setStroke];
    [pillPath stroke];

    [timeTxt drawAtPoint:CGPointMake(pillRect.origin.x + 8.0, pillRect.origin.y + (pillH - tSz.height) * 0.5)
          withAttributes:txtAttrs];

    self.renderedFrames += 1;
}

@end

#pragma mark - Overlay Root View Controller & IPC Watcher

@interface MitaEdgeRootViewController : UIViewController
@property (nonatomic, strong) MitaEdgeWaveView *waveView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL screenLocked;
@property (nonatomic, assign) unsigned int hostedContextId;
- (void)reloadControlStateNow;
- (void)writeDiagnosticsSnapshot;
@end

@implementation MitaEdgeRootViewController

- (BOOL)prefersStatusBarHidden { return NO; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
    self.view.userInteractionEnabled = NO;

    self.waveView = [[MitaEdgeWaveView alloc] initWithFrame:self.view.bounds];
    self.waveView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.waveView];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayFrame:)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(20, 30, 30);
    } else {
        self.displayLink.preferredFramesPerSecond = 30;
    }
    self.displayLink.paused = YES;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    __weak typeof(self) weakSelf = self;
    int edgeToken = 0;
    notify_register_dispatch(MITA_NOTIFY_EDGE_CHANGED, &edgeToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf reloadControlStateNow];
    });

    int lockToken = 0;
    notify_register_dispatch(MITA_NOTIFY_LOCKSTATE, &lockToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf updateLockStatus];
    });

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(onPollTick)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];

    [self reloadControlStateNow];
}

- (void)updateLockStatus {
    typedef mach_port_t (*SBPortFn)(void);
    typedef void (*SBLockFn)(mach_port_t, BOOL *, BOOL *);
    SBPortFn pPort = (SBPortFn)dlsym(RTLD_DEFAULT, "SBSSpringBoardServerPort");
    SBLockFn pLock = (SBLockFn)dlsym(RTLD_DEFAULT, "SBGetScreenLockStatus");
    if (pPort && pLock) {
        mach_port_t port = pPort();
        if (port != 0) {
            BOOL locked = NO, pass = NO;
            pLock(port, &locked, &pass);
            self.screenLocked = locked;
            if (locked) {
                self.displayLink.paused = YES;
                self.view.hidden = YES;
            } else {
                self.view.hidden = NO;
                [self reloadControlStateNow];
            }
        }
    }
}

- (void)onPollTick {
    [self reloadControlStateNow];
    [self writeDiagnosticsSnapshot];
}

- (void)writeDiagnosticsSnapshot {
    if (gDiagFilePath.length == 0) return;
    NSDictionary *diag = @{
        @"pid": @(getpid()),
        @"uid": @(getuid()),
        @"context_id": @(self.hostedContextId),
        @"active_control": @(self.waveView.activeControl),
        @"active_replying": @(self.waveView.activeReplying),
        @"opacity": @(self.waveView.masterOpacity),
        @"rendered_frames": @(self.waveView.renderedFrames),
        @"ts": @((NSInteger)[[NSDate date] timeIntervalSince1970])
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:diag options:0 error:nil];
    if (d) {
        [d writeToFile:gDiagFilePath atomically:YES];
        chmod([gDiagFilePath UTF8String], 0666);
    }
}

- (void)reloadControlStateNow {
    if (self.screenLocked) return;

    NSDictionary *state = nil;
    if (gStateFilePath.length > 0) {
        NSData *raw = [NSData dataWithContentsOfFile:gStateFilePath];
        if (raw.length > 0) {
            id obj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                state = (NSDictionary *)obj;
            }
        }
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL edgeEnabled = state[@"edge_enabled"] ? [state[@"edge_enabled"] boolValue] : YES;
    BOOL botRunning = [state[@"running"] boolValue];
    NSTimeInterval pulseUntil = [state[@"pulse_until"] doubleValue];
    NSTimeInterval updatedAt = [state[@"updated_at"] doubleValue];

    // 若状态文件超过 25 秒未刷新（例如主 App 被手动划掉强退），自动通过本机 19080 核实存活避免残留
    if (botRunning && updatedAt > 0 && (now - updatedAt) > 25.0) {
        NSURL *u = [NSURL URLWithString:@"http://127.0.0.1:19080/status"];
        NSURLRequest *req = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:0.45];
        __block BOOL checkedOk = NO;
        __block BOOL liveRun = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (!e && d) {
                id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([o isKindOfClass:[NSDictionary class]]) {
                    checkedOk = YES;
                    liveRun = [o[@"bot_running"] boolValue];
                }
            }
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
        if (!checkedOk || !liveRun) {
            botRunning = NO;
        }
    }

    BOOL hasPulse = (pulseUntil > now);
    BOOL shouldShow = edgeEnabled && (botRunning || hasPulse);
    NSString *phaseStr = [state[@"phase"] isKindOfClass:[NSString class]] ? state[@"phase"] : @"idle";
    BOOL isLively = hasPulse
                 || [phaseStr isEqualToString:@"replying"]
                 || [phaseStr isEqualToString:@"analyzing"]
                 || [phaseStr isEqualToString:@"entering"]
                 || [phaseStr isEqualToString:@"controlling"];

    NSTimeInterval startTs = [state[@"started_at"] doubleValue];
    if (shouldShow && startTs <= 0) {
        startTs = self.waveView.startedAtTs > 0 ? self.waveView.startedAtTs : now;
    } else if (!shouldShow) {
        startTs = 0;
    }

    self.waveView.activeControl = shouldShow;
    self.waveView.activeReplying = isLively;
    self.waveView.startedAtTs = startTs;

    if (shouldShow || self.waveView.masterOpacity > 0.01) {
        self.displayLink.paused = NO;
    }
}

- (void)onDisplayFrame:(CADisplayLink *)link {
    BOOL want = self.waveView.activeControl && !self.screenLocked;
    CGFloat cur = self.waveView.masterOpacity;
    if (want) {
        cur = MIN(1.0, cur + 0.12);
    } else {
        cur = MAX(0.0, cur - 0.10);
    }
    self.waveView.masterOpacity = cur;

    if (cur <= 0.005 && !want) {
        self.waveView.masterOpacity = 0.0;
        [self.waveView setNeedsDisplay];
        self.displayLink.paused = YES;
        return;
    }

    double speed = self.waveView.activeReplying ? 0.052 : 0.030;
    self.waveView.phase += speed;
    if (self.waveView.phase > 10000.0) {
        self.waveView.phase -= 10000.0;
    }
    [self.waveView setNeedsDisplay];
}

@end

#pragma mark - Plugin Application & Window Hosting Delegate

@interface MitaEdgeApplication : UIApplication
@end

@implementation MitaEdgeApplication

- (instancetype)init {
    if (self = [super init]) {
        int exitTok = 0;
        notify_register_dispatch(MITA_NOTIFY_EDGE_EXIT, &exitTok, dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            exit(0);
        });

        @try {
            id dispatcher = [self valueForKey:@"eventDispatcher"];
            SEL installSel = NSSelectorFromString(@"_installEventRunLoopSources:");
            if (dispatcher && [dispatcher respondsToSelector:installSel]) {
                ((void (*)(id, SEL, CFRunLoopRef))objc_msgSend)(dispatcher, installSel, CFRunLoopGetMain());
            }
        } @catch (NSException *ex) {}
    }
    return self;
}

@end

@interface MitaEdgeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) MitaEdgeWindow *window;
@property (nonatomic, strong) MitaEdgeRootViewController *rootVC;
@property (nonatomic, strong) id windowHostingController;
@end

@implementation MitaEdgeAppDelegate

- (void)registerSystemOverlayWindow {
    if (!self.window) return;
    Class hostCls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostCls) return;
    if (!self.windowHostingController) {
        self.windowHostingController = [[hostCls alloc] init];
    }
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if ([self.window respondsToSelector:ctxSel] && [self.windowHostingController respondsToSelector:regSel]) {
        unsigned int ctxId = ((unsigned int (*)(id, SEL))objc_msgSend)(self.window, ctxSel);
        double level = self.window.windowLevel;
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:self.windowHostingController];
            [inv setSelector:regSel];
            [inv setArgument:&ctxId atIndex:2];
            [inv setArgument:&level atIndex:3];
            [inv invoke];
            self.rootVC.hostedContextId = ctxId;
        }
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.rootVC = [[MitaEdgeRootViewController alloc] init];
    self.window = [[MitaEdgeWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.opaque = NO;
    self.window.userInteractionEnabled = NO;
    self.window.rootViewController = self.rootVC;
    self.window.windowLevel = 10000010.0;
    self.window.hidden = NO;
    [self.window makeKeyAndVisible];

    [self registerSystemOverlayWindow];

    __weak typeof(self) weakSelf = self;
    static int sbBootToken = 0;
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &sbBootToken, dispatch_get_main_queue(), ^(int token) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf registerSystemOverlayWindow];
        });
    });

    [self.rootVC writeDiagnosticsSnapshot];
    return YES;
}

@end

#pragma mark - Entry Point

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *sharedDir = @"/var/mobile/Library/Caches";
        if (argc >= 3 && argv[2] != NULL && strlen(argv[2]) > 1) {
            sharedDir = [NSString stringWithUTF8String:argv[2]];
        }
        gStateFilePath = [sharedDir stringByAppendingPathComponent:@"mita_edge_state.json"];
        gDiagFilePath  = [sharedDir stringByAppendingPathComponent:@"mita_edge_diag.json"];
        gPidFilePath   = [sharedDir stringByAppendingPathComponent:@"mita_edge_overlay.pid"];

        const char *mode = (argc >= 2 && argv[1] != NULL) ? argv[1] : "-hud";

        if (strcmp(mode, "-exit") == 0) {
            notify_post(MITA_NOTIFY_EDGE_EXIT);
            NSString *pidStr = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
            if (pidStr.length > 0) {
                pid_t oldPid = (pid_t)[pidStr intValue];
                if (oldPid > 1) kill(oldPid, SIGKILL);
                unlink([gPidFilePath UTF8String]);
            }
            return 0;
        }

        if (strcmp(mode, "-check") == 0) {
            NSString *pidStr = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
            if (pidStr.length > 0) {
                pid_t oldPid = (pid_t)[pidStr intValue];
                if (oldPid > 1 && kill(oldPid, 0) == 0) {
                    return 1;
                }
            }
            return 0;
        }

        // 启动新实例前，若已有旧 PID 存活先清理，确保全屏永远单实例无重影
        NSString *prevPidStr = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
        if (prevPidStr.length > 0) {
            pid_t prevPid = (pid_t)[prevPidStr intValue];
            if (prevPid > 1 && prevPid != getpid() && kill(prevPid, 0) == 0) {
                kill(prevPid, SIGKILL);
                usleep(80000);
            }
        }

        pid_t me = getpid();
        MitaRelaxJetsamLimits(me);

        NSString *myPidStr = [NSString stringWithFormat:@"%d", me];
        [myPidStr writeToFile:gPidFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([gPidFilePath UTF8String], 0666);

        dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

        [UIScreen class];
        CFRunLoopGetCurrent();

        typedef void (*VoidFn)(void);
        typedef void (*BoolFn)(uint8_t);
        typedef void (*ModeFn)(CFStringRef);
        typedef void (*InstFn)(Class);

        VoidFn pGSInit = (VoidFn)dlsym(RTLD_DEFAULT, "GSInitialize");
        VoidFn pBKSStart = (VoidFn)dlsym(RTLD_DEFAULT, "BKSDisplayServicesStart");
        VoidFn pUIAppInit = (VoidFn)dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
        InstFn pUIAppInst = (InstFn)dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
        BoolFn pGSEventInit = (BoolFn)dlsym(RTLD_DEFAULT, "GSEventInitialize");
        ModeFn pGSEventPush = (ModeFn)dlsym(RTLD_DEFAULT, "GSEventPushRunLoopMode");

        if (pGSInit) pGSInit();
        if (pBKSStart) pBKSStart();
        if (pUIAppInit) pUIAppInit();
        if (pUIAppInst) pUIAppInst([MitaEdgeApplication class]);

        static MitaEdgeAppDelegate *sDelegate = nil;
        sDelegate = [[MitaEdgeAppDelegate alloc] init];
        [UIApplication.sharedApplication setDelegate:sDelegate];

        SEL accSel = NSSelectorFromString(@"_accessibilityInit");
        if ([UIApplication.sharedApplication respondsToSelector:accSel]) {
            ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, accSel);
        }

        if (pGSEventInit) pGSEventInit(0);
        if (pGSEventPush) pGSEventPush(kCFRunLoopDefaultMode);

        SEL runPluginSel = NSSelectorFromString(@"__completeAndRunAsPlugin");
        if ([UIApplication.sharedApplication respondsToSelector:runPluginSel]) {
            ((void (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, runPluginSel);
        }

        CFRunLoopRun();
        return 0;
    }
}
