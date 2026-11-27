#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <signal.h>
#import <spawn.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <mach-o/dyld.h>
#import <math.h>

extern char **environ;

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

#pragma mark - Permanent Glow Capsule + On-Demand Shield Overlay Architecture (v5.1.0)

@class MitaEdgeRootViewController;

// 窗口 1：全屏纯视觉与永久常驻胶囊层（朦胧流光 + 虚拟小鼠标 + 思考气泡 + 常驻接管胶囊），_ignoresHitTest = YES 硬件级 100% 永久透传真机手指触摸
@interface MitaGlowWindow : UIWindow
@end

// 窗口 2：按需创建的防误触全屏护盾窗，_ignoresHitTest = NO；仅在 MitaControlModeAiLocked（且非穿窗门控期、未锁屏）时创建，切入 HumanControl 立即置 nil 销毁释放 CAContext！
@interface MitaShieldWindow : UIWindow
@property (nonatomic, weak) MitaEdgeRootViewController *edgeRootVC;
@end

@interface MitaShieldViewController : UIViewController
@end

#pragma mark - AI Virtual Cursor, Tap Ripple, Swipe Trail & Thinking Aura View

@interface MitaAiCursorView : UIView
@property (nonatomic, strong) UIView *pointerContainer;
@property (nonatomic, strong) CAShapeLayer *pointerShadowLayer;
@property (nonatomic, strong) CAShapeLayer *pointerFillLayer;
@property (nonatomic, strong) UIView *tagBadgeView;
@property (nonatomic, strong) UILabel *tagBadgeLabel;

@property (nonatomic, strong) UIView *thinkingRingHost;
@property (nonatomic, strong) CAGradientLayer *thinkingRingGradient;
@property (nonatomic, strong) CAShapeLayer *thinkingRingMask;
@property (nonatomic, strong) CAShapeLayer *thinkingPulseHalo;

@property (nonatomic, strong) UIView *thinkingBubbleView;
@property (nonatomic, strong) UIView *thinkingBorderClipView;
@property (nonatomic, strong) CAGradientLayer *thinkingBorderConic;
@property (nonatomic, strong) CAShapeLayer *thinkingBorderMask;
@property (nonatomic, strong) UIView *sparkleHostView;
@property (nonatomic, strong) CAShapeLayer *sparkleShapeLayer;
@property (nonatomic, strong) UIView *subSparkleHostView;
@property (nonatomic, strong) CAShapeLayer *subSparkleShapeLayer;
@property (nonatomic, strong) UILabel *thinkingLabel;
@property (nonatomic, strong) NSArray<UIView *> *thinkingDots;

@property (nonatomic, assign) CGPoint currentPos;
@property (nonatomic, assign) BOOL cursorVisible;
@property (nonatomic, assign) BOOL persistentInAiMode;
@property (nonatomic, assign) BOOL thinkingActive;
@property (nonatomic, assign) NSTimeInterval lastActivityTs;
@property (nonatomic, copy) NSString *thinkingText;

- (void)ensureVisibleForAiControlAnimated:(BOOL)animated;
- (void)showThinking:(BOOL)active text:(NSString *)text atPoint:(CGPoint)pt hasPoint:(BOOL)hasPt;
- (void)playTapAtPoint:(CGPoint)pt;
- (void)playSwipeFrom:(CGPoint)fromPt to:(CGPoint)toPt duration:(double)dur;
- (void)hideCursorAnimated:(BOOL)animated;
- (void)checkAutoFadeIfIdle;
@end

static CGPoint MitaNormalizePointToBounds(double rawX, double rawY, CGRect b) {
    CGFloat W = MAX(1.0, b.size.width);
    CGFloat H = MAX(1.0, b.size.height);
    CGFloat px = (CGFloat)rawX;
    CGFloat py = (CGFloat)rawY;
    if (rawX >= 0.0 && rawX <= 1.0 && rawY >= 0.0 && rawY <= 1.0) {
        px = (CGFloat)(rawX * W);
        py = (CGFloat)(rawY * H);
    } else if (rawX > W * 1.15 || rawY > H * 1.15) {
        CGFloat sc = MAX(1.0, [UIScreen mainScreen].scale);
        px = (CGFloat)(rawX / sc);
        py = (CGFloat)(rawY / sc);
    }
    px = MAX(6.0, MIN(W - 6.0, px));
    py = MAX(6.0, MIN(H - 6.0, py));
    return CGPointMake(px, py);
}

@implementation MitaAiCursorView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        _currentPos = CGPointMake(frame.size.width * 0.5, frame.size.height * 0.48);
        _thinkingText = @"思考中";
        [self buildSublayers];
    }
    return self;
}

- (void)buildSublayers {
    // 1. 思考中双层极光星云雷达环（环绕光标尖端：外环旋转锥形极光 + 内环柔光呼吸波）
    self.thinkingRingHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    self.thinkingRingHost.userInteractionEnabled = NO;
    self.thinkingRingHost.alpha = 0.0;

    self.thinkingPulseHalo = [CAShapeLayer layer];
    self.thinkingPulseHalo.frame = self.thinkingRingHost.bounds;
    self.thinkingPulseHalo.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.thinkingRingHost.bounds, 10.0, 10.0)].CGPath;
    self.thinkingPulseHalo.fillColor = [UIColor colorWithRed:0.16 green:0.84 blue:1.00 alpha:0.16].CGColor;
    self.thinkingPulseHalo.strokeColor = [UIColor colorWithRed:0.32 green:0.86 blue:1.00 alpha:0.55].CGColor;
    self.thinkingPulseHalo.lineWidth = 1.4;
    [self.thinkingRingHost.layer addSublayer:self.thinkingPulseHalo];

    self.thinkingRingGradient = [CAGradientLayer layer];
    self.thinkingRingGradient.frame = self.thinkingRingHost.bounds;
    if (@available(iOS 12.0, *)) {
        self.thinkingRingGradient.type = kCAGradientLayerConic;
    }
    self.thinkingRingGradient.startPoint = CGPointMake(0.5, 0.5);
    self.thinkingRingGradient.endPoint = CGPointMake(0.5, 0.0);
    self.thinkingRingGradient.colors = @[
        (id)[UIColor colorWithRed:0.12 green:0.88 blue:1.00 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.42 green:0.54 blue:1.00 alpha:0.96].CGColor,
        (id)[UIColor colorWithRed:0.68 green:0.34 blue:0.98 alpha:0.92].CGColor,
        (id)[UIColor colorWithRed:0.96 green:0.36 blue:0.68 alpha:0.80].CGColor,
        (id)[UIColor colorWithRed:0.12 green:0.88 blue:1.00 alpha:0.08].CGColor,
        (id)[UIColor colorWithRed:0.12 green:0.88 blue:1.00 alpha:1.0].CGColor
    ];
    self.thinkingRingMask = [CAShapeLayer layer];
    self.thinkingRingMask.frame = self.thinkingRingHost.bounds;
    self.thinkingRingMask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.thinkingRingHost.bounds, 2.5, 2.5)].CGPath;
    self.thinkingRingMask.fillColor = [UIColor clearColor].CGColor;
    self.thinkingRingMask.strokeColor = [UIColor whiteColor].CGColor;
    self.thinkingRingMask.lineWidth = 2.6;
    self.thinkingRingGradient.mask = self.thinkingRingMask;
    [self.thinkingRingHost.layer addSublayer:self.thinkingRingGradient];
    [self addSubview:self.thinkingRingHost];

    // 2. 思考中电影级流光描边磨砂胶囊（旋转流光边框 + 双星闪烁四芒星 + 清晰中文态 + 三颗彩虹弹跳波点）
    self.thinkingBubbleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 140, 34)];
    self.thinkingBubbleView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.14 alpha:0.93];
    self.thinkingBubbleView.layer.cornerRadius = 17.0;
    self.thinkingBubbleView.layer.borderWidth = 0.0;
    self.thinkingBubbleView.layer.shadowColor = [UIColor colorWithRed:0.18 green:0.70 blue:1.00 alpha:1.0].CGColor;
    self.thinkingBubbleView.layer.shadowOpacity = 0.44;
    self.thinkingBubbleView.layer.shadowRadius = 11.0;
    self.thinkingBubbleView.layer.shadowOffset = CGSizeMake(0, 3);
    self.thinkingBubbleView.userInteractionEnabled = NO;
    self.thinkingBubbleView.alpha = 0.0;

    // 旋转流光描边层（纯 GPU Conic Gradient + 胶囊描边 Mask，Apple Intelligence 同款精致流光！）
    self.thinkingBorderClipView = [[UIView alloc] initWithFrame:self.thinkingBubbleView.bounds];
    self.thinkingBorderClipView.userInteractionEnabled = NO;
    self.thinkingBorderClipView.clipsToBounds = YES;
    self.thinkingBorderClipView.layer.cornerRadius = 17.0;
    [self.thinkingBubbleView addSubview:self.thinkingBorderClipView];

    self.thinkingBorderConic = [CAGradientLayer layer];
    if (@available(iOS 12.0, *)) {
        self.thinkingBorderConic.type = kCAGradientLayerConic;
    }
    self.thinkingBorderConic.startPoint = CGPointMake(0.5, 0.5);
    self.thinkingBorderConic.endPoint = CGPointMake(0.5, 0.0);
    self.thinkingBorderConic.colors = @[
        (id)[UIColor colorWithRed:0.14 green:0.88 blue:1.00 alpha:0.98].CGColor,
        (id)[UIColor colorWithRed:0.46 green:0.52 blue:1.00 alpha:0.95].CGColor,
        (id)[UIColor colorWithRed:0.94 green:0.38 blue:0.72 alpha:0.92].CGColor,
        (id)[UIColor colorWithRed:0.20 green:0.82 blue:1.00 alpha:0.28].CGColor,
        (id)[UIColor colorWithRed:0.14 green:0.88 blue:1.00 alpha:0.98].CGColor
    ];
    [self.thinkingBorderClipView.layer addSublayer:self.thinkingBorderConic];

    self.thinkingBorderMask = [CAShapeLayer layer];
    self.thinkingBorderMask.fillColor = [UIColor clearColor].CGColor;
    self.thinkingBorderMask.strokeColor = [UIColor whiteColor].CGColor;
    self.thinkingBorderMask.lineWidth = 1.65;
    self.thinkingBorderClipView.layer.mask = self.thinkingBorderMask;

    // 原生矢量主四芒星 + 右上角副小星（双星错相位呼吸闪烁，极富灵气）
    self.sparkleHostView = [[UIView alloc] initWithFrame:CGRectMake(11, 9, 15, 15)];
    self.sparkleShapeLayer = [CAShapeLayer layer];
    UIBezierPath *sp = [UIBezierPath bezierPath];
    [sp moveToPoint:CGPointMake(7.5, 0.5)];
    [sp addQuadCurveToPoint:CGPointMake(14.5, 7.5) controlPoint:CGPointMake(8.7, 6.3)];
    [sp addQuadCurveToPoint:CGPointMake(7.5, 14.5) controlPoint:CGPointMake(8.7, 8.7)];
    [sp addQuadCurveToPoint:CGPointMake(0.5, 7.5) controlPoint:CGPointMake(6.3, 8.7)];
    [sp addQuadCurveToPoint:CGPointMake(7.5, 0.5) controlPoint:CGPointMake(6.3, 6.3)];
    [sp closePath];
    self.sparkleShapeLayer.path = sp.CGPath;
    self.sparkleShapeLayer.fillColor = [UIColor colorWithRed:0.36 green:0.92 blue:1.00 alpha:1.0].CGColor;
    self.sparkleShapeLayer.shadowColor = [UIColor colorWithRed:0.26 green:0.86 blue:1.00 alpha:1.0].CGColor;
    self.sparkleShapeLayer.shadowOpacity = 0.85;
    self.sparkleShapeLayer.shadowRadius = 3.5;
    self.sparkleShapeLayer.shadowOffset = CGSizeZero;
    [self.sparkleHostView.layer addSublayer:self.sparkleShapeLayer];
    [self.thinkingBubbleView addSubview:self.sparkleHostView];

    self.subSparkleHostView = [[UIView alloc] initWithFrame:CGRectMake(22.5, 6.0, 7.0, 7.0)];
    self.subSparkleShapeLayer = [CAShapeLayer layer];
    UIBezierPath *sp2 = [UIBezierPath bezierPath];
    [sp2 moveToPoint:CGPointMake(3.5, 0.3)];
    [sp2 addQuadCurveToPoint:CGPointMake(6.7, 3.5) controlPoint:CGPointMake(4.1, 2.9)];
    [sp2 addQuadCurveToPoint:CGPointMake(3.5, 6.7) controlPoint:CGPointMake(4.1, 4.1)];
    [sp2 addQuadCurveToPoint:CGPointMake(0.3, 3.5) controlPoint:CGPointMake(2.9, 4.1)];
    [sp2 addQuadCurveToPoint:CGPointMake(3.5, 0.3) controlPoint:CGPointMake(2.9, 2.9)];
    [sp2 closePath];
    self.subSparkleShapeLayer.path = sp2.CGPath;
    self.subSparkleShapeLayer.fillColor = [UIColor colorWithRed:0.96 green:0.62 blue:0.86 alpha:0.98].CGColor;
    [self.subSparkleHostView.layer addSublayer:self.subSparkleShapeLayer];
    [self.thinkingBubbleView addSubview:self.subSparkleHostView];

    self.thinkingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.thinkingLabel.font = [UIFont systemFontOfSize:12.2 weight:UIFontWeightSemibold];
    self.thinkingLabel.textColor = [UIColor colorWithRed:0.96 green:0.99 blue:1.00 alpha:0.99];
    self.thinkingLabel.text = @"思考中";
    [self.thinkingBubbleView addSubview:self.thinkingLabel];

    NSMutableArray<UIView *> *dots = [NSMutableArray arrayWithCapacity:3];
    NSArray<UIColor *> *dotCols = @[
        [UIColor colorWithRed:0.16 green:0.88 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.54 green:0.56 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.96 green:0.42 blue:0.74 alpha:1.0]
    ];
    for (int i = 0; i < 3; i++) {
        UIView *dv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4.8, 4.8)];
        dv.layer.cornerRadius = 2.4;
        dv.backgroundColor = dotCols[i];
        dv.layer.shadowColor = dotCols[i].CGColor;
        dv.layer.shadowOpacity = 0.7;
        dv.layer.shadowRadius = 2.5;
        dv.layer.shadowOffset = CGSizeZero;
        [self.thinkingBubbleView addSubview:dv];
        [dots addObject:dv];
    }
    self.thinkingDots = dots;
    [self addSubview:self.thinkingBubbleView];

    // 3. 精致苹果风流线型虚拟鼠标指针（锚点固定在左上尖端 (0, 0)）
    self.pointerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 58, 46)];
    self.pointerContainer.layer.anchorPoint = CGPointMake(0.0, 0.0);
    self.pointerContainer.userInteractionEnabled = NO;
    self.pointerContainer.alpha = 0.0;

    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(0.0, 0.0)];
    [arrow addLineToPoint:CGPointMake(0.0, 23.0)];
    [arrow addLineToPoint:CGPointMake(6.0, 17.8)];
    [arrow addLineToPoint:CGPointMake(11.0, 26.8)];
    [arrow addLineToPoint:CGPointMake(14.5, 25.0)];
    [arrow addLineToPoint:CGPointMake(9.5, 16.0)];
    [arrow addLineToPoint:CGPointMake(17.8, 15.1)];
    [arrow closePath];

    self.pointerShadowLayer = [CAShapeLayer layer];
    self.pointerShadowLayer.path = arrow.CGPath;
    self.pointerShadowLayer.fillColor = [UIColor colorWithRed:0.06 green:0.10 blue:0.20 alpha:0.86].CGColor;
    self.pointerShadowLayer.shadowColor = [UIColor colorWithRed:0.16 green:0.78 blue:1.00 alpha:1.0].CGColor;
    self.pointerShadowLayer.shadowOpacity = 0.78;
    self.pointerShadowLayer.shadowRadius = 7.5;
    self.pointerShadowLayer.shadowOffset = CGSizeMake(0.5, 1.5);
    [self.pointerContainer.layer addSublayer:self.pointerShadowLayer];

    self.pointerFillLayer = [CAShapeLayer layer];
    self.pointerFillLayer.path = arrow.CGPath;
    self.pointerFillLayer.fillColor = [UIColor colorWithRed:0.05 green:0.08 blue:0.16 alpha:0.98].CGColor;
    self.pointerFillLayer.strokeColor = [UIColor whiteColor].CGColor;
    self.pointerFillLayer.lineWidth = 1.9;
    self.pointerFillLayer.lineJoin = kCALineJoinRound;
    [self.pointerContainer.layer addSublayer:self.pointerFillLayer];

    // 右下迷你米塔徽标（非思考态常驻显示，精致通透不挡视线）
    self.tagBadgeView = [[UIView alloc] initWithFrame:CGRectMake(15.0, 22.0, 34, 16)];
    self.tagBadgeView.backgroundColor = [UIColor colorWithRed:0.05 green:0.09 blue:0.17 alpha:0.92];
    self.tagBadgeView.layer.cornerRadius = 8.0;
    self.tagBadgeView.layer.borderWidth = 0.85;
    self.tagBadgeView.layer.borderColor = [UIColor colorWithRed:0.22 green:0.86 blue:1.00 alpha:0.76].CGColor;
    self.tagBadgeView.layer.shadowColor = [UIColor colorWithRed:0.14 green:0.72 blue:1.00 alpha:1.0].CGColor;
    self.tagBadgeView.layer.shadowOpacity = 0.38;
    self.tagBadgeView.layer.shadowRadius = 4.0;
    self.tagBadgeView.layer.shadowOffset = CGSizeMake(0, 1);
    self.tagBadgeLabel = [[UILabel alloc] initWithFrame:self.tagBadgeView.bounds];
    self.tagBadgeLabel.text = @"米塔";
    self.tagBadgeLabel.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold];
    self.tagBadgeLabel.textColor = [UIColor colorWithRed:0.90 green:0.98 blue:1.00 alpha:1.0];
    self.tagBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [self.tagBadgeView addSubview:self.tagBadgeLabel];
    [self.pointerContainer addSubview:self.tagBadgeView];

    [self addSubview:self.pointerContainer];
}

- (void)startIdleHoverAnimation {
    // v5.5.0 冰镇低功耗策略：待命常驻态保持 0fps 静态清晰展示（绝不触发 60fps 脏帧重编与发热），仅在点击/滑动/思考任务期触发丝滑动画！
    if (self.tagBadgeView.bounds.size.width > 1.0) {
        self.tagBadgeView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.tagBadgeView.bounds cornerRadius:8.0].CGPath;
    }
}

- (void)stopIdleHoverAnimation {
    [self.pointerFillLayer removeAnimationForKey:@"mitaIdleFloat"];
    [self.pointerShadowLayer removeAnimationForKey:@"mitaIdleFloat"];
    [self.pointerShadowLayer removeAnimationForKey:@"mitaIdleGlow"];
}

- (void)ensureVisibleForAiControlAnimated:(BOOL)animated {
    self.persistentInAiMode = YES;
    self.lastActivityTs = [[NSDate date] timeIntervalSince1970];
    CGFloat W = MAX(100.0, self.bounds.size.width);
    CGFloat H = MAX(100.0, self.bounds.size.height);
    if (!self.cursorVisible || self.pointerContainer.alpha < 0.05) {
        CGPoint dockPt = (self.currentPos.x > 24.0 && self.currentPos.x < W - 24.0 && self.currentPos.y > 48.0 && self.currentPos.y < H - 140.0)
            ? self.currentPos
            : CGPointMake(round(W * 0.72), round(H * 0.44));
        self.currentPos = dockPt;
        self.cursorVisible = YES;
        CGPoint enterFrom = CGPointMake(MIN(W - 14.0, dockPt.x + 28.0), MAX(40.0, dockPt.y + 22.0));
        self.pointerContainer.layer.position = animated ? enterFrom : dockPt;
        self.pointerContainer.alpha = animated ? 0.0 : 1.0;
        self.tagBadgeView.alpha = self.thinkingActive ? 0.0 : 1.0;
        [self startIdleHoverAnimation];
        if (animated) {
            self.pointerContainer.transform = CGAffineTransformMakeScale(0.84, 0.84);
            [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.80 initialSpringVelocity:0.45 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                self.pointerContainer.alpha = 1.0;
                self.pointerContainer.layer.position = dockPt;
                self.pointerContainer.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            self.pointerContainer.transform = CGAffineTransformIdentity;
        }
    } else {
        self.pointerContainer.alpha = 1.0;
        self.tagBadgeView.alpha = self.thinkingActive ? 0.0 : 1.0;
        [self startIdleHoverAnimation];
    }
}

- (void)layoutThinkingBubbleAroundPoint:(CGPoint)pt {
    NSString *t = (self.thinkingText.length > 0) ? self.thinkingText : @"思考中";
    self.thinkingLabel.text = t;
    [self.thinkingLabel sizeToFit];
    CGFloat textW = ceil(self.thinkingLabel.bounds.size.width);
    CGFloat bw = 34.0 + textW + 34.0;
    CGFloat bh = 34.0;
    CGFloat W = MAX(100.0, self.bounds.size.width);
    CGFloat H = MAX(100.0, self.bounds.size.height);

    // 靠近右边界自动翻到光标左侧，底部避开居中胶囊，绝不遮挡或溢出屏幕！
    CGFloat bx = (pt.x + 20.0 + bw > W - 12.0) ? MAX(12.0, pt.x - bw - 16.0) : (pt.x + 20.0);
    CGFloat by = MAX(36.0, MIN(H - 134.0, pt.y - bh * 0.5));
    self.thinkingBubbleView.frame = CGRectMake(bx, by, bw, bh);
    self.thinkingBubbleView.layer.cornerRadius = bh * 0.5;
    self.thinkingBubbleView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.thinkingBubbleView.bounds cornerRadius:bh * 0.5].CGPath;

    self.thinkingBorderClipView.frame = self.thinkingBubbleView.bounds;
    self.thinkingBorderClipView.layer.cornerRadius = bh * 0.5;
    CGFloat diag = ceil(hypot(bw, bh)) + 8.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.thinkingBorderConic.bounds = CGRectMake(0, 0, diag, diag);
    self.thinkingBorderConic.position = CGPointMake(bw * 0.5, bh * 0.5);
    self.thinkingBorderMask.frame = self.thinkingBorderClipView.bounds;
    self.thinkingBorderMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.thinkingBorderClipView.bounds, 0.9, 0.9) cornerRadius:(bh * 0.5 - 0.9)].CGPath;
    [CATransaction commit];

    self.sparkleHostView.frame = CGRectMake(11.0, (bh - 15.0) * 0.5, 15.0, 15.0);
    self.subSparkleHostView.frame = CGRectMake(22.5, 6.0, 7.0, 7.0);
    self.thinkingLabel.frame = CGRectMake(32.0, 0, textW + 2.0, bh);
    CGFloat dotStartX = 32.0 + textW + 7.5;
    for (int i = 0; i < (int)self.thinkingDots.count; i++) {
        UIView *dv = self.thinkingDots[i];
        dv.frame = CGRectMake(dotStartX + i * 7.8, (bh - 4.8) * 0.5, 4.8, 4.8);
    }
    self.thinkingRingHost.center = pt;
}

- (void)startThinkingAnimations {
    if (![self.thinkingRingGradient animationForKey:@"mitaRingSpin"]) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = 1.45;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { spin.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.thinkingRingGradient addAnimation:spin forKey:@"mitaRingSpin"];
    }
    if (![self.thinkingPulseHalo animationForKey:@"mitaHaloPulse"]) {
        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        sc.fromValue = @(0.74);
        sc.toValue = @(1.24);
        sc.duration = 1.20;
        sc.autoreverses = YES;
        sc.repeatCount = HUGE_VALF;
        sc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        sc.removedOnCompletion = NO;

        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.86);
        op.toValue = @(0.22);
        op.duration = 1.20;
        op.autoreverses = YES;
        op.repeatCount = HUGE_VALF;
        op.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        op.removedOnCompletion = NO;

        CAAnimationGroup *g = [CAAnimationGroup animation];
        g.animations = @[ sc, op ];
        g.duration = 1.20;
        g.autoreverses = YES;
        g.repeatCount = HUGE_VALF;
        g.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { g.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.thinkingPulseHalo addAnimation:g forKey:@"mitaHaloPulse"];
    }
    if (![self.thinkingBorderConic animationForKey:@"mitaBubbleBorderSpin"]) {
        CABasicAnimation *bSpin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        bSpin.fromValue = @(0.0);
        bSpin.toValue = @(M_PI * 2.0);
        bSpin.duration = 2.6;
        bSpin.repeatCount = HUGE_VALF;
        bSpin.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { bSpin.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.thinkingBorderConic addAnimation:bSpin forKey:@"mitaBubbleBorderSpin"];
    }
    if (![self.sparkleHostView.layer animationForKey:@"mitaSparkleSpin"]) {
        CABasicAnimation *spRot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spRot.fromValue = @(0.0);
        spRot.toValue = @(M_PI);
        spRot.duration = 2.2;
        spRot.repeatCount = HUGE_VALF;
        spRot.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { spRot.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.sparkleHostView.layer addAnimation:spRot forKey:@"mitaSparkleSpin"];

        CABasicAnimation *spScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        spScale.fromValue = @(0.80);
        spScale.toValue = @(1.15);
        spScale.duration = 0.80;
        spScale.autoreverses = YES;
        spScale.repeatCount = HUGE_VALF;
        spScale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        spScale.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { spScale.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.sparkleHostView.layer addAnimation:spScale forKey:@"mitaSparkleScale"];
    }
    if (![self.subSparkleHostView.layer animationForKey:@"mitaSubSparkle"]) {
        CABasicAnimation *subSc = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        subSc.fromValue = @(0.55);
        subSc.toValue = @(1.18);
        subSc.duration = 0.68;
        subSc.beginTime = CACurrentMediaTime() + 0.34;
        subSc.autoreverses = YES;
        subSc.repeatCount = HUGE_VALF;
        subSc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        subSc.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { subSc.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [self.subSparkleHostView.layer addAnimation:subSc forKey:@"mitaSubSparkle"];
    }
    for (int i = 0; i < (int)self.thinkingDots.count; i++) {
        UIView *dv = self.thinkingDots[i];
        if ([dv.layer animationForKey:@"mitaDotBounce"]) continue;
        CAKeyframeAnimation *bounce = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
        bounce.values = @[ @(0.0), @(-4.2), @(0.0), @(0.0) ];
        bounce.keyTimes = @[ @(0.0), @(0.28), @(0.56), @(1.0) ];
        bounce.duration = 1.02;
        bounce.beginTime = CACurrentMediaTime() + i * 0.16;
        bounce.repeatCount = HUGE_VALF;
        bounce.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { bounce.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [dv.layer addAnimation:bounce forKey:@"mitaDotBounce"];

        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.38);
        op.toValue = @(1.0);
        op.duration = 0.51;
        op.beginTime = CACurrentMediaTime() + i * 0.16;
        op.autoreverses = YES;
        op.repeatCount = HUGE_VALF;
        op.removedOnCompletion = NO;
        if (@available(iOS 15.0, *)) { op.preferredFrameRateRange = CAFrameRateRangeMake(18, 24, 24); }
        [dv.layer addAnimation:op forKey:@"mitaDotOp"];
    }
}

- (void)stopThinkingAnimations {
    [self.thinkingRingGradient removeAllAnimations];
    [self.thinkingPulseHalo removeAllAnimations];
    [self.thinkingBorderConic removeAllAnimations];
    [self.sparkleHostView.layer removeAllAnimations];
    [self.subSparkleHostView.layer removeAllAnimations];
    for (UIView *dv in self.thinkingDots) {
        [dv.layer removeAllAnimations];
    }
}

- (void)showThinking:(BOOL)active text:(NSString *)text atPoint:(CGPoint)pt hasPoint:(BOOL)hasPt {
    BOOL wasThinking = self.thinkingActive;
    self.thinkingActive = active;
    self.lastActivityTs = [[NSDate date] timeIntervalSince1970];
    if (text.length > 0) self.thinkingText = text;
    if (active) {
        CGPoint target = hasPt ? pt : (self.cursorVisible ? self.currentPos : CGPointMake(self.bounds.size.width * 0.44, self.bounds.size.height * 0.44));
        if (!self.cursorVisible) {
            self.pointerContainer.layer.position = target;
            self.currentPos = target;
            self.cursorVisible = YES;
        }
        [self startIdleHoverAnimation];
        [self startThinkingAnimations];
        if (!wasThinking) {
            [self layoutThinkingBubbleAroundPoint:target];
            self.thinkingBubbleView.transform = CGAffineTransformMakeScale(0.84, 0.84);
            self.thinkingRingHost.transform = CGAffineTransformMakeScale(0.75, 0.75);
        }
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.80 initialSpringVelocity:0.42 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.pointerContainer.alpha = 1.0;
            self.pointerContainer.layer.position = target;
            self.tagBadgeView.alpha = 0.0;
            self.thinkingRingHost.alpha = 1.0;
            self.thinkingRingHost.transform = CGAffineTransformIdentity;
            self.thinkingBubbleView.alpha = 1.0;
            self.thinkingBubbleView.transform = CGAffineTransformIdentity;
            [self layoutThinkingBubbleAroundPoint:target];
        } completion:nil];
        self.currentPos = target;
    } else {
        [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.thinkingRingHost.alpha = 0.0;
            self.thinkingRingHost.transform = CGAffineTransformMakeScale(0.82, 0.82);
            self.thinkingBubbleView.alpha = 0.0;
            self.thinkingBubbleView.transform = CGAffineTransformMakeScale(0.88, 0.88);
            self.tagBadgeView.alpha = self.cursorVisible ? 1.0 : 0.0;
        } completion:^(BOOL finished) {
            if (!self.thinkingActive) {
                self.thinkingBubbleView.transform = CGAffineTransformIdentity;
                self.thinkingRingHost.transform = CGAffineTransformIdentity;
                [self stopThinkingAnimations];
            }
        }];
    }
}

- (void)spawnTapRippleAtPoint:(CGPoint)pt {
    // 双层极光扩散水波纹 + 中心高光星点
    NSArray<NSNumber *> *radii = @[ @(16.0), @(30.0) ];
    NSArray<NSNumber *> *durs  = @[ @(0.38), @(0.52) ];
    NSArray<UIColor *> *cols   = @[
        [UIColor colorWithRed:0.54 green:0.36 blue:1.00 alpha:0.92],
        [UIColor colorWithRed:0.14 green:0.85 blue:0.98 alpha:0.85]
    ];
    for (int i = 0; i < 2; i++) {
        CGFloat maxR = [radii[i] doubleValue];
        double dur = [durs[i] doubleValue];
        CAShapeLayer *ring = [CAShapeLayer layer];
        CGRect rect = CGRectMake(-maxR, -maxR, maxR * 2.0, maxR * 2.0);
        ring.path = [UIBezierPath bezierPathWithOvalInRect:rect].CGPath;
        ring.position = pt;
        ring.fillColor = (i == 0) ? [UIColor colorWithRed:0.22 green:0.78 blue:1.00 alpha:0.22].CGColor : [UIColor clearColor].CGColor;
        ring.strokeColor = cols[i].CGColor;
        ring.lineWidth = (i == 0) ? 2.2 : 1.6;
        [self.layer insertSublayer:ring below:self.pointerContainer.layer];

        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        sc.fromValue = @(0.18);
        sc.toValue = @(1.08);
        sc.duration = dur;
        sc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.95);
        op.toValue = @(0.0);
        op.duration = dur;
        op.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

        CAAnimationGroup *grp = [CAAnimationGroup animation];
        grp.animations = @[ sc, op ];
        grp.duration = dur;
        grp.fillMode = kCAFillModeForwards;
        grp.removedOnCompletion = NO;
        [ring addAnimation:grp forKey:@"mitaRipple"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.08) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ring removeFromSuperlayer];
        });
    }

    // 尖端闪光核心星点
    CAShapeLayer *core = [CAShapeLayer layer];
    core.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-3.5, -3.5, 7.0, 7.0)].CGPath;
    core.position = pt;
    core.fillColor = [UIColor colorWithRed:0.90 green:0.98 blue:1.00 alpha:1.0].CGColor;
    [self.layer insertSublayer:core below:self.pointerContainer.layer];
    CABasicAnimation *cop = [CABasicAnimation animationWithKeyPath:@"opacity"];
    cop.fromValue = @(1.0);
    cop.toValue = @(0.0);
    cop.duration = 0.28;
    cop.fillMode = kCAFillModeForwards;
    cop.removedOnCompletion = NO;
    [core addAnimation:cop forKey:@"mitaCore"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [core removeFromSuperlayer];
    });
}

- (void)playTapAtPoint:(CGPoint)pt {
    self.lastActivityTs = [[NSDate date] timeIntervalSince1970];
    if (self.thinkingActive) {
        [self showThinking:NO text:nil atPoint:pt hasPoint:YES];
    }
    if (!self.cursorVisible) {
        self.cursorVisible = YES;
        CGPoint startPt = CGPointMake(MAX(20.0, MIN(self.bounds.size.width - 20.0, pt.x - 36.0)),
                                      MAX(30.0, MIN(self.bounds.size.height - 30.0, pt.y + 42.0)));
        self.pointerContainer.layer.position = startPt;
        self.pointerContainer.alpha = 0.0;
    }
    self.currentPos = pt;
    self.tagBadgeView.alpha = 1.0;

    [UIView animateWithDuration:0.20 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.pointerContainer.alpha = 1.0;
        self.pointerContainer.layer.position = pt;
    } completion:^(BOOL finished) {
        [self spawnTapRippleAtPoint:pt];
        // 光标按压回弹微动效
        [UIView animateWithDuration:0.09 animations:^{
            self.pointerContainer.transform = CGAffineTransformMakeScale(0.82, 0.82);
        } completion:^(BOOL f2) {
            [UIView animateWithDuration:0.16 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0.6 options:0 animations:^{
                self.pointerContainer.transform = CGAffineTransformIdentity;
            } completion:nil];
        }];
    }];
}

- (void)playSwipeFrom:(CGPoint)fromPt to:(CGPoint)toPt duration:(double)dur {
    self.lastActivityTs = [[NSDate date] timeIntervalSince1970];
    if (self.thinkingActive) {
        [self showThinking:NO text:nil atPoint:fromPt hasPoint:YES];
    }
    double moveDur = MAX(0.18, MIN(1.2, dur));
    if (!self.cursorVisible) {
        self.cursorVisible = YES;
        self.pointerContainer.layer.position = fromPt;
    }
    self.tagBadgeView.alpha = 1.0;
    self.pointerContainer.alpha = 1.0;
    self.pointerContainer.layer.position = fromPt;

    // 柔光极光轨迹线
    CAShapeLayer *trail = [CAShapeLayer layer];
    UIBezierPath *tp = [UIBezierPath bezierPath];
    [tp moveToPoint:fromPt];
    [tp addLineToPoint:toPt];
    trail.path = tp.CGPath;
    trail.strokeColor = [UIColor colorWithRed:0.20 green:0.82 blue:1.00 alpha:0.80].CGColor;
    trail.fillColor = [UIColor clearColor].CGColor;
    trail.lineWidth = 4.5;
    trail.lineCap = kCALineCapRound;
    trail.shadowColor = [UIColor colorWithRed:0.46 green:0.38 blue:1.00 alpha:1.0].CGColor;
    trail.shadowOpacity = 0.85;
    trail.shadowRadius = 6.0;
    trail.shadowOffset = CGSizeZero;
    [self.layer insertSublayer:trail below:self.pointerContainer.layer];

    CABasicAnimation *se = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    se.fromValue = @(0.0);
    se.toValue = @(1.0);
    se.duration = moveDur;
    se.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [trail addAnimation:se forKey:@"mitaSwipeEnd"];

    CABasicAnimation *ss = [CABasicAnimation animationWithKeyPath:@"strokeStart"];
    ss.fromValue = @(0.0);
    ss.toValue = @(1.0);
    ss.beginTime = CACurrentMediaTime() + moveDur * 0.45;
    ss.duration = moveDur * 0.75 + 0.25;
    ss.fillMode = kCAFillModeForwards;
    ss.removedOnCompletion = NO;
    [trail addAnimation:ss forKey:@"mitaSwipeStart"];

    self.currentPos = toPt;
    [UIView animateWithDuration:moveDur delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.pointerContainer.transform = CGAffineTransformMakeScale(0.88, 0.88);
        self.pointerContainer.layer.position = toPt;
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.15 animations:^{
            self.pointerContainer.transform = CGAffineTransformIdentity;
        }];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((moveDur * 1.25 + 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [trail removeFromSuperlayer];
    });
}

- (void)hideCursorAnimated:(BOOL)animated {
    self.thinkingActive = NO;
    self.cursorVisible = NO;
    self.persistentInAiMode = NO;
    [self stopThinkingAnimations];
    [self stopIdleHoverAnimation];
    if (animated) {
        [UIView animateWithDuration:0.25 animations:^{
            self.pointerContainer.alpha = 0.0;
            self.thinkingRingHost.alpha = 0.0;
            self.thinkingBubbleView.alpha = 0.0;
        }];
    } else {
        self.pointerContainer.alpha = 0.0;
        self.thinkingRingHost.alpha = 0.0;
        self.thinkingBubbleView.alpha = 0.0;
    }
}

- (void)checkAutoFadeIfIdle {
    if (!self.cursorVisible || self.thinkingActive || self.persistentInAiMode) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.lastActivityTs > 0 && (now - self.lastActivityTs) > 6.5) {
        [self hideCursorAnimated:YES];
    }
}

@end

#pragma mark - Permanent Floating Takeover Control Bar ("AI 控制中 | 我来接管" <-> "我来控制 | 交回 AI", v5.1.0)

typedef NS_ENUM(NSInteger, MitaControlMode) {
    MitaControlModeIdle = 0,          // 历史兼容枚举：远控开启时映射为常驻 MitaControlModeHumanControl
    MitaControlModeAiLocked = 1,      // AI 控制中：屏蔽屏幕误触，右下安全区同尺寸常驻「AI 控制中 | 我来接管」
    MitaControlModeHumanControl = 2   // 我来控制（远控开启默认常驻）：shieldWindow==nil 100% 原生自由触摸，右下安全区常驻「我来控制 | 交回 AI」
};

@interface MitaTakeoverBarView : UIView
@property (nonatomic, assign) MitaControlMode controlMode;
@property (nonatomic, assign) BOOL humanCompact;
@property (nonatomic, assign) BOOL masterHidden;
@property (nonatomic, strong) UIView *pillBox;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UILabel *hintToastLabel;
@property (nonatomic, copy) BOOL (^shouldAllowButtonTap)(void);
@property (nonatomic, copy) void (^onActionTapped)(MitaControlMode currentMode);
@property (nonatomic, copy) void (^onGeometryChanged)(BOOL animated);
- (void)layoutForCurrentMode;
- (void)applyControlMode:(MitaControlMode)mode animated:(BOOL)animated;
- (void)playTapBounceFeedback;
- (void)flashBlockedTouchHint;
- (CGRect)basePillRect;
- (CGRect)pillHitRectInView:(UIView *)targetView;
- (CGRect)actionButtonHitRectInView:(UIView *)targetView;
- (CGRect)interactiveHitRectInView:(UIView *)targetView;
@end

@implementation MitaTakeoverBarView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clipsToBounds = NO;
        self.userInteractionEnabled = NO;
        _controlMode = MitaControlModeHumanControl;
        _humanCompact = YES;
        _masterHidden = NO;
        [self buildBarUI];
    }
    return self;
}

- (void)buildBarUI {
    self.hintToastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hintToastLabel.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.17 alpha:0.90];
    self.hintToastLabel.textColor = [UIColor colorWithRed:0.94 green:0.97 blue:1.00 alpha:0.98];
    self.hintToastLabel.font = [UIFont systemFontOfSize:11.2 weight:UIFontWeightMedium];
    self.hintToastLabel.textAlignment = NSTextAlignmentCenter;
    self.hintToastLabel.layer.cornerRadius = 13.0;
    self.hintToastLabel.clipsToBounds = YES;
    self.hintToastLabel.alpha = 0.0;
    self.hintToastLabel.userInteractionEnabled = NO;
    [self addSubview:self.hintToastLabel];

    self.pillBox = [[UIView alloc] initWithFrame:CGRectZero];
    self.pillBox.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.15 alpha:0.95];
    self.pillBox.layer.cornerRadius = 18.0;
    self.pillBox.layer.borderWidth = 1.0;
    self.pillBox.layer.borderColor = [UIColor colorWithRed:0.18 green:0.86 blue:0.58 alpha:0.85].CGColor;
    self.pillBox.layer.shadowColor = [UIColor blackColor].CGColor;
    self.pillBox.layer.shadowOpacity = 0.34;
    self.pillBox.layer.shadowRadius = 12.0;
    self.pillBox.layer.shadowOffset = CGSizeMake(0, 4);
    self.pillBox.hidden = NO;
    self.pillBox.alpha = 1.0;
    self.pillBox.userInteractionEnabled = NO;
    [self addSubview:self.pillBox];

    self.dotView = [[UIView alloc] initWithFrame:CGRectMake(13.0, 14.0, 8.0, 8.0)];
    self.dotView.layer.cornerRadius = 4.0;
    self.dotView.backgroundColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.58 alpha:1.0];
    self.dotView.alpha = 1.0;
    self.dotView.userInteractionEnabled = NO;
    [self.pillBox addSubview:self.dotView];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont systemFontOfSize:12.4 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithRed:0.92 green:1.00 blue:0.96 alpha:0.98];
    self.statusLabel.textAlignment = NSTextAlignmentLeft;
    self.statusLabel.userInteractionEnabled = NO;
    [self.pillBox addSubview:self.statusLabel];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    self.actionButton.layer.cornerRadius = 13.0;
    self.actionButton.clipsToBounds = YES;
    self.actionButton.userInteractionEnabled = NO;
    [self.pillBox addSubview:self.actionButton];

    [self layoutForCurrentMode];
}

- (void)playTapBounceFeedback {
    [UIView animateWithDuration:0.08 animations:^{
        self.pillBox.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.16 animations:^{
            self.pillBox.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)layoutForCurrentMode {
    if (self.masterHidden) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.pillBox.hidden = YES;
        return;
    }
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 20.0 || sb.size.height < 20.0) return;
    if (!CGRectEqualToRect(self.frame, sb)) {
        self.frame = sb;
    }
    CGFloat W = sb.size.width;
    CGFloat H = sb.size.height;
    BOOL isModern = (MAX(W, H) / MAX(1.0, MIN(W, H))) > 1.95;
    CGFloat bottomSafe = isModern ? 34.0 : 12.0;

    self.hidden = NO;
    self.alpha = 1.0;
    self.pillBox.hidden = NO;
    self.pillBox.alpha = 1.0;

    // v5.6.0：合并上移至顶部状态栏居中精巧灵动岛一体胶囊（y=1..27 / 刘海屏 y=34..60），
    // 0% 遮挡底部键盘（数字 7/8/9 及字母区）、0% 遮挡底栏与内容区、0% 干扰其他 AI 触摸！
    CGFloat pw = 196.0, ph = 24.0;
    CGFloat centerX = round(W * 0.5);
    CGFloat topY = isModern ? 34.0 : 1.0;
    CGFloat centerY = round(topY + ph * 0.5);
    self.pillBox.bounds = CGRectMake(0.0, 0.0, pw, ph);
    self.pillBox.center = CGPointMake(centerX, centerY);
    self.pillBox.layer.cornerRadius = ph * 0.5;
    self.pillBox.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.pillBox.bounds cornerRadius:ph * 0.5].CGPath;

    self.dotView.frame = CGRectMake(10.0, (ph - 6.5) * 0.5, 6.5, 6.5);
    self.dotView.layer.cornerRadius = 3.25;
    self.statusLabel.frame = CGRectMake(21.0, 0.0, 92.0, ph);
    self.actionButton.frame = CGRectMake(pw - 74.0 - 3.0, (ph - 18.0) * 0.5, 74.0, 18.0);
    self.actionButton.layer.cornerRadius = 9.0;
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];

    if (self.controlMode == MitaControlModeAiLocked) {
        self.pillBox.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.14 alpha:0.95];
        self.pillBox.layer.borderColor = [UIColor colorWithRed:0.28 green:0.80 blue:1.00 alpha:0.82].CGColor;
        self.dotView.backgroundColor = [UIColor colorWithRed:0.16 green:0.86 blue:0.98 alpha:1.0];

        self.statusLabel.text = @"AI 控制中";
        self.statusLabel.font = [UIFont systemFontOfSize:10.8 weight:UIFontWeightSemibold];
        self.statusLabel.textColor = [UIColor colorWithRed:0.94 green:0.98 blue:1.00 alpha:0.99];

        self.actionButton.backgroundColor = [UIColor whiteColor];
        [self.actionButton setTitle:@"我来接管" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor colorWithRed:0.06 green:0.09 blue:0.17 alpha:1.0] forState:UIControlStateNormal];
    } else {
        self.pillBox.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.15 alpha:0.94];
        self.pillBox.layer.borderColor = [UIColor colorWithRed:0.18 green:0.86 blue:0.58 alpha:0.88].CGColor;
        self.dotView.backgroundColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.58 alpha:1.0];

        self.statusLabel.text = @"我来控制";
        self.statusLabel.font = [UIFont systemFontOfSize:10.8 weight:UIFontWeightSemibold];
        self.statusLabel.textColor = [UIColor colorWithRed:0.93 green:1.00 blue:0.97 alpha:0.99];

        self.actionButton.backgroundColor = [UIColor colorWithRed:0.06 green:0.74 blue:0.52 alpha:1.0];
        [self.actionButton setTitle:@"交回 AI" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }

    self.hintToastLabel.bounds = CGRectMake(0.0, 0.0, 248.0, 24.0);
    self.hintToastLabel.center = CGPointMake(centerX, topY + ph + 18.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutForCurrentMode];
}

- (void)applyControlMode:(MitaControlMode)mode animated:(BOOL)animated {
    MitaControlMode effectiveMode = (mode == MitaControlModeAiLocked) ? MitaControlModeAiLocked : MitaControlModeHumanControl;
    self.controlMode = effectiveMode;
    self.humanCompact = YES;
    if (self.masterHidden) return;

    void (^applyBlock)(void) = ^{
        self.hidden = NO;
        self.alpha = 1.0;
        self.pillBox.hidden = NO;
        self.pillBox.alpha = 1.0;
        [self layoutForCurrentMode];
        if (effectiveMode != MitaControlModeAiLocked) {
            self.hintToastLabel.alpha = 0.0;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.35 options:UIViewAnimationOptionBeginFromCurrentState animations:applyBlock completion:nil];
    } else {
        applyBlock();
    }
}

- (void)flashBlockedTouchHint {
    if (self.masterHidden || self.controlMode != MitaControlModeAiLocked) return;
    self.hintToastLabel.text = @"AI 正在操控，点击下方「我来接管」控制";
    [self layoutForCurrentMode];
    [UIView animateWithDuration:0.14 animations:^{
        self.hintToastLabel.alpha = 1.0;
        self.pillBox.transform = CGAffineTransformMakeScale(1.05, 1.05);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.20 animations:^{
            self.pillBox.transform = CGAffineTransformIdentity;
        }];
    }];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{
            if (weakSelf) weakSelf.hintToastLabel.alpha = 0.0;
        }];
    });
}

- (CGRect)basePillRect {
    if (CGRectIsEmpty(self.pillBox.bounds)) [self layoutForCurrentMode];
    CGPoint c = self.pillBox.center;
    CGSize sz = self.pillBox.bounds.size;
    return CGRectMake(c.x - sz.width * 0.5, c.y - sz.height * 0.5, sz.width, sz.height);
}

- (CGRect)pillHitRectInView:(UIView *)targetView {
    CGRect basePillRect = [self basePillRect];
    CGRect r = targetView ? [self convertRect:basePillRect toView:targetView] : basePillRect;
    return CGRectInset(r, -10.0, -10.0);
}

- (CGRect)actionButtonHitRectInView:(UIView *)targetView {
    CGRect basePillRect = [self basePillRect];
    CGRect btnInPill = self.actionButton.frame;
    CGRect baseBtnRect = CGRectMake(basePillRect.origin.x + btnInPill.origin.x,
                                    basePillRect.origin.y + btnInPill.origin.y,
                                    btnInPill.size.width,
                                    btnInPill.size.height);
    CGRect r = targetView ? [self convertRect:baseBtnRect toView:targetView] : baseBtnRect;
    return CGRectInset(r, -6.0, -8.0);
}

- (CGRect)interactiveHitRectInView:(UIView *)targetView {
    return [self pillHitRectInView:targetView];
}

@end

#pragma mark - Touch Shield View (Blocks Accidental Human Touches During AI Control)

@interface MitaTouchShieldView : UIView
@property (nonatomic, copy) void (^onBlockedTouch)(void);
@end

@implementation MitaTouchShieldView

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.onBlockedTouch) self.onBlockedTouch();
}

@end

#pragma mark - Hazy Sci-Fi Nebula Edge Aura (Zero-CPU Pure GPU Conic Mist + Crisp Rim, v4.8.0)

@interface MitaEdgeWaveView : UIView
@property (nonatomic, assign) double phase;
@property (nonatomic, assign) BOOL activeControl;
@property (nonatomic, assign) BOOL activeReplying;
@property (nonatomic, copy) NSString *phaseLabel;
@property (nonatomic, assign) NSTimeInterval startedAtTs;
@property (nonatomic, assign) CGFloat masterOpacity;
@property (nonatomic, assign) uint64_t renderedFrames;

@property (nonatomic, strong) CALayer *waveCompositeLayer;
@property (nonatomic, strong) CAGradientLayer *mainConicLayer;
@property (nonatomic, strong) CAGradientLayer *cometConicLayer;
@property (nonatomic, strong) CALayer *mistMaskLayer;

@property (nonatomic, strong) CALayer *rimCompositeLayer;
@property (nonatomic, strong) CAGradientLayer *rimConicLayer;
@property (nonatomic, strong) CALayer *rimMaskLayer;

@property (nonatomic, assign) CGFloat physicalCornerRadius;

@property (nonatomic, strong) UIView *statusPillView;
@property (nonatomic, strong) UIView *statusDotView;
@property (nonatomic, strong) UILabel *statusPillLabel;
@property (nonatomic, strong) dispatch_source_t pillTimer;

@property (nonatomic, assign) CGSize lastLayoutSize;
@property (nonatomic, assign) BOOL gpuAnimRunning;
- (void)syncGpuOpacityAndMode;
- (void)updateStatusPillText;
@end

static NSString *MitaFormatPillTimer(NSInteger sec) {
    if (sec < 0) sec = 0;
    NSInteger h = sec / 3600;
    NSInteger m = (sec % 3600) / 60;
    NSInteger s = sec % 60;
    if (h > 0) return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

static CGFloat MitaPhysicalCornerRadiusForBounds(CGRect b) {
    @try {
        id val = [[UIScreen mainScreen] valueForKey:@"_displayCornerRadius"];
        if ([val respondsToSelector:@selector(doubleValue)]) {
            CGFloat r = (CGFloat)[val doubleValue];
            if (r >= 0.0 && r <= 70.0) return r;
        }
    } @catch (NSException *ex) {}
    return (b.size.height / MAX(1.0, b.size.width) > 1.95) ? 39.0 : 0.0;
}

// v5.5.0 冰镇零发热单层预烘焙极光柔雾图（仅布局初始化执行 1 次 <3ms，占用 300KB 显存，运行期 0% CPU + 0 离屏 Mask + 0 VNC 脏帧风暴！）
static CGImageRef MitaCreatePrebakedAuraEdgeImage(CGSize size, CGFloat cornerRadius, CGFloat maxFeatherPt) CF_RETURNS_RETAINED {
    double W = MAX(20.0, (double)size.width);
    double H = MAX(20.0, (double)size.height);
    double scale = 0.5; // 207x368 柔和羽化纹理，GPU 硬件双线性插值丝滑无锯齿且带宽仅原来的 1/350
    size_t bw = (size_t)MAX(64, (int)ceil(W * scale));
    size_t bh = (size_t)MAX(64, (int)ceil(H * scale));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    uint8_t *buf = (uint8_t *)calloc(bw * bh * 4, 1);
    if (!buf) {
        CGColorSpaceRelease(cs);
        return NULL;
    }

    // 赛博电光青 -> 深海量子蓝 -> 星云幻影紫 -> 极光霓虹洋红 -> 冰川青蓝 环绕色盘
    static const double stopPos[6] = { 0.00, 0.20, 0.42, 0.64, 0.84, 1.00 };
    static const double stopR[6]   = { 0.02, 0.14, 0.48, 0.88, 0.12, 0.02 };
    static const double stopG[6]   = { 0.86, 0.42, 0.24, 0.24, 0.78, 0.86 };
    static const double stopB[6]   = { 0.99, 0.98, 0.98, 0.68, 0.98, 0.99 };

    double r = MIN((double)cornerRadius, MIN(W, H) * 0.25);
    double hx = W * 0.5 - r;
    double hy = H * 0.5 - r;
    double feather = MAX(4.0, (double)maxFeatherPt);
    const double twoPi = 6.283185307179586;

    for (size_t iy = 0; iy < bh; iy++) {
        double py = ((double)iy + 0.5) / (double)bh * H;
        double dyC = py - H * 0.5;
        double qy = fabs(dyC) - hy;
        double oy = fmax(qy, 0.0);
        size_t rowOff = iy * bw * 4;
        for (size_t ix = 0; ix < bw; ix++) {
            double px = ((double)ix + 0.5) / (double)bw * W;
            double dxC = px - W * 0.5;
            double qx = fabs(dxC) - hx;
            double ox = fmax(qx, 0.0);
            double outside = hypot(ox, oy) + fmin(fmax(qx, qy), 0.0) - r;
            double d = -outside;
            if (d < -0.75 || d >= feather) continue;

            double a = 0.0;
            double rimBoost = 0.0;
            if (d < 0.0) {
                a = 1.0 + (d / 0.75);
                rimBoost = a;
            } else {
                double t = d / feather;
                // 贴边 3.4pt 高亮导光芯 + 向内 32pt 高斯柔雾星云晕染（中心严格 0.0 全透明）
                double rim = (d < 3.6) ? pow(MAX(0.0, 1.0 - d / 3.6), 1.65) : 0.0;
                double core = exp(-14.0 * t * t) * 0.34;
                double mist = exp(-2.90 * t * t) * (1.0 - t) * 0.82;
                a = MIN(1.0, rim * 0.88 + core + mist);
                rimBoost = rim * 0.35;
            }
            if (a <= 0.003) continue;

            double ang = atan2(dyC, dxC) + 1.15;
            if (ang < 0.0) ang += twoPi;
            double u = fmod(ang / twoPi, 1.0);
            int seg = 0;
            while (seg < 4 && u > stopPos[seg + 1]) seg++;
            double span = MAX(0.001, stopPos[seg + 1] - stopPos[seg]);
            double f = MAX(0.0, MIN(1.0, (u - stopPos[seg]) / span));
            double cr = stopR[seg] + (stopR[seg + 1] - stopR[seg]) * f;
            double cg = stopG[seg] + (stopG[seg + 1] - stopG[seg]) * f;
            double cb = stopB[seg] + (stopB[seg + 1] - stopB[seg]) * f;
            // 贴边导光芯微微提亮增透，呈现精致星云立体感
            cr = MIN(1.0, cr + rimBoost * 0.25);
            cg = MIN(1.0, cg + rimBoost * 0.25);
            cb = MIN(1.0, cb + rimBoost * 0.20);

            size_t p = rowOff + ix * 4;
            // Premultiplied RGBA
            buf[p + 0] = (uint8_t)MIN(255, MAX(0, (int)llround(cr * a * 255.0)));
            buf[p + 1] = (uint8_t)MIN(255, MAX(0, (int)llround(cg * a * 255.0)));
            buf[p + 2] = (uint8_t)MIN(255, MAX(0, (int)llround(cb * a * 255.0)));
            buf[p + 3] = (uint8_t)MIN(255, MAX(0, (int)llround(a * 255.0)));
        }
    }

    CGContextRef ctx = CGBitmapContextCreate(buf, bw, bh, 8, bw * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    free(buf);
    CGColorSpaceRelease(cs);
    return img;
}

@implementation MitaEdgeWaveView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        _phase = 0.0;
        _masterOpacity = 0.0;
        _lastLayoutSize = CGSizeZero;
        [self setupGpuLayers];
        [self setupStatusPill];
    }
    return self;
}

- (void)setupStatusPill {
    self.statusPillView = [[UIView alloc] initWithFrame:CGRectMake(0, 2, 92, 16)];
    self.statusPillView.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.15 alpha:0.88];
    self.statusPillView.layer.cornerRadius = 8.0;
    self.statusPillView.layer.borderWidth = 0.75;
    self.statusPillView.layer.borderColor = [UIColor colorWithRed:0.25 green:0.84 blue:1.00 alpha:0.65].CGColor;
    self.statusPillView.clipsToBounds = YES;
    self.statusPillView.userInteractionEnabled = NO;

    self.statusDotView = [[UIView alloc] initWithFrame:CGRectMake(6.5, 5.5, 5.0, 5.0)];
    self.statusDotView.backgroundColor = [UIColor colorWithRed:0.12 green:0.88 blue:1.00 alpha:1.0];
    self.statusDotView.layer.cornerRadius = 2.5;
    self.statusDotView.alpha = 1.0;
    [self.statusPillView addSubview:self.statusDotView];

    self.statusPillLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusPillLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.8 weight:UIFontWeightSemibold];
    self.statusPillLabel.textColor = [UIColor colorWithRed:0.95 green:0.98 blue:1.00 alpha:0.98];
    self.statusPillLabel.textAlignment = NSTextAlignmentLeft;
    [self.statusPillView addSubview:self.statusPillLabel];
    // v5.6.0：顶部灵动岛已合并为唯一精巧控制条（MitaTakeoverBarView），隐藏旧重复计时微章避免顶部两坨黑条重叠
    self.statusPillView.hidden = YES;
    self.statusPillView.alpha = 0.0;
    [self addSubview:self.statusPillView];
}

- (void)ensurePillTimerRunning {
    if (self.pillTimer != nil) return;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // v5.5.0 冰镇低功耗：顶部计时条每 5 秒刷新一次（而非每秒脏屏触发 VNC 全帧编码），温控大降！
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                              (uint64_t)(5.0 * NSEC_PER_SEC),
                              (uint64_t)(0.80 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        [weakSelf updateStatusPillText];
    });
    self.pillTimer = t;
    dispatch_resume(t);
}

- (void)stopPillTimer {
    if (self.pillTimer != nil) {
        dispatch_source_cancel(self.pillTimer);
        self.pillTimer = nil;
    }
}

- (void)updateStatusPillText {
    if (!self.statusPillView || self.bounds.size.width < 40) return;
    if (!self.activeControl && self.masterOpacity <= 0.01) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger elapsed = (self.startedAtTs > 1000000) ? MAX(0, (NSInteger)llround(now - self.startedAtTs)) : 0;
    NSString *lbl = (self.phaseLabel.length > 0) ? self.phaseLabel : @"AI控制中";
    NSString *txt = [NSString stringWithFormat:@"%@ %@", lbl, MitaFormatPillTimer(elapsed)];
    if (![self.statusPillLabel.text isEqualToString:txt]) {
        self.statusPillLabel.text = txt;
        [self.statusPillLabel sizeToFit];
        CGFloat pillH = 16.0;
        CGFloat textW = ceil(self.statusPillLabel.bounds.size.width);
        CGFloat pillW = textW + 21.0;
        BOOL isModern = (self.bounds.size.height / MAX(1.0, self.bounds.size.width)) > 1.95;
        CGFloat pillY = isModern ? 4.5 : 2.0;
        self.statusPillView.frame = CGRectMake((self.bounds.size.width - pillW) * 0.5, pillY, pillW, pillH);
        self.statusDotView.frame = CGRectMake(6.5, (pillH - 5.0) * 0.5, 5.0, 5.0);
        self.statusPillLabel.frame = CGRectMake(15.0, 0, textW + 2.0, pillH);
    }
}

- (void)setupGpuLayers {
    self.layer.opacity = 0.0f;

    // v5.5.0 冰镇单层预烘焙极光雾环（零 Conic 全屏着色器 + 零双路离屏 Mask + 稳态 0fps，彻底终结发热与 VNC 脏帧风暴！）
    self.waveCompositeLayer = [CALayer layer];
    self.waveCompositeLayer.contentsGravity = kCAGravityResize;
    self.waveCompositeLayer.magnificationFilter = kCAFilterLinear;
    self.waveCompositeLayer.minificationFilter = kCAFilterLinear;
    [self.layer addSublayer:self.waveCompositeLayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (b.size.width < 10 || b.size.height < 10) return;
    if (CGSizeEqualToSize(self.lastLayoutSize, b.size)) return;
    self.lastLayoutSize = b.size;
    self.physicalCornerRadius = MitaPhysicalCornerRadiusForBounds(b);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.waveCompositeLayer.frame = b;
    CGImageRef auraImg = MitaCreatePrebakedAuraEdgeImage(b.size, self.physicalCornerRadius, 32.0);
    if (auraImg) {
        self.waveCompositeLayer.contents = (__bridge id)auraImg;
        CGImageRelease(auraImg);
    }
    [CATransaction commit];
    [self bringSubviewToFront:self.statusPillView];
    [self syncGpuOpacityAndMode];
}

- (void)ensureGpuAnimationsRunning {
    // v5.5.0 冰镇静默极光策略：静态单图 0fps 零发热，绝不启动 60fps 全屏旋转着色器！
    self.gpuAnimRunning = NO;
}

- (void)syncGpuOpacityAndMode {
    CGFloat targetOp = MAX(0.0f, MIN(1.0f, self.masterOpacity));
    if (self.activeControl && targetOp > 0.05f) {
        [self ensurePillTimerRunning];
    } else {
        [self stopPillTimer];
    }
    if (self.gpuAnimRunning) {
        [self.waveCompositeLayer removeAllAnimations];
        self.gpuAnimRunning = NO;
    }
    BOOL lively = self.activeReplying;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.opacity = (float)targetOp;
    self.waveCompositeLayer.opacity = lively ? 0.98f : 0.88f;
    [CATransaction commit];
    if (self.activeControl && targetOp > 0.01f) {
        [self updateStatusPillText];
    }
}

@end

#pragma mark - Overlay Root View Controller & IPC Watcher

@interface MitaEdgeRootViewController : UIViewController
@property (nonatomic, strong) MitaEdgeWaveView *waveView;
@property (nonatomic, strong) MitaTouchShieldView *touchShieldView;
@property (nonatomic, strong) MitaAiCursorView *cursorView;
@property (nonatomic, strong) MitaTakeoverBarView *takeoverBar;
@property (nonatomic, strong) MitaShieldWindow *shieldWindow;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) dispatch_source_t pollSource;
@property (nonatomic, assign) BOOL screenLocked;
@property (nonatomic, assign) unsigned int hostedContextId;
@property (nonatomic, assign) unsigned int shieldHostedContextId;
@property (nonatomic, assign) NSTimeInterval lastSeenUpdatedAt;
@property (nonatomic, assign) NSInteger consecutiveStoppedChecks;
@property (nonatomic, assign) BOOL statusProbeInFlight;
@property (nonatomic, assign) NSTimeInterval lastStatusProbeTs;
@property (nonatomic, assign) NSTimeInterval lastWindowReassertTs;
@property (nonatomic, assign) CFTimeInterval lastFrameTs;

@property (nonatomic, assign) BOOL overlayMasterVisible;
@property (nonatomic, assign) MitaControlMode controlMode;
@property (nonatomic, assign) NSTimeInterval passthroughUntilTs;
@property (nonatomic, assign) NSTimeInterval aiLockExpireAtTs;
@property (nonatomic, assign) NSTimeInterval lastTouchHandledTs;
@property (nonatomic, assign) NSTimeInterval lastHintToastTs;
@property (nonatomic, assign) void *hidEventClient;
@property (nonatomic, copy) NSString *pcCallbackUrl;
@property (nonatomic, copy) NSString *controlModeString;

@property (nonatomic, copy) void (^reassertWindowBlock)(void);
@property (nonatomic, copy) unsigned int (^registerHostedWindowBlock)(UIWindow *win);
@property (nonatomic, copy) void (^unregisterHostedContextBlock)(unsigned int ctxId);
- (void)applyOverlayMasterOffAndHideAll;
- (void)restoreOverlayMasterVisibleWithMode:(MitaControlMode)mode;
- (void)destroyShieldWindowIfNeeded;
- (void)flashBlockedHintThrottled;
- (void)syncShieldWindowGeometryAnimated:(BOOL)animated;
- (BOOL)tryAcquireActionDebounceLock;
- (void)handleTakeoverBarButtonTappedFromMode:(MitaControlMode)curMode;
- (void)reloadControlStateNow;
- (void)writeDiagnosticsSnapshot;
- (void)applyControlModeFromExternal:(MitaControlMode)mode ttlSec:(double)ttlSec pcUrl:(NSString *)pcUrl;
- (void)openPassthroughGateMs:(double)ms;
- (void)handleOverlayTouchDownAtPoint:(CGPoint)pt;
- (void)handleAiThinking:(BOOL)active text:(NSString *)text rawX:(double)rx rawY:(double)ry hasPoint:(BOOL)hasPt lockAi:(BOOL)lockAi;
- (void)handleAiCursorTapRawX:(double)rx rawY: (double)ry passthroughMs:(double)pMs lockAi:(BOOL)lockAi;
- (void)handleAiCursorSwipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2 duration:(double)dur lockAi:(BOOL)lockAi;
- (NSDictionary *)liveOverlayStatusDict;
@end

static NSString *MitaControlModeName(MitaControlMode m) {
    if (m == MitaControlModeAiLocked) return @"ai_locked";
    return @"human_control";
}

@implementation MitaShieldViewController
- (BOOL)prefersStatusBarHidden { return NO; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
    self.view.clipsToBounds = NO;
    self.view.userInteractionEnabled = YES;
}
@end

@implementation MitaEdgeRootViewController

- (BOOL)prefersStatusBarHidden { return NO; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;
    // MitaGlowWindow 根视图永久禁用交互，确保朦胧流光、虚拟小鼠标与常驻胶囊 100% 物理穿透真机手指触摸！
    self.view.userInteractionEnabled = NO;
    self.overlayMasterVisible = YES;
    self.controlMode = MitaControlModeHumanControl;
    self.controlModeString = @"human_control";
    self.pcCallbackUrl = @"http://192.168.1.34:18765";

    self.waveView = [[MitaEdgeWaveView alloc] initWithFrame:self.view.bounds];
    self.waveView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.waveView];

    self.cursorView = [[MitaAiCursorView alloc] initWithFrame:self.view.bounds];
    self.cursorView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.cursorView];

    // v5.0.0：将控制胶囊直接挂载在永久透传的 MitaGlowWindow 最顶层，100% 全局永久常驻显示，绝不消失！
    self.takeoverBar = [[MitaTakeoverBarView alloc] initWithFrame:self.view.bounds];
    self.takeoverBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.takeoverBar.hidden = NO;
    self.takeoverBar.alpha = 1.0;
    [self.takeoverBar applyControlMode:MitaControlModeHumanControl animated:NO];
    [self.view addSubview:self.takeoverBar];

    __weak typeof(self) weakSelf = self;
    [self setupGlobalHidTouchMonitor];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayFrame:)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(15, 24, 24);
    } else {
        self.displayLink.preferredFramesPerSecond = 24;
    }
    self.displayLink.paused = YES;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    int edgeToken = 0;
    notify_register_dispatch(MITA_NOTIFY_EDGE_CHANGED, &edgeToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf reloadControlStateNow];
    });

    int lockToken = 0;
    notify_register_dispatch(MITA_NOTIFY_LOCKSTATE, &lockToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf updateLockStatus];
    });

    int blankToken = 0;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf updateLockStatus];
    });

    self.pollSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.pollSource,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(6.0 * NSEC_PER_SEC),
                              (uint64_t)(0.50 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(self.pollSource, ^{
        [weakSelf onPollTick];
    });
    dispatch_resume(self.pollSource);

    [self syncShieldWindowGeometryAnimated:NO];
    [self reloadControlStateNow];
    [self writeDiagnosticsSnapshot];
}

- (void)applyOverlayMasterOffAndHideAll {
    self.overlayMasterVisible = NO;
    self.controlMode = MitaControlModeHumanControl;
    self.controlModeString = @"off";
    self.aiLockExpireAtTs = 0;
    if (self.takeoverBar) {
        self.takeoverBar.masterHidden = YES;
        self.takeoverBar.hidden = YES;
        self.takeoverBar.alpha = 0.0;
        self.takeoverBar.pillBox.hidden = YES;
        self.takeoverBar.hintToastLabel.alpha = 0.0;
    }
    self.view.hidden = YES;
    self.waveView.activeControl = NO;
    self.waveView.activeReplying = NO;
    self.waveView.masterOpacity = 0.0;
    [self.waveView syncGpuOpacityAndMode];
    [self.cursorView hideCursorAnimated:NO];
    [self destroyShieldWindowIfNeeded];
    self.displayLink.paused = YES;
    [self writeDiagnosticsSnapshot];
}

- (void)restoreOverlayMasterVisibleWithMode:(MitaControlMode)mode {
    MitaControlMode eff = (mode == MitaControlModeAiLocked) ? MitaControlModeAiLocked : MitaControlModeHumanControl;
    self.overlayMasterVisible = YES;
    self.controlMode = eff;
    self.controlModeString = MitaControlModeName(eff);
    if (!self.screenLocked) {
        self.view.hidden = NO;
    }
    if (self.takeoverBar) {
        self.takeoverBar.masterHidden = NO;
        self.takeoverBar.hidden = NO;
        self.takeoverBar.alpha = 1.0;
        self.takeoverBar.pillBox.hidden = NO;
        self.takeoverBar.pillBox.alpha = 1.0;
        [self.takeoverBar applyControlMode:eff animated:NO];
    }
    if (!self.screenLocked && self.reassertWindowBlock) {
        self.reassertWindowBlock();
    }
    [self syncShieldWindowGeometryAnimated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.overlayMasterVisible) {
        if (self.takeoverBar) {
            self.takeoverBar.masterHidden = YES;
            self.takeoverBar.hidden = YES;
            self.takeoverBar.alpha = 0.0;
            self.takeoverBar.pillBox.hidden = YES;
        }
        self.view.hidden = YES;
        return;
    }
    if (self.takeoverBar) {
        self.takeoverBar.frame = self.view.bounds;
        self.takeoverBar.hidden = NO;
        self.takeoverBar.alpha = 1.0;
        [self.takeoverBar layoutForCurrentMode];
        [self.view bringSubviewToFront:self.takeoverBar];
    }
}

- (BOOL)tryAcquireActionDebounceLock {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastTouchHandledTs) < 0.42) {
        return NO;
    }
    self.lastTouchHandledTs = now;
    return YES;
}

- (void)flashBlockedHintThrottled {
    if (self.controlMode != MitaControlModeAiLocked || !self.takeoverBar) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastHintToastTs) < 0.26) return;
    self.lastHintToastTs = now;
    [self.takeoverBar flashBlockedTouchHint];
}

- (void)destroyShieldWindowIfNeeded {
    unsigned int oldCtx = self.shieldHostedContextId;
    self.shieldHostedContextId = 0;
    if (self.touchShieldView) {
        self.touchShieldView.onBlockedTouch = nil;
        [self.touchShieldView removeFromSuperview];
        self.touchShieldView = nil;
    }
    if (self.shieldWindow) {
        MitaShieldWindow *win = self.shieldWindow;
        self.shieldWindow = nil;
        win.edgeRootVC = nil;
        win.userInteractionEnabled = NO;
        win.hidden = YES;
        [win removeFromSuperview];
        win.rootViewController = nil;
    }
    if (oldCtx != 0 && self.unregisterHostedContextBlock) {
        self.unregisterHostedContextBlock(oldCtx);
    }
}

- (void)syncShieldWindowGeometryAnimated:(BOOL)animated {
    if (!self.overlayMasterVisible) {
        if (self.takeoverBar) {
            self.takeoverBar.masterHidden = YES;
            self.takeoverBar.hidden = YES;
            self.takeoverBar.alpha = 0.0;
            self.takeoverBar.pillBox.hidden = YES;
        }
        self.view.hidden = YES;
        [self destroyShieldWindowIfNeeded];
        return;
    }

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat W = sb.size.width;
    CGFloat H = sb.size.height;
    if (W < 40.0 || H < 40.0) return;

    if (!self.screenLocked && self.takeoverBar) {
        self.takeoverBar.masterHidden = NO;
        self.takeoverBar.hidden = NO;
        self.takeoverBar.alpha = 1.0;
        self.takeoverBar.pillBox.hidden = NO;
        self.takeoverBar.pillBox.alpha = 1.0;
        if (!CGRectEqualToRect(self.takeoverBar.frame, self.view.bounds)) {
            self.takeoverBar.frame = self.view.bounds;
        }
        [self.takeoverBar layoutForCurrentMode];
        [self.view bringSubviewToFront:self.takeoverBar];
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL gateOpen = (self.passthroughUntilTs > now);

    // 锁屏 / AI 瞬时穿窗期：销毁拦截窗确保解锁与 AI 点击 100% 畅通
    if (self.screenLocked || gateOpen) {
        [self destroyShieldWindowIfNeeded];
        return;
    }

    // v5.4.0 几何隔离防穿透拦截窗：
    // - AiLocked：全屏 sb (414x736) 防误触护盾；
    // - HumanControl：仅包裹大号悬浮胶囊外扩 4pt 的迷你局部拦截窗 (252x54)，点胶囊 0% 穿透底层服务号/聊天，屏幕其余 95.5% 100% 原生自由触控！
    BOOL isAiLocked = (self.controlMode == MitaControlModeAiLocked);
    CGRect pillBase = self.takeoverBar ? [self.takeoverBar basePillRect] : CGRectMake(round(W * 0.5) - 122.0, H - 116.0, 244.0, 46.0);
    CGRect localPillShield = CGRectInset(pillBase, -4.0, -4.0);
    CGRect targetFrame = isAiLocked ? sb : localPillShield;

    // 几何尺寸发生切换（全屏 <-> 迷你胶囊）时，先彻底注销旧 CAContext 再以精确新尺寸重建，100% 杜绝 WindowServer 残留旧命中盒！
    if (self.shieldWindow && !CGRectEqualToRect(self.shieldWindow.frame, targetFrame)) {
        [self destroyShieldWindowIfNeeded];
    }

    BOOL newlyCreated = NO;
    if (!self.shieldWindow) {
        MitaShieldViewController *svc = [[MitaShieldViewController alloc] init];
        MitaShieldWindow *sw = [[MitaShieldWindow alloc] initWithFrame:targetFrame];
        sw.edgeRootVC = self;
        sw.backgroundColor = [UIColor clearColor];
        sw.opaque = NO;
        sw.clipsToBounds = YES;
        sw.layer.cornerRadius = isAiLocked ? 0.0 : (targetFrame.size.height * 0.5);
        sw.userInteractionEnabled = YES;
        sw.rootViewController = svc;
        sw.windowLevel = 10000012.0;

        svc.view.frame = sw.bounds;
        svc.view.backgroundColor = [UIColor clearColor];
        svc.view.clipsToBounds = YES;

        MitaTouchShieldView *tsv = [[MitaTouchShieldView alloc] initWithFrame:sw.bounds];
        tsv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // alpha=0.01 肉眼 100% 透明不可见，但确保 backboardd 跨进程命中测试将其视为实体拦截面，100% 物理吞掉触摸绝不穿透到底层微信！
        tsv.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.01];
        tsv.layer.cornerRadius = isAiLocked ? 0.0 : (targetFrame.size.height * 0.5);
        tsv.clipsToBounds = YES;
        tsv.userInteractionEnabled = YES;
        __weak typeof(self) weakSelf = self;
        tsv.onBlockedTouch = ^{
            if (weakSelf && weakSelf.controlMode == MitaControlModeAiLocked) {
                [weakSelf flashBlockedHintThrottled];
            }
        };
        [svc.view addSubview:tsv];
        self.touchShieldView = tsv;

        sw.hidden = NO;
        self.shieldWindow = sw;
        newlyCreated = YES;
    } else {
        self.shieldWindow.windowLevel = 10000012.0;
        self.shieldWindow.clipsToBounds = YES;
        self.shieldWindow.layer.cornerRadius = isAiLocked ? 0.0 : (targetFrame.size.height * 0.5);
        UIView *sRoot = self.shieldWindow.rootViewController.view;
        sRoot.hidden = NO;
        sRoot.frame = self.shieldWindow.bounds;
        if (self.touchShieldView) {
            self.touchShieldView.frame = self.shieldWindow.bounds;
            self.touchShieldView.layer.cornerRadius = isAiLocked ? 0.0 : (targetFrame.size.height * 0.5);
            self.touchShieldView.hidden = NO;
            self.touchShieldView.userInteractionEnabled = YES;
        }
        self.shieldWindow.hidden = NO;
    }

    if ((newlyCreated || self.shieldHostedContextId == 0) && self.registerHostedWindowBlock) {
        unsigned int sCtx = self.registerHostedWindowBlock(self.shieldWindow);
        if (sCtx != 0) {
            self.shieldHostedContextId = sCtx;
        }
    }
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
                // 锁屏时自动切回常驻 HumanControl（若远控已关闭则保持 off 隐藏）并彻底销毁护盾窗，绝不锁死锁屏滑动解锁
                if (!self.overlayMasterVisible) {
                    [self destroyShieldWindowIfNeeded];
                } else if (self.controlMode == MitaControlModeAiLocked) {
                    [self applyControlModeFromExternal:MitaControlModeHumanControl ttlSec:0 pcUrl:nil];
                } else {
                    [self destroyShieldWindowIfNeeded];
                }
            } else {
                if (!self.overlayMasterVisible) {
                    self.displayLink.paused = YES;
                    self.view.hidden = YES;
                    if (self.takeoverBar) {
                        self.takeoverBar.masterHidden = YES;
                        self.takeoverBar.hidden = YES;
                        self.takeoverBar.alpha = 0.0;
                        self.takeoverBar.pillBox.hidden = YES;
                    }
                    [self destroyShieldWindowIfNeeded];
                    [self reloadControlStateNow];
                } else {
                    self.view.hidden = NO;
                    if (self.takeoverBar) {
                        self.takeoverBar.masterHidden = NO;
                        self.takeoverBar.hidden = NO;
                        self.takeoverBar.alpha = 1.0;
                        self.takeoverBar.pillBox.hidden = NO;
                        self.takeoverBar.pillBox.alpha = 1.0;
                    }
                    if (self.reassertWindowBlock) self.reassertWindowBlock();
                    [self syncShieldWindowGeometryAnimated:NO];
                    [self reloadControlStateNow];
                    __weak typeof(self) weakSelf = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (!weakSelf.screenLocked && weakSelf.overlayMasterVisible && weakSelf.reassertWindowBlock) {
                            weakSelf.reassertWindowBlock();
                            [weakSelf syncShieldWindowGeometryAnimated:NO];
                            [weakSelf reloadControlStateNow];
                        }
                    });
                }
            }
        }
    }
}

- (void)onPollTick {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // v5.6.0：无论当前是否开启远程总控，每 30 秒由后台低优先级向电脑端发一次极轻发现心跳，
    // 确保电脑无需用户先在手机点开「远程操控」即可自动发现手机在线并随时按需拉起控制！
    static NSTimeInterval sLastStandbyHbTs = 0.0;
    if ((now - sLastStandbyHbTs) >= 30.0) {
        sLastStandbyHbTs = now;
        NSString *pcBase = (self.pcCallbackUrl.length > 6) ? self.pcCallbackUrl : @"http://192.168.1.34:18765";
        while ([pcBase hasSuffix:@"/"]) pcBase = [pcBase substringToIndex:pcBase.length - 1];
        NSURL *hbUrl = [NSURL URLWithString:[pcBase stringByAppendingString:@"/api/phone_agent/heartbeat"]];
        if (hbUrl) {
            NSDictionary *hbBody = @{
                @"platform": @"ios",
                @"app": @"MitaEdgeOverlay",
                @"version": @"5.6.0",
                @"port": @(19081),
                @"daemon": @"MitaEdgeOverlay",
                @"standby_discoverable": @(YES),
                @"remote_control_enabled": @(self.overlayMasterVisible),
                @"control_mode": (!self.overlayMasterVisible) ? @"off" : (self.controlModeString ?: @"human_control")
            };
            NSData *jdHb = [NSJSONSerialization dataWithJSONObject:hbBody options:0 error:nil];
            if (jdHb) {
                NSMutableURLRequest *reqHb = [NSMutableURLRequest requestWithURL:hbUrl];
                reqHb.HTTPMethod = @"POST";
                reqHb.timeoutInterval = 2.0;
                [reqHb setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                reqHb.HTTPBody = jdHb;
                [[[NSURLSession sharedSession] dataTaskWithRequest:reqHb completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
            }
        }
    }
    if (!self.overlayMasterVisible) {
        if (self.takeoverBar) {
            self.takeoverBar.masterHidden = YES;
            self.takeoverBar.hidden = YES;
            self.takeoverBar.alpha = 0.0;
            self.takeoverBar.pillBox.hidden = YES;
        }
        self.view.hidden = YES;
        [self destroyShieldWindowIfNeeded];
        if ((now - self.lastWindowReassertTs) >= 15.0) {
            self.lastWindowReassertTs = now;
            [self writeDiagnosticsSnapshot];
        }
        [self reloadControlStateNow];
        return;
    }
    [self syncShieldWindowGeometryAnimated:NO];
    [self.cursorView checkAutoFadeIfIdle];

    // 每 15 秒自动校验并重申顶层窗口可见性，锁屏解锁或桌面切换后 100% 自动恢复显示
    if ((now - self.lastWindowReassertTs) >= 15.0) {
        self.lastWindowReassertTs = now;
        if (!self.screenLocked && self.reassertWindowBlock) {
            self.reassertWindowBlock();
        }
        [self writeDiagnosticsSnapshot];
    }
    [self reloadControlStateNow];
}

- (void)notifyPcAndLocalTakeoverMode:(MitaControlMode)nextMode {
    NSString *modeStr = MitaControlModeName(nextMode);
    if (nextMode == MitaControlModeHumanControl && gStateFilePath.length > 0) {
        // 用户点击「我来接管」时立即在本地状态中停止 AI 脉冲与巡检标记
        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        NSData *raw = [NSData dataWithContentsOfFile:gStateFilePath];
        if (raw.length > 0) {
            id old = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
            if ([old isKindOfClass:[NSDictionary class]]) [st addEntriesFromDictionary:old];
        }
        st[@"running"] = @(NO);
        st[@"pulse_until"] = @(0.0);
        st[@"phase"] = @"idle";
        st[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
        NSData *jdLocal = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
        if (jdLocal) {
            [jdLocal writeToFile:gStateFilePath atomically:YES];
            chmod([gStateFilePath UTF8String], 0666);
        }
    }
    // 1. 切入我来控制时立即同步停止手机本机 :19080 引擎
    NSURL *uLocal = [NSURL URLWithString:@"http://127.0.0.1:19080/toggle_bot"];
    if (uLocal && nextMode == MitaControlModeHumanControl) {
        NSData *lb = [NSJSONSerialization dataWithJSONObject:@{@"running": @(NO)} options:0 error:nil];
        if (lb) {
            NSMutableURLRequest *lReq = [NSMutableURLRequest requestWithURL:uLocal];
            lReq.HTTPMethod = @"POST";
            lReq.timeoutInterval = 1.5;
            [lReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            lReq.HTTPBody = lb;
            [[[NSURLSession sharedSession] dataTaskWithRequest:lReq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
        }
    }
    // 2. 立即回调电脑端 :18765 终止/恢复微信自动操控任务
    NSString *pcBase = (self.pcCallbackUrl.length > 0) ? self.pcCallbackUrl : @"http://192.168.1.34:18765";
    while ([pcBase hasSuffix:@"/"]) pcBase = [pcBase substringToIndex:pcBase.length - 1];
    NSString *ep = (nextMode == MitaControlModeHumanControl)
        ? [pcBase stringByAppendingString:@"/api/ai_control/takeover"]
        : [pcBase stringByAppendingString:@"/api/ai_control/mode"];
    NSDictionary *body = (nextMode == MitaControlModeAiLocked)
        ? @{@"mode": modeStr, @"source": @"phone_overlay_button", @"resume_bot": @(YES), @"start_bot": @(NO)}
        : @{@"mode": modeStr, @"source": @"phone_overlay_button"};
    NSData *jd = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSURL *u = [NSURL URLWithString:ep];
    if (u && jd) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 3.0;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = jd;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
    }
}

// 硬件级全局触摸回调（IOKit 动态安全加载）：确保非 Key 托管窗口中点击「我来接管」与拦截误触提示 100% 毫秒级必中！
typedef void *MitaIOHIDClientRef;
typedef void *MitaIOHIDEventRef;
typedef void (*MitaIOHIDCallbackFn)(void *target, void *refcon, void *sender, MitaIOHIDEventRef event);
typedef MitaIOHIDClientRef (*MitaHIDCreateFn)(CFAllocatorRef);
typedef void (*MitaHIDScheduleFn)(MitaIOHIDClientRef, CFRunLoopRef, CFStringRef);
typedef void (*MitaHIDRegCbFn)(MitaIOHIDClientRef, MitaIOHIDCallbackFn, void *, void *);
typedef uint32_t (*MitaHIDGetTypeFn)(MitaIOHIDEventRef);
typedef CFIndex (*MitaHIDGetIntFn)(MitaIOHIDEventRef, uint32_t);
typedef double (*MitaHIDGetFloatFn)(MitaIOHIDEventRef, uint32_t);

typedef CFArrayRef (*MitaHIDGetChildrenFn)(MitaIOHIDEventRef);

static MitaHIDGetTypeFn gHidGetType = NULL;
static MitaHIDGetIntFn gHidGetInt = NULL;
static MitaHIDGetFloatFn gHidGetFloat = NULL;
static MitaHIDGetChildrenFn gHidGetChildren = NULL;
static BOOL gHidPrevTouching = NO;
static CFAbsoluteTime gHidLastEventTs = 0.0;

static void MitaGlobalHidEventCallback(void *target, void *refcon, void *sender, MitaIOHIDEventRef event) {
    if (!event || !target || !gHidGetType || !gHidGetInt || !gHidGetFloat) return;
    // kIOHIDEventTypeDigitizer = 11
    if (gHidGetType(event) != 11) return;

    CFIndex touching = gHidGetInt(event, (11u << 16) | 9u);
    double nx = gHidGetFloat(event, (11u << 16) | 0u);
    double ny = gHidGetFloat(event, (11u << 16) | 1u);

    if (gHidGetChildren) {
        CFArrayRef children = gHidGetChildren(event);
        if (children && CFArrayGetCount(children) > 0) {
            CFIndex cnt = CFArrayGetCount(children);
            for (CFIndex i = 0; i < cnt; i++) {
                MitaIOHIDEventRef ch = (MitaIOHIDEventRef)CFArrayGetValueAtIndex(children, i);
                if (!ch || gHidGetType(ch) != 11) continue;
                CFIndex chTouch = gHidGetInt(ch, (11u << 16) | 9u);
                if (chTouch != 0) touching = 1;
                if (nx <= 0.0001 && ny <= 0.0001) {
                    double cx = gHidGetFloat(ch, (11u << 16) | 0u);
                    double cy = gHidGetFloat(ch, (11u << 16) | 1u);
                    if (cx > 0.0001 || cy > 0.0001) {
                        nx = cx;
                        ny = cy;
                    }
                }
            }
        }
    }

    CFAbsoluteTime nowAbs = CFAbsoluteTimeGetCurrent();
    BOOL stalePrev = ((nowAbs - gHidLastEventTs) > 0.65);
    gHidLastEventTs = nowAbs;
    BOOL isDownEdge = (touching != 0 && (!gHidPrevTouching || stalePrev));
    gHidPrevTouching = (touching != 0);
    if (!isDownEdge) return;

    if ((nx <= 0.0001 && ny <= 0.0001) || nx < 0.0 || nx > 1.0 || ny < 0.0 || ny > 1.0) return;

    MitaEdgeRootViewController *vc = (__bridge MitaEdgeRootViewController *)target;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.screenLocked || !vc.overlayMasterVisible) return;
        CGRect sb = [UIScreen mainScreen].bounds;
        if (sb.size.width < 20.0 || sb.size.height < 20.0) return;
        CGPoint pt = CGPointMake((CGFloat)(nx * sb.size.width), (CGFloat)(ny * sb.size.height));
        [vc handleOverlayTouchDownAtPoint:pt];
    });
}

- (void)setupGlobalHidTouchMonitor {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) return;
    MitaHIDCreateFn pCreate = (MitaHIDCreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
    MitaHIDScheduleFn pSched = (MitaHIDScheduleFn)dlsym(iokit, "IOHIDEventSystemClientScheduleWithRunLoop");
    MitaHIDRegCbFn pReg = (MitaHIDRegCbFn)dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
    gHidGetType = (MitaHIDGetTypeFn)dlsym(iokit, "IOHIDEventGetType");
    gHidGetInt = (MitaHIDGetIntFn)dlsym(iokit, "IOHIDEventGetIntegerValue");
    gHidGetFloat = (MitaHIDGetFloatFn)dlsym(iokit, "IOHIDEventGetFloatValue");
    gHidGetChildren = (MitaHIDGetChildrenFn)dlsym(iokit, "IOHIDEventGetChildren");
    if (!pCreate || !pSched || !pReg || !gHidGetType || !gHidGetInt || !gHidGetFloat) return;

    MitaIOHIDClientRef cli = pCreate(kCFAllocatorDefault);
    if (!cli) return;
    self.hidEventClient = cli;
    pReg(cli, MitaGlobalHidEventCallback, (__bridge void *)self, NULL);
    pSched(cli, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

- (void)handleOverlayTouchDownAtPoint:(CGPoint)pt {
    if (!self.overlayMasterVisible) return;
    if (self.screenLocked || !self.takeoverBar) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (self.controlMode == MitaControlModeAiLocked) {
        // AI 自身穿窗点击放行期内绝不拦截或误触发
        if (self.passthroughUntilTs > now) return;

        CGRect pillHit = [self.takeoverBar pillHitRectInView:self.view];
        if (!CGRectIsEmpty(pillHit) && CGRectContainsPoint(pillHit, pt)) {
            if ([self tryAcquireActionDebounceLock]) {
                [self.takeoverBar playTapBounceFeedback];
                [self handleTakeoverBarButtonTappedFromMode:MitaControlModeAiLocked];
            }
            return;
        }
        [self flashBlockedHintThrottled];
        return;
    }

    // HumanControl 常驻自由态：shieldWindow == nil，屏幕其余 98% 区域直接 return，真机手指 100% 原生直达微信与桌面！
    // 仅当手指点击胶囊上的「交回 AI」按钮外扩热区时，才立即切换回 AiLocked！
    CGRect actionHit = [self.takeoverBar actionButtonHitRectInView:self.view];
    if (!CGRectIsEmpty(actionHit) && CGRectContainsPoint(actionHit, pt)) {
        if ([self tryAcquireActionDebounceLock]) {
            [self.takeoverBar playTapBounceFeedback];
            [self handleTakeoverBarButtonTappedFromMode:MitaControlModeHumanControl];
        }
    }
}

- (void)handleTakeoverBarButtonTappedFromMode:(MitaControlMode)curMode {
    if (self.controlMode != curMode) return;
    if (curMode == MitaControlModeAiLocked) {
        // 点击「我来接管」-> 0ms 立即切换为常驻 HumanControl，将 shieldWindow 重建为仅覆盖胶囊的迷你局部防穿透窗，释放屏幕其余 95.5% 区域自由触摸
        [self.cursorView hideCursorAnimated:YES];
        self.controlMode = MitaControlModeHumanControl;
        self.controlModeString = @"human_control";
        self.aiLockExpireAtTs = 0;
        [self.takeoverBar applyControlMode:MitaControlModeHumanControl animated:YES];
        [self syncShieldWindowGeometryAnimated:NO];
        self.waveView.activeControl = NO;
        self.waveView.activeReplying = NO;
        self.waveView.phaseLabel = @"我来控制";
        self.displayLink.paused = NO;
        [self.waveView syncGpuOpacityAndMode];
        [self writeDiagnosticsSnapshot];
        [self notifyPcAndLocalTakeoverMode:MitaControlModeHumanControl];
    } else {
        // 点击「交回 AI」-> 立即切换为 AiLocked，新建并注册全屏 shieldWindow 防误触护盾，常驻展示米塔小鼠标，并通知电脑恢复/启动 AI 控制
        self.controlMode = MitaControlModeAiLocked;
        self.controlModeString = @"ai_locked";
        self.aiLockExpireAtTs = 0;
        [self.takeoverBar applyControlMode:MitaControlModeAiLocked animated:YES];
        [self syncShieldWindowGeometryAnimated:NO];
        [self.cursorView ensureVisibleForAiControlAnimated:YES];
        self.waveView.activeControl = YES;
        self.waveView.phaseLabel = @"AI控制中";
        if (self.waveView.masterOpacity < 0.92) self.waveView.masterOpacity = 0.92;
        self.displayLink.paused = NO;
        [self.waveView syncGpuOpacityAndMode];
        [self writeDiagnosticsSnapshot];
        [self notifyPcAndLocalTakeoverMode:MitaControlModeAiLocked];
    }
}

- (void)applyControlModeFromExternal:(MitaControlMode)mode ttlSec:(double)ttlSec pcUrl:(NSString *)pcUrl {
    if (pcUrl.length > 6) self.pcCallbackUrl = pcUrl;
    MitaControlMode effectiveMode = (mode == MitaControlModeAiLocked) ? MitaControlModeAiLocked : MitaControlModeHumanControl;
    [self restoreOverlayMasterVisibleWithMode:effectiveMode];
    self.aiLockExpireAtTs = 0;
    if (effectiveMode == MitaControlModeAiLocked) {
        if (!self.screenLocked) {
            [self.cursorView ensureVisibleForAiControlAnimated:YES];
        }
    } else {
        [self.cursorView hideCursorAnimated:YES];
    }
    [self reloadControlStateNow];
    [self writeDiagnosticsSnapshot];
}

- (void)openPassthroughGateMs:(double)ms {
    if (!self.overlayMasterVisible) return;
    double clamped = MAX(120.0, MIN(8000.0, ms));
    NSTimeInterval until = [[NSDate date] timeIntervalSince1970] + (clamped / 1000.0);
    if (until > self.passthroughUntilTs) {
        self.passthroughUntilTs = until;
    }
    [self syncShieldWindowGeometryAnimated:NO];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((clamped + 20.0) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [weakSelf syncShieldWindowGeometryAnimated:NO];
    });
}

- (void)handleAiThinking:(BOOL)active text:(NSString *)text rawX:(double)rx rawY:(double)ry hasPoint:(BOOL)hasPt lockAi:(BOOL)lockAi {
    if (!self.overlayMasterVisible) return;
    if (lockAi && active && self.controlMode != MitaControlModeHumanControl) {
        [self applyControlModeFromExternal:MitaControlModeAiLocked ttlSec:90.0 pcUrl:nil];
    } else if (self.controlMode == MitaControlModeAiLocked && active) {
        self.aiLockExpireAtTs = [[NSDate date] timeIntervalSince1970] + 90.0;
    }
    CGPoint pt = hasPt ? MitaNormalizePointToBounds(rx, ry, self.view.bounds) : CGPointZero;
    [self.cursorView showThinking:active text:text atPoint:pt hasPoint:hasPt];
    self.waveView.activeReplying = active;
    if (active) {
        self.waveView.activeControl = YES;
        self.waveView.phaseLabel = @"思考中";
        if (self.waveView.masterOpacity < 0.96) {
            if (self.waveView.masterOpacity < 0.90) self.waveView.masterOpacity = 0.90;
            self.displayLink.paused = NO;
        }
    }
    [self.waveView syncGpuOpacityAndMode];
    [self writeDiagnosticsSnapshot];
}

- (void)handleAiCursorTapRawX:(double)rx rawY:(double)ry passthroughMs:(double)pMs lockAi:(BOOL)lockAi {
    if (!self.overlayMasterVisible) return;
    if (lockAi && self.controlMode != MitaControlModeHumanControl) {
        [self applyControlModeFromExternal:MitaControlModeAiLocked ttlSec:120.0 pcUrl:nil];
    } else if (self.controlMode == MitaControlModeAiLocked) {
        self.aiLockExpireAtTs = [[NSDate date] timeIntervalSince1970] + 120.0;
    }
    // 瞬时打开穿窗放行门控，保证 AI 自身注入的物理点击 100% 精准穿透到底层 App
    [self openPassthroughGateMs:(pMs > 50.0 ? pMs : 560.0)];
    CGPoint pt = MitaNormalizePointToBounds(rx, ry, self.view.bounds);
    [self.cursorView playTapAtPoint:pt];
    self.waveView.activeControl = YES;
    self.waveView.activeReplying = YES;
    if (self.waveView.masterOpacity < 0.96) {
        if (self.waveView.masterOpacity < 0.90) self.waveView.masterOpacity = 0.90;
        self.displayLink.paused = NO;
    }
    [self.waveView syncGpuOpacityAndMode];
}

- (void)handleAiCursorSwipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2 duration:(double)dur lockAi:(BOOL)lockAi {
    if (!self.overlayMasterVisible) return;
    if (lockAi && self.controlMode != MitaControlModeHumanControl) {
        [self applyControlModeFromExternal:MitaControlModeAiLocked ttlSec:120.0 pcUrl:nil];
    } else if (self.controlMode == MitaControlModeAiLocked) {
        self.aiLockExpireAtTs = [[NSDate date] timeIntervalSince1970] + 120.0;
    }
    double effDur = (dur > 0.05) ? dur : 0.30;
    [self openPassthroughGateMs:(effDur * 1000.0 + 560.0)];
    CGPoint p1 = MitaNormalizePointToBounds(x1, y1, self.view.bounds);
    CGPoint p2 = MitaNormalizePointToBounds(x2, y2, self.view.bounds);
    [self.cursorView playSwipeFrom:p1 to:p2 duration:effDur];
    self.waveView.activeControl = YES;
    self.waveView.activeReplying = YES;
    if (self.waveView.masterOpacity < 0.96) {
        if (self.waveView.masterOpacity < 0.90) self.waveView.masterOpacity = 0.90;
        self.displayLink.paused = NO;
    }
    [self.waveView syncGpuOpacityAndMode];
}

- (NSDictionary *)liveOverlayStatusDict {
    CGRect sf = self.shieldWindow ? self.shieldWindow.frame : CGRectZero;
    CGRect pf = self.takeoverBar ? [self.takeoverBar basePillRect] : CGRectZero;
    BOOL barVis = (self.overlayMasterVisible && self.takeoverBar && !self.takeoverBar.hidden && !self.takeoverBar.pillBox.hidden && self.takeoverBar.pillBox.alpha >= 0.99);
    NSString *modeOut = (!self.overlayMasterVisible) ? @"off" : (self.controlModeString ?: @"human_control");
    return @{
        @"ok": @(YES),
        @"daemon": @"MitaEdgeOverlay",
        @"version": @"5.7.0",
        @"port": @(19081),
        @"standby_discoverable": @(YES),
        @"push_media_supported": @(YES),
        @"remote_enabled": @(self.overlayMasterVisible),
        @"overlay_master_visible": @(self.overlayMasterVisible),
        @"control_mode": modeOut,
        @"glow_ignores_hit_test": @(YES),
        @"glow_context_id": @(self.hostedContextId),
        @"shield_window_nil": @(self.shieldWindow == nil),
        @"shield_context_id": @(self.shieldHostedContextId),
        @"shield_hidden": @(self.shieldWindow ? self.shieldWindow.hidden : YES),
        @"shield_frame": NSStringFromCGRect(sf),
        @"takeover_bar_visible": @(barVis),
        @"pill_frame": NSStringFromCGRect(pf),
        @"human_compact": @(YES),
        @"ai_thinking": @(self.cursorView.thinkingActive),
        @"thinking_text": self.cursorView.thinkingText ?: @"",
        @"cursor_visible": @(self.cursorView.cursorVisible),
        @"cursor_x": @(self.cursorView.currentPos.x),
        @"cursor_y": @(self.cursorView.currentPos.y),
        @"rendered_frames": @(self.waveView.renderedFrames)
    };
}

- (void)writeDiagnosticsSnapshot {
    if (gDiagFilePath.length == 0) return;
    CGRect sf = self.shieldWindow ? self.shieldWindow.frame : CGRectZero;
    CGRect pf = self.takeoverBar ? [self.takeoverBar basePillRect] : CGRectZero;
    BOOL barVis = (self.overlayMasterVisible && self.takeoverBar && !self.takeoverBar.hidden && !self.takeoverBar.pillBox.hidden && self.takeoverBar.pillBox.alpha >= 0.99);
    NSString *modeOut = (!self.overlayMasterVisible) ? @"off" : (self.controlModeString ?: @"human_control");
    NSDictionary *diag = @{
        @"pid": @(getpid()),
        @"uid": @(getuid()),
        @"version": @"5.7.0",
        @"standby_discoverable": @(YES),
        @"push_media_supported": @(YES),
        @"remote_enabled": @(self.overlayMasterVisible),
        @"context_id": @(self.hostedContextId),
        @"overlay_master_visible": @(self.overlayMasterVisible),
        @"takeover_bar_visible": @(barVis),
        @"shield_window_nil": @(self.shieldWindow == nil),
        @"shield_context_id": @(self.shieldHostedContextId),
        @"shield_hidden": @(self.shieldWindow ? self.shieldWindow.hidden : YES),
        @"shield_frame": NSStringFromCGRect(sf),
        @"pill_frame": NSStringFromCGRect(pf),
        @"control_mode": modeOut,
        @"active_control": @(self.waveView.activeControl),
        @"active_replying": @(self.waveView.activeReplying),
        @"opacity": @(self.waveView.masterOpacity),
        @"rendered_frames": @(self.waveView.renderedFrames),
        @"stopped_checks": @(self.consecutiveStoppedChecks),
        @"ts": @((NSInteger)[[NSDate date] timeIntervalSince1970])
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:diag options:0 error:nil];
    if (d) {
        [d writeToFile:gDiagFilePath atomically:YES];
        chmod([gDiagFilePath UTF8String], 0666);
    }
}

- (void)probeLocalStatusForGraceCheck {
    if (self.statusProbeInFlight) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastStatusProbeTs) < 1.8) return;
    self.statusProbeInFlight = YES;
    self.lastStatusProbeTs = now;

    NSURL *u = [NSURL URLWithString:@"http://127.0.0.1:19080/status"];
    NSURLRequest *req = [NSURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.5];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        BOOL explicitStopped = NO;
        BOOL explicitRunning = NO;
        if (!e && d.length > 0) {
            id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([o isKindOfClass:[NSDictionary class]] && (o[@"remote_control_enabled"] != nil || o[@"bot_running"] != nil)) {
                BOOL rcOn = o[@"remote_control_enabled"] ? [o[@"remote_control_enabled"] boolValue] : NO;
                BOOL botOn = o[@"bot_running"] ? [o[@"bot_running"] boolValue] : NO;
                if (rcOn || botOn) {
                    explicitRunning = YES;
                } else {
                    explicitStopped = YES;
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.statusProbeInFlight = NO;
            if (explicitRunning) {
                strongSelf.consecutiveStoppedChecks = 0;
                strongSelf.lastSeenUpdatedAt = [[NSDate date] timeIntervalSince1970];
            } else if (explicitStopped) {
                strongSelf.consecutiveStoppedChecks += 1;
            }
            [strongSelf reloadControlStateNow];
        });
    }] resume];
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
    BOOL hasRemoteKey = (state[@"remote_enabled"] != nil && state[@"remote_enabled"] != [NSNull null]);
    BOOL remoteEnabled = hasRemoteKey ? [state[@"remote_enabled"] boolValue] : YES;
    if (!edgeEnabled || (hasRemoteKey && !remoteEnabled)) {
        [self applyOverlayMasterOffAndHideAll];
        return;
    }
    if (!self.overlayMasterVisible && edgeEnabled && remoteEnabled) {
        MitaControlMode restoreMode = (self.controlMode == MitaControlModeAiLocked) ? MitaControlModeAiLocked : MitaControlModeHumanControl;
        [self restoreOverlayMasterVisibleWithMode:restoreMode];
    }

    BOOL botRunning = [state[@"running"] boolValue];
    NSTimeInterval pulseUntil = [state[@"pulse_until"] doubleValue];
    NSTimeInterval updatedAt = [state[@"updated_at"] doubleValue];
    BOOL hasPulse = (pulseUntil > now);

    // 一旦检测到新的 updated_at 或脉冲激活，立即清零离线停止计数
    if (updatedAt > self.lastSeenUpdatedAt + 0.001) {
        self.lastSeenUpdatedAt = updatedAt;
        if (botRunning || hasPulse) {
            self.consecutiveStoppedChecks = 0;
        }
    } else if (hasPulse) {
        self.consecutiveStoppedChecks = 0;
    }

    // 离线宽限期设为 60s，且需连续 3 次请求 127.0.0.1:19080/status（超时 1.5s）均明确返回 bot_running == false 才淡出
    if (botRunning && updatedAt > 0 && (now - updatedAt) > 60.0) {
        if (self.consecutiveStoppedChecks >= 3) {
            botRunning = NO;
        } else {
            [self probeLocalStatusForGraceCheck];
        }
    }

    BOOL shouldShow = edgeEnabled && (botRunning || hasPulse || self.controlMode == MitaControlModeAiLocked) && (self.controlMode != MitaControlModeHumanControl);
    NSString *phaseStr = [state[@"phase"] isKindOfClass:[NSString class]] ? state[@"phase"] : @"idle";
    BOOL isLively = hasPulse
                 || (self.controlMode == MitaControlModeAiLocked)
                 || [phaseStr isEqualToString:@"replying"]
                 || [phaseStr isEqualToString:@"analyzing"]
                 || [phaseStr isEqualToString:@"entering"]
                 || [phaseStr isEqualToString:@"controlling"]
                 || [phaseStr isEqualToString:@"burnin"];
    NSString *lbl = @"远程联机";
    if (self.cursorView.thinkingActive || [phaseStr isEqualToString:@"thinking"]) {
        lbl = @"思考中";
    } else if (self.controlMode == MitaControlModeHumanControl) {
        lbl = @"我来控制";
    } else if (self.controlMode == MitaControlModeAiLocked) {
        lbl = @"AI控制中";
    } else if ([phaseStr isEqualToString:@"replying"] || [phaseStr isEqualToString:@"generating"] || [phaseStr isEqualToString:@"analyzing"]) {
        lbl = @"微信回复";
    } else if ([phaseStr isEqualToString:@"burnin"]) {
        lbl = @"防烧屏";
    } else if ([phaseStr isEqualToString:@"controlling"]) {
        lbl = @"远程操控";
    } else if ([phaseStr isEqualToString:@"watching"] || [phaseStr isEqualToString:@"patrolling"]) {
        lbl = @"微信值守";
    } else if ([phaseStr isEqualToString:@"remote"]) {
        lbl = @"远程联机";
    }

    NSTimeInterval startTs = [state[@"started_at"] doubleValue];
    if (shouldShow && startTs <= 0) {
        startTs = self.waveView.startedAtTs > 0 ? self.waveView.startedAtTs : now;
    } else if (!shouldShow) {
        startTs = 0;
    }

    BOOL wasShowing = self.waveView.activeControl;
    self.waveView.activeControl = shouldShow;
    self.waveView.activeReplying = isLively;
    self.waveView.phaseLabel = lbl;
    self.waveView.startedAtTs = startTs;

    if (shouldShow) {
        if (!wasShowing && self.reassertWindowBlock) {
            self.reassertWindowBlock();
        }
        if (self.waveView.masterOpacity < 0.96) {
            self.displayLink.paused = NO;
        }
        [self.waveView syncGpuOpacityAndMode];
    } else if (self.waveView.masterOpacity > 0.005) {
        [self.waveView syncGpuOpacityAndMode];
        self.displayLink.paused = NO;
    }
}

- (void)onDisplayFrame:(CADisplayLink *)link {
    BOOL want = self.waveView.activeControl && !self.screenLocked;
    CGFloat target = want ? 0.97 : 0.0;
    CGFloat cur = self.waveView.masterOpacity;
    if (cur < target) {
        cur = MIN(target, cur + 0.16);
    } else if (cur > target) {
        cur = MAX(target, cur - 0.12);
    }
    self.waveView.masterOpacity = cur;
    self.waveView.renderedFrames += 1;
    [self.waveView syncGpuOpacityAndMode];

    // 淡入或淡出到位后立即暂停 CADisplayLink（0% CPU 零发热！纯靠 CoreAnimation 硬件合成旋转极光雾环）
    if (fabs(cur - target) <= 0.005) {
        self.waveView.masterOpacity = target;
        self.lastFrameTs = 0.0;
        [self.waveView syncGpuOpacityAndMode];
        self.displayLink.paused = YES;
    }
}

@end

@implementation MitaGlowWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_canBecomeKeyWindow { return NO; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

@end

@implementation MitaShieldWindow

+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_canBecomeKeyWindow { return NO; }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    MitaEdgeRootViewController *vc = self.edgeRootVC;
    if (!vc || vc.screenLocked || self.hidden || !vc.overlayMasterVisible) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (vc.passthroughUntilTs > now) return NO;
    return CGRectContainsPoint(self.bounds, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    MitaEdgeRootViewController *vc = self.edgeRootVC;
    if (!vc || vc.screenLocked || self.hidden || !vc.overlayMasterVisible) return nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (vc.passthroughUntilTs > now) return nil;
    if (CGRectContainsPoint(self.bounds, point)) {
        return vc.touchShieldView;
    }
    return nil;
}

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        MitaEdgeRootViewController *vc = self.edgeRootVC;
        if (vc && !vc.screenLocked && !self.hidden && vc.overlayMasterVisible) {
            for (UITouch *t in [event allTouches]) {
                if (t.phase == UITouchPhaseBegan) {
                    CGPoint locInWin = [t locationInView:self];
                    CGPoint ptInScreen = CGPointMake(self.frame.origin.x + locInWin.x, self.frame.origin.y + locInWin.y);
                    [vc handleOverlayTouchDownAtPoint:ptInScreen];
                    break;
                }
            }
        }
    }
    [super sendEvent:event];
}

@end

static void MitaEdgeSendHttp(int fd, int code, NSDictionary *obj) {
    NSData *body = obj ? ([NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] ?: [NSData data]) : [NSData data];
    NSString *hdr = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        code, (code == 200 ? @"OK" : @"Not Found"), (unsigned long)body.length];
    NSData *hd = [hdr dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, hd.bytes, hd.length, 0);
    if (body.length > 0) send(fd, body.bytes, body.length, 0);
}

static NSString *MitaEdgeExtractCopyText(NSDictionary *act) {
    if (![act isKindOfClass:[NSDictionary class]]) return @"";
    id b64 = act[@"text_b64"];
    if ([b64 isKindOfClass:[NSString class]] && [(NSString *)b64 length] > 0) {
        NSData *dec = [[NSData alloc] initWithBase64EncodedString:(NSString *)b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (dec.length > 0) {
            NSString *s = [[NSString alloc] initWithData:dec encoding:NSUTF8StringEncoding];
            if (s != nil) return s;
        }
    }
    id raw = act[@"text"];
    if ([raw isKindOfClass:[NSString class]]) return (NSString *)raw;
    return @"";
}

static NSString *MitaPhotoAuthString(PHAuthorizationStatus st) {
    if (@available(iOS 14, *)) {
        if (st == PHAuthorizationStatusLimited) return @"limited";
    }
    switch (st) {
        case PHAuthorizationStatusAuthorized: return @"authorized";
        case PHAuthorizationStatusDenied: return @"denied";
        case PHAuthorizationStatusRestricted: return @"restricted";
        default: return @"not_determined";
    }
}

static NSDictionary *MitaSaveMediaFileToPhotosSync(NSString *filePath) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return @{@"ok": @(NO), @"error": @"media_file_missing"};
    }
    NSString *ext = [[filePath pathExtension] lowercaseString] ?: @"jpg";
    BOOL isVideo = ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"]);
    NSURL *fileUrl = [NSURL fileURLWithPath:filePath];

    __block PHAuthorizationStatus authSt = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (authSt == PHAuthorizationStatusNotDetermined) {
        __block BOOL authDone = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                authSt = status;
                authDone = YES;
            }];
        });
        NSTimeInterval deadline = [[NSDate date] timeIntervalSince1970] + 8.0;
        while (!authDone && [[NSDate date] timeIntervalSince1970] < deadline) {
            if ([NSThread isMainThread]) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
            } else {
                usleep(30000);
            }
        }
    }

    __block BOOL saveOk = NO;
    __block NSString *localId = @"";
    __block NSString *errMsg = @"";
    __block BOOL saveDone = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetChangeRequest *req = nil;
            if (isVideo) {
                req = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileUrl];
            } else {
                req = [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileUrl];
                if (!req) {
                    UIImage *img = [UIImage imageWithContentsOfFile:filePath];
                    if (img) {
                        req = [PHAssetChangeRequest creationRequestForAssetFromImage:img];
                    }
                }
            }
            if (req && req.placeholderForCreatedAsset.localIdentifier) {
                localId = [req.placeholderForCreatedAsset.localIdentifier copy];
            }
        } completionHandler:^(BOOL success, NSError * _Nullable error) {
            saveOk = success;
            if (error) {
                errMsg = [error localizedDescription] ?: [error description];
            }
            saveDone = YES;
        }];
    });

    NSTimeInterval saveDeadline = [[NSDate date] timeIntervalSince1970] + 15.0;
    while (!saveDone && [[NSDate date] timeIntervalSince1970] < saveDeadline) {
        if ([NSThread isMainThread]) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
        } else {
            usleep(30000);
        }
    }
    if (!saveDone && errMsg.length == 0) {
        errMsg = @"photos_commit_timeout";
    }
    return @{
        @"ok": @(saveOk),
        @"local_id": localId ?: @"",
        @"media_type": isVideo ? @"video" : @"image",
        @"photo_auth": MitaPhotoAuthString(authSt),
        @"error": errMsg ?: @""
    };
}

static NSDictionary *MitaPushMediaViaMobileHelper(NSData *mediaBytes, NSString *filename) {
    if (!mediaBytes || mediaBytes.length == 0) {
        return @{@"ok": @(NO), @"error": @"empty_media_bytes"};
    }
    NSMutableString *clean = [NSMutableString string];
    NSString *rawName = filename ?: @"";
    for (NSUInteger i = 0; i < rawName.length; i++) {
        unichar ch = [rawName characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-') {
            [clean appendFormat:@"%C", ch];
        } else {
            [clean appendString:@"_"];
        }
    }
    if (clean.length == 0 || [clean hasPrefix:@"."]) {
        [clean setString:[NSString stringWithFormat:@"mita_%lld.jpg", (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)]];
    }
    if ([clean pathExtension].length == 0) {
        [clean appendString:@".jpg"];
    }

    long long tsMs = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSString *cacheDir = @"/var/mobile/Library/Caches";
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *mediaPath = [cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"mita_push_%lld_%@", tsMs, clean]];
    NSString *resJsonPath = [cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"mita_push_%lld.json", tsMs]];

    if (![mediaBytes writeToFile:mediaPath atomically:YES]) {
        return @{@"ok": @(NO), @"error": @"write_temp_media_failed"};
    }
    chown([mediaPath UTF8String], 501, 501);
    chmod([mediaPath UTF8String], 0666);

    NSDictionary *result = nil;
    char exeBuf[2048];
    uint32_t exeLen = sizeof(exeBuf);
    if (getuid() != 501 && _NSGetExecutablePath(exeBuf, &exeLen) == 0) {
        typedef int (*MitaPMSetPersonaFn)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
        typedef int (*MitaPMSetUidFn)(const posix_spawnattr_t * __restrict, uid_t);
        MitaPMSetPersonaFn fnP = (MitaPMSetPersonaFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        MitaPMSetUidFn fnU = (MitaPMSetUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        MitaPMSetUidFn fnG = (MitaPMSetUidFn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        if (fnP) fnP(&attr, 99, 1);
        if (fnU) fnU(&attr, 501);
        if (fnG) fnG(&attr, 501);
        const char *argvChild[] = { exeBuf, "-push_media", [mediaPath UTF8String], [resJsonPath UTF8String], NULL };
        pid_t child = 0;
        int spRc = posix_spawn(&child, exeBuf, NULL, &attr, (char * const *)argvChild, environ);
        posix_spawnattr_destroy(&attr);

        if (spRc == 0 && child > 0) {
            int st = 0;
            NSTimeInterval deadline = [[NSDate date] timeIntervalSince1970] + 15.0;
            while ([[NSDate date] timeIntervalSince1970] < deadline) {
                pid_t wr = waitpid(child, &st, WNOHANG);
                if (wr == child || wr < 0) break;
                usleep(25000);
            }
            NSData *jd = [NSData dataWithContentsOfFile:resJsonPath];
            if (jd.length > 0) {
                id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    result = (NSDictionary *)obj;
                }
            }
        }
    }

    if (!result) {
        result = MitaSaveMediaFileToPhotosSync(mediaPath);
    }

    unlink([mediaPath UTF8String]);
    unlink([resJsonPath UTF8String]);

    NSMutableDictionary *out = [result mutableCopy] ?: [NSMutableDictionary dictionary];
    out[@"bytes"] = @(mediaBytes.length);
    out[@"filename"] = clean;
    out[@"version"] = @"5.7.0";
    return out;
}

static void MitaEdgeHandleClient(int fd, MitaEdgeRootViewController * __weak weakVC) {
    struct timeval tv = {18, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
    int noSig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, sizeof(noSig));
#endif
    NSMutableData *buf = [NSMutableData data];
    char chunk[16384];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
    NSInteger cLen = 0;
    while (buf.length < 37748736) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
        if (hdrEnd.location == NSNotFound) {
            hdrEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
            if (hdrEnd.location != NSNotFound) {
                NSData *hdrSlice = [buf subdataWithRange:NSMakeRange(0, hdrEnd.location)];
                NSString *hs = [[NSString alloc] initWithData:hdrSlice encoding:NSUTF8StringEncoding] ?: @"";
                for (NSString *ln in [hs componentsSeparatedByString:@"\r\n"]) {
                    if ([[ln lowercaseString] hasPrefix:@"content-length:"]) {
                        cLen = [[[ln substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];
                    }
                }
                if (cLen > 37748736) {
                    MitaEdgeSendHttp(fd, 413, @{@"ok": @(NO), @"error": @"payload_too_large"});
                    close(fd);
                    return;
                }
            }
        }
        if (hdrEnd.location != NSNotFound && buf.length >= hdrEnd.location + 4 + (NSUInteger)MAX(0, cLen)) break;
    }
    if (hdrEnd.location == NSNotFound) { close(fd); return; }
    NSString *hs = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *parts = [[[hs componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    NSString *fullPath = (parts.count > 1) ? parts[1] : @"/";
    NSString *path = [[fullPath componentsSeparatedByString:@"?"] firstObject] ?: @"/";
    NSString *query = [fullPath containsString:@"?"] ? ([[fullPath componentsSeparatedByString:@"?"] lastObject] ?: @"") : @"";
    NSUInteger avail = (buf.length > hdrEnd.location + 4) ? (buf.length - hdrEnd.location - 4) : 0;
    NSUInteger take = (cLen > 0 && (NSUInteger)cLen < avail) ? (NSUInteger)cLen : avail;
    NSData *bodyData = (take > 0) ? [buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, take)] : [NSData data];

    if ([path isEqualToString:@"/ping"] || [path isEqualToString:@"/status"]) {
        __block NSDictionary *stOut = @{@"ok": @(YES), @"daemon": @"MitaEdgeOverlay", @"version": @"5.7.0", @"port": @(19081), @"standby_discoverable": @(YES), @"push_media_supported": @(YES)};
        MitaEdgeRootViewController *strongVC = weakVC;
        if (strongVC) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                stOut = [strongVC liveOverlayStatusDict];
            });
        }
        MitaEdgeSendHttp(fd, 200, stOut);
    } else if ([path isEqualToString:@"/permissions"]) {
        PHAuthorizationStatus rwSt = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        PHAuthorizationStatus addSt = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        MitaEdgeSendHttp(fd, 200, @{
            @"ok": @(YES),
            @"version": @"5.7.0",
            @"photos_status": MitaPhotoAuthString(rwSt),
            @"photos_add_status": MitaPhotoAuthString(addSt),
            @"push_media_supported": @(YES)
        });
    } else if ([path isEqualToString:@"/push_media"]) {
        id obj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : nil;
        NSData *mediaData = nil;
        NSString *fname = @"";
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)obj;
            fname = [dict[@"filename"] isKindOfClass:[NSString class]] ? dict[@"filename"] : @"";
            NSString *b64 = [dict[@"data_b64"] isKindOfClass:[NSString class]] ? dict[@"data_b64"] : @"";
            NSRange comma = [b64 rangeOfString:@","];
            if (comma.location != NSNotFound && [[b64 substringToIndex:comma.location] containsString:@"base64"]) {
                b64 = [b64 substringFromIndex:(comma.location + 1)];
            }
            if (b64.length > 0) {
                mediaData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            }
        } else if (bodyData.length > 0) {
            mediaData = bodyData;
            for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
                if ([kv hasPrefix:@"filename="]) {
                    fname = [[kv substringFromIndex:9] stringByRemovingPercentEncoding] ?: @"";
                }
            }
        }
        NSDictionary *pmRes = MitaPushMediaViaMobileHelper(mediaData, fname);
        MitaEdgeSendHttp(fd, 200, pmRes);
    } else if ([path isEqualToString:@"/exit"]) {
        MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"exiting": @(YES), @"version": @"5.7.0"});
        close(fd);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_MSEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (gPidFilePath.length > 0) {
                NSString *curPid = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
                if ([curPid intValue] == getpid()) {
                    unlink([gPidFilePath UTF8String]);
                }
            }
            exit(0);
        });
        return;
    } else if ([path isEqualToString:@"/action"] || [path isEqualToString:@"/copy_text"]) {
        id obj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
        NSString *actType = [[dict[@"action"] ?: dict[@"type"] ?: @"" description] lowercaseString];
        if ([actType isEqualToString:@"ai_cursor_tap"] || [actType isEqualToString:@"cursor_tap"]) {
            double rx = [dict[@"x"] doubleValue];
            double ry = [dict[@"y"] doubleValue];
            double pMs = dict[@"passthrough_ms"] ? [dict[@"passthrough_ms"] doubleValue] : 480.0;
            BOOL lockAi = dict[@"lock_ai"] ? [dict[@"lock_ai"] boolValue] : NO;
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [strongVC handleAiCursorTapRawX:rx rawY:ry passthroughMs:pMs lockAi:lockAi];
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_cursor_tap", @"x": @(rx), @"y": @(ry), @"version": @"5.2.0"});
        } else if ([actType isEqualToString:@"ai_cursor_swipe"] || [actType isEqualToString:@"cursor_swipe"]) {
            double x1 = [dict[@"x1"] doubleValue];
            double y1 = [dict[@"y1"] doubleValue];
            double x2 = [dict[@"x2"] doubleValue];
            double y2 = [dict[@"y2"] doubleValue];
            double dur = dict[@"duration"] ? [dict[@"duration"] doubleValue] : 0.30;
            BOOL lockAi = dict[@"lock_ai"] ? [dict[@"lock_ai"] boolValue] : NO;
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [strongVC handleAiCursorSwipeFromX:x1 y:y1 toX:x2 y:y2 duration:dur lockAi:lockAi];
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_cursor_swipe", @"version": @"5.2.0"});
        } else if ([actType isEqualToString:@"ai_thinking"] || [actType isEqualToString:@"thinking"]) {
            BOOL active = dict[@"active"] ? [dict[@"active"] boolValue] : YES;
            NSString *txt = [dict[@"text"] isKindOfClass:[NSString class]] ? dict[@"text"] : @"思考中";
            BOOL hasPt = (dict[@"x"] != nil && dict[@"y"] != nil);
            double rx = hasPt ? [dict[@"x"] doubleValue] : 0.0;
            double ry = hasPt ? [dict[@"y"] doubleValue] : 0.0;
            BOOL lockAi = dict[@"lock_ai"] ? [dict[@"lock_ai"] boolValue] : active;
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [strongVC handleAiThinking:active text:txt rawX:rx rawY:ry hasPoint:hasPt lockAi:lockAi];
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_thinking", @"active": @(active), @"version": @"5.2.0"});
        } else if ([actType isEqualToString:@"set_control_mode"] || [actType isEqualToString:@"takeover"]) {
            NSString *mStr = [[dict[@"mode"] ?: @"human_control" description] lowercaseString];
            BOOL hasRemoteKey = (dict[@"remote_enabled"] != nil && dict[@"remote_enabled"] != [NSNull null]);
            BOOL remoteOff = (hasRemoteKey && ![dict[@"remote_enabled"] boolValue]);
            BOOL modeOff = ([mStr isEqualToString:@"off"] || [mStr isEqualToString:@"disabled"] || [mStr isEqualToString:@"hidden"]);
            NSString *pcUrl = [dict[@"pc_url"] isKindOfClass:[NSString class]] ? dict[@"pc_url"] : nil;
            if (modeOff || remoteOff) {
                if (gStateFilePath.length > 0) {
                    NSMutableDictionary *st = [NSMutableDictionary dictionary];
                    NSData *raw = [NSData dataWithContentsOfFile:gStateFilePath];
                    if (raw.length > 0) {
                        id old = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
                        if ([old isKindOfClass:[NSDictionary class]]) [st addEntriesFromDictionary:old];
                    }
                    st[@"running"] = @(NO);
                    st[@"remote_enabled"] = @(NO);
                    st[@"pulse_until"] = @(0.0);
                    st[@"phase"] = @"idle";
                    st[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
                    NSData *jd = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
                    if (jd) {
                        [jd writeToFile:gStateFilePath atomically:YES];
                        chmod([gStateFilePath UTF8String], 0666);
                    }
                }
                MitaEdgeRootViewController *strongVC = weakVC;
                if (strongVC) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        if (pcUrl.length > 6) strongVC.pcCallbackUrl = pcUrl;
                        [strongVC applyOverlayMasterOffAndHideAll];
                    });
                }
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_control_mode", @"control_mode": @"off", @"version": @"5.2.0"});
            } else {
                MitaControlMode mode = MitaControlModeHumanControl;
                if ([mStr isEqualToString:@"ai_locked"] || [mStr isEqualToString:@"ai"] || [mStr isEqualToString:@"locked"]) {
                    mode = MitaControlModeAiLocked;
                }
                double ttlSec = dict[@"ttl_sec"] ? [dict[@"ttl_sec"] doubleValue] : 90.0;
                if (gStateFilePath.length > 0 && (!hasRemoteKey || [dict[@"remote_enabled"] boolValue])) {
                    NSMutableDictionary *st = [NSMutableDictionary dictionary];
                    NSData *raw = [NSData dataWithContentsOfFile:gStateFilePath];
                    if (raw.length > 0) {
                        id old = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
                        if ([old isKindOfClass:[NSDictionary class]]) [st addEntriesFromDictionary:old];
                    }
                    // v5.6.0: 电脑端主动唤醒接管时强制置 edge_enabled & remote_enabled 为 YES，无需手机端先手动开启！
                    st[@"edge_enabled"] = @(YES);
                    st[@"remote_enabled"] = @(YES);
                    st[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
                    NSData *jd = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
                    if (jd) {
                        [jd writeToFile:gStateFilePath atomically:YES];
                        chmod([gStateFilePath UTF8String], 0666);
                    }
                    // 异步顺带同步本机主 App :19080 远程开关状态（若主 App 挂起也完全不影响 :19081 即刻生效）
                    NSURL *u19080 = [NSURL URLWithString:@"http://127.0.0.1:19080/toggle_remote"];
                    if (u19080) {
                        NSData *b19 = [NSJSONSerialization dataWithJSONObject:@{@"remote_control_enabled": @(YES)} options:0 error:nil];
                        if (b19) {
                            NSMutableURLRequest *r19 = [NSMutableURLRequest requestWithURL:u19080];
                            r19.HTTPMethod = @"POST";
                            r19.timeoutInterval = 0.45;
                            [r19 setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
                            r19.HTTPBody = b19;
                            [[[NSURLSession sharedSession] dataTaskWithRequest:r19 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
                        }
                    }
                }
                MitaEdgeRootViewController *strongVC = weakVC;
                if (strongVC) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [strongVC applyControlModeFromExternal:mode ttlSec:ttlSec pcUrl:pcUrl];
                    });
                }
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_control_mode", @"control_mode": MitaControlModeName(mode), @"version": @"5.2.0"});
            }
        } else if ([actType isEqualToString:@"clean_capture_pause"]) {
            // v5.6.0 AI 纯净截屏专用瞬时隐身门：拍完即刻自动恢复，确保 AI 看到的永远是无悬浮框、无鼠标、无蓝边的纯净原屏！
            double hideMs = dict[@"ms"] ? [dict[@"ms"] doubleValue] : 380.0;
            if (hideMs < 80.0) hideMs = 80.0;
            if (hideMs > 2500.0) hideMs = 2500.0;
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    strongVC.view.hidden = YES;
                    [CATransaction flush];
                });
                static uint64_t sCleanCapSeq = 0;
                uint64_t mySeq = ++sCleanCapSeq;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hideMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    if (sCleanCapSeq == mySeq && strongVC && strongVC.overlayMasterVisible && !strongVC.screenLocked) {
                        strongVC.view.hidden = NO;
                        [CATransaction flush];
                    }
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_clean_pause", @"ms": @(hideMs), @"version": @"5.6.0"});
        } else if ([actType isEqualToString:@"clean_capture_resume"]) {
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    if (strongVC.overlayMasterVisible && !strongVC.screenLocked) {
                        strongVC.view.hidden = NO;
                        [CATransaction flush];
                    }
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_clean_resume", @"version": @"5.6.0"});
        } else if ([actType isEqualToString:@"passthrough"]) {
            double pMs = dict[@"ms"] ? [dict[@"ms"] doubleValue] : (dict[@"passthrough_ms"] ? [dict[@"passthrough_ms"] doubleValue] : 600.0);
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [strongVC openPassthroughGateMs:pMs];
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_passthrough", @"ms": @(pMs), @"version": @"5.2.0"});
        } else if ([actType isEqualToString:@"push_media"]) {
            NSString *fname = [dict[@"filename"] isKindOfClass:[NSString class]] ? dict[@"filename"] : @"";
            NSString *b64 = [dict[@"data_b64"] isKindOfClass:[NSString class]] ? dict[@"data_b64"] : @"";
            NSRange comma = [b64 rangeOfString:@","];
            if (comma.location != NSNotFound && [[b64 substringToIndex:comma.location] containsString:@"base64"]) {
                b64 = [b64 substringFromIndex:(comma.location + 1)];
            }
            NSData *mediaData = (b64.length > 0) ? [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
            NSDictionary *pmRes = MitaPushMediaViaMobileHelper(mediaData, fname);
            MitaEdgeSendHttp(fd, 200, pmRes);
        } else if ([actType isEqualToString:@"launch_app"] || [actType isEqualToString:@"open_app"]) {
            NSString *bid = [dict[@"bundle_id"] ?: dict[@"app"] ?: @"" description];
            __block BOOL opened = NO;
            if (bid.length > 0) {
                @try {
                    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
                    SEL defSel = NSSelectorFromString(@"defaultWorkspace");
                    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
                    if (wsCls && [wsCls respondsToSelector:defSel]) {
                        id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
                        if (ws && [ws respondsToSelector:openSel]) {
                            opened = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(ws, openSel, bid);
                        }
                    }
                } @catch (NSException *ex) {}
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(opened), @"channel": @"edge_19081_lsworkspace", @"bundle_id": bid ?: @"", @"steps": @[@{@"ok": @(opened)}], @"version": @"5.2.0"});
        } else {
            NSString *txt = MitaEdgeExtractCopyText(dict);
            if (txt.length > 0) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [UIPasteboard generalPasteboard].string = txt;
                });
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081", @"len": @(txt.length), @"version": @"5.2.0"});
            } else {
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(NO), @"error": @"empty_text"});
            }
        }
    } else if ([path isEqualToString:@"/edge_pulse"]) {
        id obj = bodyData.length ? [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil] : @{};
        NSDictionary *dict = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
        double sec = dict[@"seconds"] ? [dict[@"seconds"] doubleValue] : 8.0;
        NSString *ph = [dict[@"phase"] isKindOfClass:[NSString class]] ? dict[@"phase"] : @"controlling";
        BOOL hasRemoteFlag = (dict[@"remote_enabled"] != nil && dict[@"remote_enabled"] != [NSNull null]);
        BOOL remoteFlag = hasRemoteFlag ? [dict[@"remote_enabled"] boolValue] : YES;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (gStateFilePath.length > 0) {
            NSMutableDictionary *st = [NSMutableDictionary dictionary];
            NSData *raw = [NSData dataWithContentsOfFile:gStateFilePath];
            if (raw.length > 0) {
                id old = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
                if ([old isKindOfClass:[NSDictionary class]]) [st addEntriesFromDictionary:old];
            }
            if ((hasRemoteFlag && !remoteFlag) || [ph isEqualToString:@"idle"] || sec <= 0.0) {
                st[@"running"] = @(NO);
                if (hasRemoteFlag && !remoteFlag) {
                    st[@"remote_enabled"] = @(NO);
                }
                st[@"pulse_until"] = @(0.0);
                st[@"phase"] = @"idle";
            } else {
                st[@"edge_enabled"] = @(YES);
                if (hasRemoteFlag && remoteFlag) {
                    st[@"running"] = @(YES);
                    st[@"remote_enabled"] = @(YES);
                }
                st[@"pulse_until"] = @(now + MAX(2.0, MIN(30.0, sec)));
                st[@"phase"] = ph;
            }
            st[@"updated_at"] = @(now);
            NSData *jd = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
            if (jd) {
                [jd writeToFile:gStateFilePath atomically:YES];
                chmod([gStateFilePath UTF8String], 0666);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakVC reloadControlStateNow];
        });
        MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_pulse", @"version": @"5.2.0"});
    } else {
        MitaEdgeSendHttp(fd, 404, @{@"ok": @(NO), @"error": @"not_found"});
    }
    close(fd);
}

static void MitaStartEdgeDaemonHttpServer(MitaEdgeRootViewController * __weak weakVC) {
    signal(SIGPIPE, SIG_IGN);
    dispatch_queue_t srvQ = dispatch_queue_create("com.mita.edge.http19081", DISPATCH_QUEUE_CONCURRENT);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (YES) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { sleep(2); continue; }
            int yes = 1;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(19081);
            addr.sin_addr.s_addr = INADDR_ANY;
            if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 24) != 0) {
                close(fd);
                // 若已有另一正常实例占住 19081 端口，自我安静退出杜绝双实例蓝边重影！
                if (gPidFilePath.length > 0) {
                    NSString *curPid = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
                    int ownerPid = [curPid intValue];
                    if (ownerPid > 1 && ownerPid != getpid() && kill(ownerPid, 0) == 0) {
                        exit(0);
                    }
                }
                sleep(2);
                continue;
            }
            while (YES) {
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(fd, &rfds);
                struct timeval tv = {3, 0};
                int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
                if (sel < 0) break;
                if (sel == 0) continue;
                int cfd = accept(fd, NULL, NULL);
                if (cfd < 0) break;
                dispatch_async(srvQ, ^{
                    MitaEdgeHandleClient(cfd, weakVC);
                });
            }
            close(fd);
        }
    });
}

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
@property (nonatomic, strong) MitaGlowWindow *window;
@property (nonatomic, strong) MitaEdgeRootViewController *rootVC;
@property (nonatomic, strong) id windowHostingController;
@end

@implementation MitaEdgeAppDelegate

- (unsigned int)registerHostedWindow:(UIWindow *)targetWin {
    if (!targetWin) return 0;
    Class hostCls = objc_getClass("SBSAccessibilityWindowHostingController");
    if (!hostCls) return 0;
    if (!self.windowHostingController) {
        self.windowHostingController = [[hostCls alloc] init];
    }
    unsigned int outCtx = 0;
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    SEL regSel = NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
    if ([targetWin respondsToSelector:ctxSel] && [self.windowHostingController respondsToSelector:regSel]) {
        unsigned int ctxId = ((unsigned int (*)(id, SEL))objc_msgSend)(targetWin, ctxSel);
        double level = targetWin.windowLevel;
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:self.windowHostingController];
            [inv setSelector:regSel];
            [inv setArgument:&ctxId atIndex:2];
            [inv setArgument:&level atIndex:3];
            [inv invoke];
            outCtx = ctxId;
        }
    }
    return outCtx;
}

- (void)unregisterHostedContextID:(unsigned int)ctxId {
    if (ctxId == 0 || !self.windowHostingController) return;
    SEL unregSel = NSSelectorFromString(@"unregisterWindowWithContextID:");
    if ([self.windowHostingController respondsToSelector:unregSel]) {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:I"];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:self.windowHostingController];
            [inv setSelector:unregSel];
            [inv setArgument:&ctxId atIndex:2];
            [inv invoke];
        }
    }
}

- (void)ensureOverlayWindowVisibleAndHosted {
    if (!self.window) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    if (!CGRectEqualToRect(self.window.frame, sb)) {
        self.window.frame = sb;
    }
    self.window.windowLevel = 10000010.0;
    if (!self.rootVC.screenLocked) {
        self.window.hidden = NO;
        self.rootVC.view.hidden = NO;
        if (self.rootVC.takeoverBar) {
            self.rootVC.takeoverBar.hidden = NO;
            self.rootVC.takeoverBar.alpha = 1.0;
            self.rootVC.takeoverBar.pillBox.hidden = NO;
            self.rootVC.takeoverBar.pillBox.alpha = 1.0;
            [self.rootVC.view bringSubviewToFront:self.rootVC.takeoverBar];
        }
    }
    unsigned int gCtx = [self registerHostedWindow:self.window];
    if (gCtx != 0) {
        self.rootVC.hostedContextId = gCtx;
    }
    if (self.rootVC.shieldWindow && self.rootVC.overlayMasterVisible && !self.rootVC.screenLocked) {
        self.rootVC.shieldWindow.windowLevel = 10000012.0;
        unsigned int sCtx = [self registerHostedWindow:self.rootVC.shieldWindow];
        if (sCtx != 0) {
            self.rootVC.shieldHostedContextId = sCtx;
        }
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    CGRect sb = [UIScreen mainScreen].bounds;
    self.rootVC = [[MitaEdgeRootViewController alloc] init];

    __weak typeof(self) weakSelf = self;
    self.rootVC.reassertWindowBlock = ^{
        [weakSelf ensureOverlayWindowVisibleAndHosted];
    };
    self.rootVC.registerHostedWindowBlock = ^unsigned int(UIWindow *win) {
        return weakSelf ? [weakSelf registerHostedWindow:win] : 0;
    };
    self.rootVC.unregisterHostedContextBlock = ^(unsigned int ctxId) {
        [weakSelf unregisterHostedContextID:ctxId];
    };

    // v5.0.0：启动仅创建永久透传的 MitaGlowWindow (_ignoresHitTest = YES)，承载常驻「我来控制 | 交回 AI」胶囊；
    // MitaShieldWindow 默认为 nil（绝不在 HumanControl 下创建 CAContext），确保真机手指 100% 物理自由触摸！
    self.window = [[MitaGlowWindow alloc] initWithFrame:sb];
    self.window.backgroundColor = [UIColor clearColor];
    self.window.opaque = NO;
    self.window.userInteractionEnabled = NO;
    self.window.rootViewController = self.rootVC;
    self.window.windowLevel = 10000010.0;
    self.window.hidden = NO;
    [self.window makeKeyAndVisible];

    // v5.6.0：对 MitaGlowWindow 应用 iOS 原生防截屏硬件屏蔽标志 (UITextField secure canvas / CALayer disableUpdateMask)，
    // 使手机真机显示屏 100% 清晰可见，同时尽量在硬件层直接对系统截图/录屏/Remote4 隐藏悬浮框与鼠标！
    @try {
        SEL maskSel = NSSelectorFromString(@"setDisableUpdateMask:");
        if ([self.window.layer respondsToSelector:maskSel]) {
            // bit 4 (0x10 = kCALayerDisableUpdateCapture): 仅屏蔽截屏/录屏抓取，真机物理显示屏正常渲染可见！
            ((void (*)(id, SEL, unsigned int))objc_msgSend)(self.window.layer, maskSel, 0x10);
        }
    } @catch (NSException *ex) {}

    [self ensureOverlayWindowVisibleAndHosted];
    [self.rootVC syncShieldWindowGeometryAnimated:NO];

    static int sbBootToken = 0;
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &sbBootToken, dispatch_get_main_queue(), ^(int token) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf ensureOverlayWindowVisibleAndHosted];
        });
    });

    [self.rootVC writeDiagnosticsSnapshot];
    MitaStartEdgeDaemonHttpServer(self.rootVC);
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

        if (strcmp(mode, "-push_media") == 0 && argc >= 4 && argv[2] != NULL && argv[3] != NULL) {
            NSString *mediaPath = [NSString stringWithUTF8String:argv[2]];
            NSString *resPath = [NSString stringWithUTF8String:argv[3]];
            NSDictionary *res = MitaSaveMediaFileToPhotosSync(mediaPath);
            NSData *jd = [NSJSONSerialization dataWithJSONObject:(res ?: @{@"ok": @(NO), @"error": @"empty_res"}) options:0 error:nil];
            if (jd) {
                [jd writeToFile:resPath atomically:YES];
                chmod([resPath UTF8String], 0666);
            }
            return [res[@"ok"] boolValue] ? 0 : 1;
        }

        // v5.6.0 彻底根治真机双鼠标重影：通过 sysctl 扫描全系统进程表，清除所有同名 MitaEdgeOverlay 旧/孤儿实例（不仅依赖单个 PID 文件）！
        pid_t meSelf = getpid();
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
        size_t procBufSize = 0;
        if (sysctl(mib, 4, NULL, &procBufSize, NULL, 0) == 0 && procBufSize > 0) {
            struct kinfo_proc *procs = (struct kinfo_proc *)malloc(procBufSize);
            if (procs) {
                if (sysctl(mib, 4, procs, &procBufSize, NULL, 0) == 0) {
                    size_t procCount = procBufSize / sizeof(struct kinfo_proc);
                    BOOL killedAny = NO;
                    for (size_t i = 0; i < procCount; i++) {
                        pid_t pp = procs[i].kp_proc.p_pid;
                        if (pp > 1 && pp != meSelf) {
                            const char *comm = procs[i].kp_proc.p_comm;
                            if (comm && strncmp(comm, "MitaEdgeOverlay", 15) == 0) {
                                kill(pp, SIGKILL);
                                killedAny = YES;
                            }
                        }
                    }
                    if (killedAny) {
                        usleep(120000);
                    }
                }
                free(procs);
            }
        }
        // 同步清理 PID 文件记录的旧进程
        NSString *prevPidStr = [NSString stringWithContentsOfFile:gPidFilePath encoding:NSUTF8StringEncoding error:nil];
        if (prevPidStr.length > 0) {
            pid_t prevPid = (pid_t)[prevPidStr intValue];
            if (prevPid > 1 && prevPid != meSelf && kill(prevPid, 0) == 0) {
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
