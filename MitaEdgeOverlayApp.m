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
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
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

@property (nonatomic, strong) UIView *thinkingBubbleView;
@property (nonatomic, strong) UIView *sparkleHostView;
@property (nonatomic, strong) CAShapeLayer *sparkleShapeLayer;
@property (nonatomic, strong) UILabel *thinkingLabel;
@property (nonatomic, strong) NSArray<UIView *> *thinkingDots;

@property (nonatomic, assign) CGPoint currentPos;
@property (nonatomic, assign) BOOL cursorVisible;
@property (nonatomic, assign) BOOL thinkingActive;
@property (nonatomic, assign) NSTimeInterval lastActivityTs;
@property (nonatomic, copy) NSString *thinkingText;

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
    // 1. 思考中旋转极光星环（环绕光标尖端）
    self.thinkingRingHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
    self.thinkingRingHost.userInteractionEnabled = NO;
    self.thinkingRingHost.alpha = 0.0;

    self.thinkingRingGradient = [CAGradientLayer layer];
    self.thinkingRingGradient.frame = self.thinkingRingHost.bounds;
    if (@available(iOS 12.0, *)) {
        self.thinkingRingGradient.type = kCAGradientLayerConic;
    }
    self.thinkingRingGradient.startPoint = CGPointMake(0.5, 0.5);
    self.thinkingRingGradient.endPoint = CGPointMake(0.5, 0.0);
    self.thinkingRingGradient.colors = @[
        (id)[UIColor colorWithRed:0.13 green:0.83 blue:0.93 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.38 green:0.55 blue:1.00 alpha:0.95].CGColor,
        (id)[UIColor colorWithRed:0.62 green:0.35 blue:0.98 alpha:0.92].CGColor,
        (id)[UIColor colorWithRed:0.93 green:0.30 blue:0.62 alpha:0.75].CGColor,
        (id)[UIColor colorWithRed:0.13 green:0.83 blue:0.93 alpha:0.12].CGColor,
        (id)[UIColor colorWithRed:0.13 green:0.83 blue:0.93 alpha:1.0].CGColor
    ];
    self.thinkingRingMask = [CAShapeLayer layer];
    self.thinkingRingMask.frame = self.thinkingRingHost.bounds;
    self.thinkingRingMask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.thinkingRingHost.bounds, 2.5, 2.5)].CGPath;
    self.thinkingRingMask.fillColor = [UIColor clearColor].CGColor;
    self.thinkingRingMask.strokeColor = [UIColor whiteColor].CGColor;
    self.thinkingRingMask.lineWidth = 2.4;
    self.thinkingRingGradient.mask = self.thinkingRingMask;
    [self.thinkingRingHost.layer addSublayer:self.thinkingRingGradient];
    [self addSubview:self.thinkingRingHost];

    // 2. 思考中高级磨砂微泡（矢量四芒星 + 动态文字 + 三颗错相位跳动极光点）
    self.thinkingBubbleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 126, 30)];
    self.thinkingBubbleView.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.15 alpha:0.90];
    self.thinkingBubbleView.layer.cornerRadius = 15.0;
    self.thinkingBubbleView.layer.borderWidth = 0.85;
    self.thinkingBubbleView.layer.borderColor = [UIColor colorWithRed:0.35 green:0.82 blue:1.00 alpha:0.65].CGColor;
    self.thinkingBubbleView.layer.shadowColor = [UIColor colorWithRed:0.18 green:0.65 blue:1.00 alpha:1.0].CGColor;
    self.thinkingBubbleView.layer.shadowOpacity = 0.36;
    self.thinkingBubbleView.layer.shadowRadius = 8.0;
    self.thinkingBubbleView.layer.shadowOffset = CGSizeMake(0, 2);
    self.thinkingBubbleView.userInteractionEnabled = NO;
    self.thinkingBubbleView.alpha = 0.0;

    // 原生矢量四芒星（Apple Intelligence Sparkle 路径，绝不缺字！）
    self.sparkleHostView = [[UIView alloc] initWithFrame:CGRectMake(10, 8, 14, 14)];
    self.sparkleShapeLayer = [CAShapeLayer layer];
    UIBezierPath *sp = [UIBezierPath bezierPath];
    [sp moveToPoint:CGPointMake(7, 0.5)];
    [sp addQuadCurveToPoint:CGPointMake(13.5, 7) controlPoint:CGPointMake(8.1, 5.9)];
    [sp addQuadCurveToPoint:CGPointMake(7, 13.5) controlPoint:CGPointMake(8.1, 8.1)];
    [sp addQuadCurveToPoint:CGPointMake(0.5, 7) controlPoint:CGPointMake(5.9, 8.1)];
    [sp addQuadCurveToPoint:CGPointMake(7, 0.5) controlPoint:CGPointMake(5.9, 5.9)];
    [sp closePath];
    self.sparkleShapeLayer.path = sp.CGPath;
    self.sparkleShapeLayer.fillColor = [UIColor colorWithRed:0.32 green:0.88 blue:1.00 alpha:1.0].CGColor;
    [self.sparkleHostView.layer addSublayer:self.sparkleShapeLayer];
    [self.thinkingBubbleView addSubview:self.sparkleHostView];

    self.thinkingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.thinkingLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    self.thinkingLabel.textColor = [UIColor colorWithRed:0.95 green:0.98 blue:1.00 alpha:0.98];
    self.thinkingLabel.text = @"思考中";
    [self.thinkingBubbleView addSubview:self.thinkingLabel];

    NSMutableArray<UIView *> *dots = [NSMutableArray arrayWithCapacity:3];
    NSArray<UIColor *> *dotCols = @[
        [UIColor colorWithRed:0.18 green:0.86 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.52 green:0.56 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.94 green:0.38 blue:0.70 alpha:1.0]
    ];
    for (int i = 0; i < 3; i++) {
        UIView *dv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4.5, 4.5)];
        dv.layer.cornerRadius = 2.25;
        dv.backgroundColor = dotCols[i];
        [self.thinkingBubbleView addSubview:dv];
        [dots addObject:dv];
    }
    self.thinkingDots = dots;
    [self addSubview:self.thinkingBubbleView];

    // 3. 精致苹果风流线型虚拟鼠标指针（锚点固定在左上尖端 (0, 0)）
    self.pointerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 44)];
    self.pointerContainer.layer.anchorPoint = CGPointMake(0.0, 0.0);
    self.pointerContainer.userInteractionEnabled = NO;
    self.pointerContainer.alpha = 0.0;

    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(0.0, 0.0)];
    [arrow addLineToPoint:CGPointMake(0.0, 22.5)];
    [arrow addLineToPoint:CGPointMake(5.8, 17.5)];
    [arrow addLineToPoint:CGPointMake(10.6, 26.2)];
    [arrow addLineToPoint:CGPointMake(14.0, 24.4)];
    [arrow addLineToPoint:CGPointMake(9.2, 15.6)];
    [arrow addLineToPoint:CGPointMake(17.2, 14.8)];
    [arrow closePath];

    self.pointerShadowLayer = [CAShapeLayer layer];
    self.pointerShadowLayer.path = arrow.CGPath;
    self.pointerShadowLayer.fillColor = [UIColor colorWithRed:0.06 green:0.10 blue:0.20 alpha:0.85].CGColor;
    self.pointerShadowLayer.shadowColor = [UIColor colorWithRed:0.16 green:0.76 blue:1.00 alpha:1.0].CGColor;
    self.pointerShadowLayer.shadowOpacity = 0.72;
    self.pointerShadowLayer.shadowRadius = 6.5;
    self.pointerShadowLayer.shadowOffset = CGSizeMake(0.5, 1.5);
    [self.pointerContainer.layer addSublayer:self.pointerShadowLayer];

    self.pointerFillLayer = [CAShapeLayer layer];
    self.pointerFillLayer.path = arrow.CGPath;
    self.pointerFillLayer.fillColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.17 alpha:0.98].CGColor;
    self.pointerFillLayer.strokeColor = [UIColor whiteColor].CGColor;
    self.pointerFillLayer.lineWidth = 1.85;
    self.pointerFillLayer.lineJoin = kCALineJoinRound;
    [self.pointerContainer.layer addSublayer:self.pointerFillLayer];

    // 右下迷你米塔徽标（非思考态显示，极克制不挡视线）
    self.tagBadgeView = [[UIView alloc] initWithFrame:CGRectMake(14.5, 21.5, 32, 15)];
    self.tagBadgeView.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.17 alpha:0.88];
    self.tagBadgeView.layer.cornerRadius = 7.5;
    self.tagBadgeView.layer.borderWidth = 0.7;
    self.tagBadgeView.layer.borderColor = [UIColor colorWithRed:0.24 green:0.84 blue:1.00 alpha:0.68].CGColor;
    self.tagBadgeLabel = [[UILabel alloc] initWithFrame:self.tagBadgeView.bounds];
    self.tagBadgeLabel.text = @"米塔";
    self.tagBadgeLabel.font = [UIFont systemFontOfSize:8.8 weight:UIFontWeightBold];
    self.tagBadgeLabel.textColor = [UIColor colorWithRed:0.88 green:0.97 blue:1.00 alpha:1.0];
    self.tagBadgeLabel.textAlignment = NSTextAlignmentCenter;
    [self.tagBadgeView addSubview:self.tagBadgeLabel];
    [self.pointerContainer addSubview:self.tagBadgeView];

    [self addSubview:self.pointerContainer];
}

- (void)layoutThinkingBubbleAroundPoint:(CGPoint)pt {
    NSString *t = (self.thinkingText.length > 0) ? self.thinkingText : @"思考中";
    self.thinkingLabel.text = t;
    [self.thinkingLabel sizeToFit];
    CGFloat textW = ceil(self.thinkingLabel.bounds.size.width);
    CGFloat bw = 28.0 + textW + 30.0;
    CGFloat bh = 30.0;
    CGFloat W = MAX(100.0, self.bounds.size.width);
    CGFloat H = MAX(100.0, self.bounds.size.height);

    // 靠近右边界自动翻到光标左侧，绝不溢出屏幕！
    CGFloat bx = (pt.x + 18.0 + bw > W - 12.0) ? MAX(12.0, pt.x - bw - 14.0) : (pt.x + 18.0);
    CGFloat by = MAX(32.0, MIN(H - 120.0, pt.y - bh * 0.5));
    self.thinkingBubbleView.frame = CGRectMake(bx, by, bw, bh);
    self.sparkleHostView.frame = CGRectMake(10.0, (bh - 14.0) * 0.5, 14.0, 14.0);
    self.thinkingLabel.frame = CGRectMake(28.0, 0, textW + 2.0, bh);
    CGFloat dotStartX = 28.0 + textW + 6.0;
    for (int i = 0; i < (int)self.thinkingDots.count; i++) {
        UIView *dv = self.thinkingDots[i];
        dv.frame = CGRectMake(dotStartX + i * 7.5, (bh - 4.5) * 0.5, 4.5, 4.5);
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
        [self.thinkingRingGradient addAnimation:spin forKey:@"mitaRingSpin"];
    }
    if (![self.sparkleHostView.layer animationForKey:@"mitaSparkleSpin"]) {
        CABasicAnimation *spRot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spRot.fromValue = @(0.0);
        spRot.toValue = @(M_PI);
        spRot.duration = 2.4;
        spRot.repeatCount = HUGE_VALF;
        spRot.removedOnCompletion = NO;
        [self.sparkleHostView.layer addAnimation:spRot forKey:@"mitaSparkleSpin"];

        CABasicAnimation *spScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        spScale.fromValue = @(0.82);
        spScale.toValue = @(1.12);
        spScale.duration = 0.85;
        spScale.autoreverses = YES;
        spScale.repeatCount = HUGE_VALF;
        spScale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        spScale.removedOnCompletion = NO;
        [self.sparkleHostView.layer addAnimation:spScale forKey:@"mitaSparkleScale"];
    }
    for (int i = 0; i < (int)self.thinkingDots.count; i++) {
        UIView *dv = self.thinkingDots[i];
        if ([dv.layer animationForKey:@"mitaDotBounce"]) continue;
        CAKeyframeAnimation *bounce = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
        bounce.values = @[ @(0.0), @(-3.8), @(0.0), @(0.0) ];
        bounce.keyTimes = @[ @(0.0), @(0.28), @(0.56), @(1.0) ];
        bounce.duration = 1.05;
        bounce.beginTime = CACurrentMediaTime() + i * 0.16;
        bounce.repeatCount = HUGE_VALF;
        bounce.removedOnCompletion = NO;
        [dv.layer addAnimation:bounce forKey:@"mitaDotBounce"];

        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.42);
        op.toValue = @(1.0);
        op.duration = 0.525;
        op.beginTime = CACurrentMediaTime() + i * 0.16;
        op.autoreverses = YES;
        op.repeatCount = HUGE_VALF;
        op.removedOnCompletion = NO;
        [dv.layer addAnimation:op forKey:@"mitaDotOp"];
    }
}

- (void)stopThinkingAnimations {
    [self.thinkingRingGradient removeAllAnimations];
    [self.sparkleHostView.layer removeAllAnimations];
    for (UIView *dv in self.thinkingDots) {
        [dv.layer removeAllAnimations];
    }
}

- (void)showThinking:(BOOL)active text:(NSString *)text atPoint:(CGPoint)pt hasPoint:(BOOL)hasPt {
    self.thinkingActive = active;
    self.lastActivityTs = [[NSDate date] timeIntervalSince1970];
    if (text.length > 0) self.thinkingText = text;
    if (active) {
        CGPoint target = hasPt ? pt : (self.cursorVisible ? self.currentPos : CGPointMake(self.bounds.size.width * 0.44, self.bounds.size.height * 0.46));
        if (!self.cursorVisible) {
            self.pointerContainer.layer.position = target;
            self.currentPos = target;
            self.cursorVisible = YES;
        }
        [self startThinkingAnimations];
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.84 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.pointerContainer.alpha = 1.0;
            self.pointerContainer.layer.position = target;
            self.tagBadgeView.alpha = 0.0;
            self.thinkingRingHost.alpha = 1.0;
            self.thinkingBubbleView.alpha = 1.0;
            [self layoutThinkingBubbleAroundPoint:target];
        } completion:nil];
        self.currentPos = target;
    } else {
        [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.thinkingRingHost.alpha = 0.0;
            self.thinkingBubbleView.alpha = 0.0;
            self.tagBadgeView.alpha = self.cursorVisible ? 1.0 : 0.0;
        } completion:^(BOOL finished) {
            if (!self.thinkingActive) {
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
    [self stopThinkingAnimations];
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
    if (!self.cursorVisible || self.thinkingActive) return;
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
    self.hintToastLabel.layer.cornerRadius = 12.0;
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

    self.dotView = [[UIView alloc] initWithFrame:CGRectMake(12, 14, 8, 8)];
    self.dotView.layer.cornerRadius = 4.0;
    self.dotView.backgroundColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.58 alpha:1.0];
    self.dotView.userInteractionEnabled = NO;
    [self.pillBox addSubview:self.dotView];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @(0.45);
    pulse.toValue = @(1.0);
    pulse.duration = 1.05;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.removedOnCompletion = NO;
    [self.dotView.layer addAnimation:pulse forKey:@"mitaTakeDotPulse"];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont systemFontOfSize:12.4 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor colorWithRed:0.92 green:1.00 blue:0.96 alpha:0.98];
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
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 20.0 || H < 20.0) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    BOOL isModern = (sb.size.height / MAX(1.0, sb.size.width)) > 1.95;
    CGFloat bottomSafe = isModern ? 34.0 : 12.0;

    self.hidden = NO;
    self.alpha = 1.0;
    self.pillBox.hidden = NO;
    self.pillBox.alpha = 1.0;

    // v5.1.0：AiLocked 与 HumanControl 统一为完全一致的尺寸与坐标 196x36，固定停靠右下安全区（0px 位移原地平滑切换）
    CGFloat pw = 196.0, ph = 36.0;
    self.pillBox.frame = CGRectMake(W - pw - 12.0, H - bottomSafe - ph - 58.0, pw, ph);
    self.pillBox.layer.cornerRadius = ph * 0.5;

    if (self.controlMode == MitaControlModeAiLocked) {
        self.pillBox.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.14 alpha:0.96];
        self.pillBox.layer.borderColor = [UIColor colorWithRed:0.28 green:0.80 blue:1.00 alpha:0.78].CGColor;

        self.dotView.frame = CGRectMake(12.0, (ph - 8.0) * 0.5, 8.0, 8.0);
        self.dotView.backgroundColor = [UIColor colorWithRed:0.16 green:0.86 blue:0.98 alpha:1.0];

        self.statusLabel.text = @"AI 控制中";
        self.statusLabel.font = [UIFont systemFontOfSize:12.4 weight:UIFontWeightSemibold];
        self.statusLabel.textColor = [UIColor colorWithRed:0.93 green:0.97 blue:1.00 alpha:0.98];
        self.statusLabel.frame = CGRectMake(25.0, 0, 82.0, ph);

        self.actionButton.frame = CGRectMake(pw - 82.0, (ph - 26.0) * 0.5, 76.0, 26.0);
        self.actionButton.layer.cornerRadius = 13.0;
        self.actionButton.backgroundColor = [UIColor whiteColor];
        [self.actionButton setTitle:@"我来接管" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor colorWithRed:0.06 green:0.09 blue:0.17 alpha:1.0] forState:UIControlStateNormal];
        self.actionButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    } else {
        self.pillBox.backgroundColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.15 alpha:0.95];
        self.pillBox.layer.borderColor = [UIColor colorWithRed:0.18 green:0.86 blue:0.58 alpha:0.85].CGColor;

        self.dotView.frame = CGRectMake(12.0, (ph - 8.0) * 0.5, 8.0, 8.0);
        self.dotView.backgroundColor = [UIColor colorWithRed:0.20 green:0.90 blue:0.58 alpha:1.0];

        self.statusLabel.text = @"我来控制";
        self.statusLabel.font = [UIFont systemFontOfSize:12.4 weight:UIFontWeightSemibold];
        self.statusLabel.textColor = [UIColor colorWithRed:0.92 green:1.00 blue:0.96 alpha:0.98];
        self.statusLabel.frame = CGRectMake(25.0, 0, 82.0, ph);

        self.actionButton.frame = CGRectMake(pw - 78.0, (ph - 26.0) * 0.5, 72.0, 26.0);
        self.actionButton.layer.cornerRadius = 13.0;
        self.actionButton.backgroundColor = [UIColor colorWithRed:0.06 green:0.74 blue:0.52 alpha:1.0];
        [self.actionButton setTitle:@"交回 AI" forState:UIControlStateNormal];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.actionButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    }

    CGFloat hw = 252.0, hh = 26.0;
    CGFloat hx = MIN(W - hw - 12.0, MAX(12.0, CGRectGetMidX(self.pillBox.frame) - hw * 0.5));
    self.hintToastLabel.frame = CGRectMake(hx, CGRectGetMinY(self.pillBox.frame) - hh - 10.0, hw, hh);
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

- (CGRect)pillHitRectInView:(UIView *)targetView {
    if (CGRectIsEmpty(self.pillBox.frame)) [self layoutForCurrentMode];
    CGRect r = targetView ? [self convertRect:self.pillBox.frame toView:targetView] : self.pillBox.frame;
    return CGRectInset(r, -10.0, -10.0);
}

- (CGRect)actionButtonHitRectInView:(UIView *)targetView {
    if (CGRectIsEmpty(self.pillBox.frame)) [self layoutForCurrentMode];
    CGRect r = targetView ? [self.pillBox convertRect:self.actionButton.frame toView:targetView] : self.actionButton.frame;
    return CGRectInset(r, -2.0, -4.0);
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

// 仅在布局初始化时执行 1 次（<1.5ms）：基于圆角矩形 SDF 距离场生成丝滑指数级朦胧雾化边缘遮罩纹理，运行期 0% CPU！
static CGImageRef MitaCreateSdfEdgeMaskImage(CGSize size, CGFloat cornerRadius, CGFloat maxFeatherPt, BOOL isNarrowRim) CF_RETURNS_RETAINED {
    double W = MAX(20.0, (double)size.width);
    double H = MAX(20.0, (double)size.height);
    double scale = isNarrowRim ? 1.0 : 0.5;
    size_t bw = (size_t)MAX(64, (int)ceil(W * scale));
    size_t bh = (size_t)MAX(64, (int)ceil(H * scale));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    uint8_t *buf = (uint8_t *)calloc(bw * bh * 4, 1);
    if (!buf) {
        CGColorSpaceRelease(cs);
        return NULL;
    }

    double r = MIN((double)cornerRadius, MIN(W, H) * 0.25);
    double hx = W * 0.5 - r;
    double hy = H * 0.5 - r;
    double feather = MAX(1.5, (double)maxFeatherPt);

    for (size_t iy = 0; iy < bh; iy++) {
        double py = ((double)iy + 0.5) / (double)bh * H;
        double qy = fabs(py - H * 0.5) - hy;
        double oy = fmax(qy, 0.0);
        size_t rowOff = iy * bw * 4;
        for (size_t ix = 0; ix < bw; ix++) {
            double px = ((double)ix + 0.5) / (double)bw * W;
            double qx = fabs(px - W * 0.5) - hx;
            double ox = fmax(qx, 0.0);
            double outside = hypot(ox, oy) + fmin(fmax(qx, qy), 0.0) - r;
            double d = -outside;
            if (d < -0.75 || d >= feather) continue;

            double a = 0.0;
            if (d < 0.0) {
                a = 1.0 + (d / 0.75);
            } else if (isNarrowRim) {
                double t = d / feather;
                a = pow(MAX(0.0, 1.0 - t), 1.75);
            } else {
                double t = d / feather;
                // 贴边高饱和能量带 + 向内 36pt 高斯柔雾星云晕染（屏幕中心 d >= 36pt 严格 0.0 全透明）
                double core = exp(-15.0 * t * t) * 0.36;
                double mist = exp(-2.95 * t * t) * (1.0 - t) * 0.88;
                a = MIN(1.0, core + mist);
            }
            if (a <= 0.002) continue;
            uint8_t v = (uint8_t)MIN(255, MAX(0, (int)llround(a * 255.0)));
            size_t p = rowOff + ix * 4;
            buf[p + 0] = v;
            buf[p + 1] = v;
            buf[p + 2] = v;
            buf[p + 3] = v;
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
    [self.statusPillView addSubview:self.statusDotView];

    self.statusPillLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusPillLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.8 weight:UIFontWeightSemibold];
    self.statusPillLabel.textColor = [UIColor colorWithRed:0.95 green:0.98 blue:1.00 alpha:0.98];
    self.statusPillLabel.textAlignment = NSTextAlignmentLeft;
    [self.statusPillView addSubview:self.statusPillLabel];

    [self addSubview:self.statusPillView];

    CABasicAnimation *dotPulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dotPulse.fromValue = @(0.42);
    dotPulse.toValue = @(1.0);
    dotPulse.duration = 1.2;
    dotPulse.autoreverses = YES;
    dotPulse.repeatCount = HUGE_VALF;
    dotPulse.removedOnCompletion = NO;
    [self.statusDotView.layer addAnimation:dotPulse forKey:@"mitaDotPulse"];

    __weak typeof(self) weakSelf = self;
    self.pillTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.pillTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.15 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(self.pillTimer, ^{
        [weakSelf updateStatusPillText];
    });
    dispatch_resume(self.pillTimer);
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

    // 1. 深邃高饱和未来科技极光主色盘（白底微信与深色界面均浓郁朦胧、层次分明）
    NSArray *mainColors = @[
        (id)[UIColor colorWithRed:0.00 green:0.85 blue:0.99 alpha:0.98].CGColor, // 赛博电光青
        (id)[UIColor colorWithRed:0.11 green:0.38 blue:0.96 alpha:0.95].CGColor, // 深海量子蓝
        (id)[UIColor colorWithRed:0.44 green:0.20 blue:0.96 alpha:0.94].CGColor, // 星云幻影紫
        (id)[UIColor colorWithRed:0.86 green:0.18 blue:0.58 alpha:0.88].CGColor, // 极光霓虹洋红
        (id)[UIColor colorWithRed:0.22 green:0.20 blue:0.78 alpha:0.68].CGColor, // 幽邃靛蓝雾谷
        (id)[UIColor colorWithRed:0.02 green:0.76 blue:0.96 alpha:0.94].CGColor, // 冰川青蓝流峰
        (id)[UIColor colorWithRed:0.52 green:0.24 blue:0.98 alpha:0.92].CGColor, // 紫罗兰星云
        (id)[UIColor colorWithRed:0.06 green:0.56 blue:0.96 alpha:0.72].CGColor, // 科技天蓝柔谷
        (id)[UIColor colorWithRed:0.00 green:0.85 blue:0.99 alpha:0.98].CGColor
    ];
    NSArray *mainLocs = @[ @0.00, @0.13, @0.27, @0.41, @0.54, @0.67, @0.80, @0.91, @1.00 ];

    // 2. 反向穿梭的高能科技双彗星流光束（制造雾环内部的流动能量脉搏）
    NSArray *cometColors = @[
        (id)[UIColor colorWithRed:0.00 green:0.92 blue:1.00 alpha:0.00].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.92 blue:1.00 alpha:0.85].CGColor,
        (id)[UIColor colorWithRed:0.76 green:0.97 blue:1.00 alpha:0.98].CGColor,
        (id)[UIColor colorWithRed:0.48 green:0.28 blue:0.98 alpha:0.82].CGColor,
        (id)[UIColor colorWithRed:0.48 green:0.28 blue:0.98 alpha:0.00].CGColor,
        (id)[UIColor colorWithRed:0.92 green:0.24 blue:0.66 alpha:0.00].CGColor,
        (id)[UIColor colorWithRed:0.92 green:0.24 blue:0.66 alpha:0.82].CGColor,
        (id)[UIColor colorWithRed:0.62 green:0.38 blue:1.00 alpha:0.95].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.84 blue:0.98 alpha:0.78].CGColor,
        (id)[UIColor colorWithRed:0.08 green:0.84 blue:0.98 alpha:0.00].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.92 blue:1.00 alpha:0.00].CGColor
    ];
    NSArray *cometLocs = @[ @0.00, @0.08, @0.15, @0.23, @0.32, @0.52, @0.60, @0.68, @0.76, @0.86, @1.00 ];

    self.waveCompositeLayer = [CALayer layer];
    self.waveCompositeLayer.masksToBounds = YES;

    self.mainConicLayer = [CAGradientLayer layer];
    if (@available(iOS 12.0, *)) {
        self.mainConicLayer.type = kCAGradientLayerConic;
    }
    self.mainConicLayer.startPoint = CGPointMake(0.5, 0.5);
    self.mainConicLayer.endPoint = CGPointMake(0.5, 0.0);
    self.mainConicLayer.colors = mainColors;
    self.mainConicLayer.locations = mainLocs;
    [self.waveCompositeLayer addSublayer:self.mainConicLayer];

    self.cometConicLayer = [CAGradientLayer layer];
    if (@available(iOS 12.0, *)) {
        self.cometConicLayer.type = kCAGradientLayerConic;
    }
    self.cometConicLayer.startPoint = CGPointMake(0.5, 0.5);
    self.cometConicLayer.endPoint = CGPointMake(0.5, 0.0);
    self.cometConicLayer.colors = cometColors;
    self.cometConicLayer.locations = cometLocs;
    self.cometConicLayer.opacity = 0.88f;
    [self.waveCompositeLayer addSublayer:self.cometConicLayer];

    self.mistMaskLayer = [CALayer layer];
    self.waveCompositeLayer.mask = self.mistMaskLayer;
    [self.layer addSublayer:self.waveCompositeLayer];

    // 3. 贴合屏幕物理边缘的 3.4pt 精密科技流光导光芯（内雾外锐，未来感拉满）
    self.rimCompositeLayer = [CALayer layer];
    self.rimCompositeLayer.masksToBounds = YES;
    self.rimConicLayer = [CAGradientLayer layer];
    if (@available(iOS 12.0, *)) {
        self.rimConicLayer.type = kCAGradientLayerConic;
    }
    self.rimConicLayer.startPoint = CGPointMake(0.5, 0.5);
    self.rimConicLayer.endPoint = CGPointMake(0.5, 0.0);
    self.rimConicLayer.colors = @[
        (id)[UIColor colorWithRed:0.00 green:0.94 blue:1.00 alpha:1.00].CGColor,
        (id)[UIColor colorWithRed:0.24 green:0.48 blue:1.00 alpha:0.96].CGColor,
        (id)[UIColor colorWithRed:0.62 green:0.28 blue:1.00 alpha:0.98].CGColor,
        (id)[UIColor colorWithRed:0.94 green:0.26 blue:0.66 alpha:0.94].CGColor,
        (id)[UIColor colorWithRed:0.06 green:0.78 blue:1.00 alpha:0.98].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.94 blue:1.00 alpha:1.00].CGColor
    ];
    [self.rimCompositeLayer addSublayer:self.rimConicLayer];

    self.rimMaskLayer = [CALayer layer];
    self.rimCompositeLayer.mask = self.rimMaskLayer;
    [self.layer addSublayer:self.rimCompositeLayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (b.size.width < 10 || b.size.height < 10) return;
    if (CGSizeEqualToSize(self.lastLayoutSize, b.size)) return;
    self.lastLayoutSize = b.size;
    self.physicalCornerRadius = MitaPhysicalCornerRadiusForBounds(b);

    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    CGFloat diag = ceil(hypot(W, H) * 1.16);
    CGRect conicBounds = CGRectMake(0, 0, diag, diag);
    CGPoint centerPt = CGPointMake(W * 0.5, H * 0.5);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.waveCompositeLayer.frame = b;
    self.mainConicLayer.bounds = conicBounds;
    self.mainConicLayer.position = centerPt;
    self.cometConicLayer.bounds = conicBounds;
    self.cometConicLayer.position = centerPt;
    self.mistMaskLayer.frame = b;

    self.rimCompositeLayer.frame = b;
    self.rimConicLayer.bounds = conicBounds;
    self.rimConicLayer.position = centerPt;
    self.rimMaskLayer.frame = b;

    CGImageRef mistImg = MitaCreateSdfEdgeMaskImage(b.size, self.physicalCornerRadius, 36.0, NO);
    if (mistImg) {
        self.mistMaskLayer.contents = (__bridge id)mistImg;
        CGImageRelease(mistImg);
    }
    CGImageRef rimImg = MitaCreateSdfEdgeMaskImage(b.size, self.physicalCornerRadius, 3.6, YES);
    if (rimImg) {
        self.rimMaskLayer.contents = (__bridge id)rimImg;
        CGImageRelease(rimImg);
    }

    [CATransaction commit];
    [self bringSubviewToFront:self.statusPillView];
    [self updateStatusPillText];
    [self ensureGpuAnimationsRunning];
}

- (void)ensureGpuAnimationsRunning {
    if (self.gpuAnimRunning && [self.mainConicLayer animationForKey:@"mitaRot1"] != nil) return;
    self.gpuAnimRunning = YES;

    CABasicAnimation *rot1 = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot1.fromValue = @(0.0);
    rot1.toValue = @(M_PI * 2.0);
    rot1.duration = 5.4;
    rot1.repeatCount = HUGE_VALF;
    rot1.removedOnCompletion = NO;
    [self.mainConicLayer addAnimation:rot1 forKey:@"mitaRot1"];

    CABasicAnimation *rot2 = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot2.fromValue = @(0.0);
    rot2.toValue = @(-M_PI * 2.0);
    rot2.duration = 3.6;
    rot2.repeatCount = HUGE_VALF;
    rot2.removedOnCompletion = NO;
    [self.cometConicLayer addAnimation:rot2 forKey:@"mitaRot2"];

    CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
    breath.fromValue = @(0.76);
    breath.toValue = @(0.98);
    breath.duration = 2.2;
    breath.autoreverses = YES;
    breath.repeatCount = HUGE_VALF;
    breath.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    breath.removedOnCompletion = NO;
    [self.waveCompositeLayer addAnimation:breath forKey:@"mitaMistBreath"];

    CABasicAnimation *rotRim = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotRim.fromValue = @(0.0);
    rotRim.toValue = @(M_PI * 2.0);
    rotRim.duration = 4.0;
    rotRim.repeatCount = HUGE_VALF;
    rotRim.removedOnCompletion = NO;
    [self.rimConicLayer addAnimation:rotRim forKey:@"mitaRotRim"];
}

- (void)syncGpuOpacityAndMode {
    CGFloat targetOp = MAX(0.0f, MIN(1.0f, self.masterOpacity));
    if (targetOp > 0.005f) {
        [self ensureGpuAnimationsRunning];
    } else if (self.gpuAnimRunning) {
        [self.mainConicLayer removeAllAnimations];
        [self.cometConicLayer removeAllAnimations];
        [self.waveCompositeLayer removeAllAnimations];
        [self.rimConicLayer removeAllAnimations];
        self.gpuAnimRunning = NO;
    }
    BOOL lively = self.activeReplying;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.opacity = (float)targetOp;
    self.cometConicLayer.opacity = lively ? 0.96f : 0.82f;
    [CATransaction commit];
    [self updateStatusPillText];
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
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                              (uint64_t)(0.40 * NSEC_PER_SEC),
                              (uint64_t)(0.08 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(self.pollSource, ^{
        [weakSelf onPollTick];
    });
    dispatch_resume(self.pollSource);

    [self syncShieldWindowGeometryAnimated:NO];
    [self reloadControlStateNow];
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
    if ((now - self.lastTouchHandledTs) < 0.28) {
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
    BOOL needShield = (!self.screenLocked && self.controlMode == MitaControlModeAiLocked && !gateOpen);

    // HumanControl / 锁屏 / AI 瞬时穿窗期：立即彻底销毁 shieldWindow = nil 并注销 ContextID，真机手指 100% 原生自由触控！
    if (!needShield) {
        [self destroyShieldWindowIfNeeded];
        return;
    }

    // 仅在 MitaControlModeAiLocked 下按需创建并注册全屏护盾窗
    BOOL newlyCreated = NO;
    if (!self.shieldWindow) {
        MitaShieldViewController *svc = [[MitaShieldViewController alloc] init];
        MitaShieldWindow *sw = [[MitaShieldWindow alloc] initWithFrame:sb];
        sw.edgeRootVC = self;
        sw.backgroundColor = [UIColor clearColor];
        sw.opaque = NO;
        sw.clipsToBounds = NO;
        sw.userInteractionEnabled = YES;
        sw.rootViewController = svc;
        sw.windowLevel = 10000012.0;

        MitaTouchShieldView *tsv = [[MitaTouchShieldView alloc] initWithFrame:svc.view.bounds];
        tsv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tsv.backgroundColor = [UIColor clearColor];
        tsv.userInteractionEnabled = YES;
        __weak typeof(self) weakSelf = self;
        tsv.onBlockedTouch = ^{
            [weakSelf flashBlockedHintThrottled];
        };
        [svc.view addSubview:tsv];
        self.touchShieldView = tsv;

        sw.hidden = NO;
        self.shieldWindow = sw;
        newlyCreated = YES;
    } else {
        self.shieldWindow.windowLevel = 10000012.0;
        if (!CGRectEqualToRect(self.shieldWindow.frame, sb)) {
            self.shieldWindow.frame = sb;
        }
        UIView *sRoot = self.shieldWindow.rootViewController.view;
        sRoot.hidden = NO;
        sRoot.frame = self.shieldWindow.bounds;
        if (self.touchShieldView) {
            self.touchShieldView.frame = self.shieldWindow.bounds;
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
    if (!self.overlayMasterVisible) {
        if (self.takeoverBar) {
            self.takeoverBar.masterHidden = YES;
            self.takeoverBar.hidden = YES;
            self.takeoverBar.alpha = 0.0;
            self.takeoverBar.pillBox.hidden = YES;
        }
        self.view.hidden = YES;
        [self destroyShieldWindowIfNeeded];
        if ((now - self.lastWindowReassertTs) >= 5.0) {
            self.lastWindowReassertTs = now;
            [self writeDiagnosticsSnapshot];
        }
        [self reloadControlStateNow];
        return;
    }
    [self syncShieldWindowGeometryAnimated:NO];
    [self.cursorView checkAutoFadeIfIdle];

    // 每 5 秒自动校验并重申顶层窗口可见性，锁屏解锁或桌面切换后 100% 自动恢复显示
    if ((now - self.lastWindowReassertTs) >= 5.0) {
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
        // 点击「我来接管」-> 0ms 立即切换为常驻 HumanControl，彻底置 nil 销毁 shieldWindow 释放全屏触摸，并暂停电脑与本机自动控制
        [self.cursorView hideCursorAnimated:YES];
        self.controlMode = MitaControlModeHumanControl;
        self.controlModeString = @"human_control";
        self.aiLockExpireAtTs = 0;
        [self.takeoverBar applyControlMode:MitaControlModeHumanControl animated:YES];
        [self destroyShieldWindowIfNeeded];
        self.waveView.activeControl = NO;
        self.waveView.activeReplying = NO;
        self.waveView.phaseLabel = @"我来控制";
        self.displayLink.paused = NO;
        [self.waveView syncGpuOpacityAndMode];
        [self writeDiagnosticsSnapshot];
        [self notifyPcAndLocalTakeoverMode:MitaControlModeHumanControl];
    } else {
        // 点击「交回 AI」-> 立即切换为 AiLocked，新建并注册全屏 shieldWindow 防误触护盾，并通知电脑恢复/启动 AI 控制
        self.controlMode = MitaControlModeAiLocked;
        self.controlModeString = @"ai_locked";
        self.aiLockExpireAtTs = 0;
        [self.takeoverBar applyControlMode:MitaControlModeAiLocked animated:YES];
        [self syncShieldWindowGeometryAnimated:NO];
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
    if (effectiveMode != MitaControlModeAiLocked) {
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
    CGRect pf = self.takeoverBar ? self.takeoverBar.pillBox.frame : CGRectZero;
    BOOL barVis = (self.overlayMasterVisible && self.takeoverBar && !self.takeoverBar.hidden && !self.takeoverBar.pillBox.hidden && self.takeoverBar.pillBox.alpha >= 0.99);
    NSString *modeOut = (!self.overlayMasterVisible) ? @"off" : (self.controlModeString ?: @"human_control");
    return @{
        @"ok": @(YES),
        @"daemon": @"MitaEdgeOverlay",
        @"version": @"5.1.0",
        @"port": @(19081),
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
    CGRect pf = self.takeoverBar ? self.takeoverBar.pillBox.frame : CGRectZero;
    BOOL barVis = (self.overlayMasterVisible && self.takeoverBar && !self.takeoverBar.hidden && !self.takeoverBar.pillBox.hidden && self.takeoverBar.pillBox.alpha >= 0.99);
    NSString *modeOut = (!self.overlayMasterVisible) ? @"off" : (self.controlModeString ?: @"human_control");
    NSDictionary *diag = @{
        @"pid": @(getpid()),
        @"uid": @(getuid()),
        @"version": @"5.1.0",
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
    if (!vc || vc.screenLocked || self.hidden) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (vc.passthroughUntilTs > now) return NO;
    if (vc.controlMode == MitaControlModeAiLocked) {
        return CGRectContainsPoint(self.bounds, point);
    }
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    MitaEdgeRootViewController *vc = self.edgeRootVC;
    if (!vc || vc.screenLocked || self.hidden) return nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (vc.passthroughUntilTs > now) return nil;
    if (vc.controlMode == MitaControlModeAiLocked) {
        return vc.touchShieldView;
    }
    return nil;
}

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        MitaEdgeRootViewController *vc = self.edgeRootVC;
        if (vc && !vc.screenLocked && !self.hidden && vc.controlMode == MitaControlModeAiLocked) {
            for (UITouch *t in [event allTouches]) {
                if (t.phase == UITouchPhaseBegan) {
                    CGPoint ptInRoot = [t locationInView:vc.view];
                    [vc handleOverlayTouchDownAtPoint:ptInRoot];
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

static void MitaEdgeHandleClient(int fd, MitaEdgeRootViewController * __weak weakVC) {
    struct timeval tv = {4, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
    int noSig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, sizeof(noSig));
#endif
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
    NSInteger cLen = 0;
    while (buf.length < 131072) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
        if (hdrEnd.location == NSNotFound) {
            hdrEnd = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
            if (hdrEnd.location != NSNotFound) {
                NSString *hs = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
                for (NSString *ln in [hs componentsSeparatedByString:@"\r\n"]) {
                    if ([[ln lowercaseString] hasPrefix:@"content-length:"]) {
                        cLen = [[[ln substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];
                    }
                }
            }
        }
        if (hdrEnd.location != NSNotFound && buf.length >= hdrEnd.location + 4 + (NSUInteger)MAX(0, cLen)) break;
    }
    if (hdrEnd.location == NSNotFound) { close(fd); return; }
    NSString *hs = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding] ?: @"";
    NSArray *parts = [[[hs componentsSeparatedByString:@"\r\n"] firstObject] componentsSeparatedByString:@" "];
    NSString *path = (parts.count > 1) ? [[parts[1] componentsSeparatedByString:@"?"] firstObject] : @"/";
    NSUInteger avail = (buf.length > hdrEnd.location + 4) ? (buf.length - hdrEnd.location - 4) : 0;
    NSUInteger take = (cLen > 0 && (NSUInteger)cLen < avail) ? (NSUInteger)cLen : avail;
    NSData *bodyData = (take > 0) ? [buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, take)] : [NSData data];

    if ([path isEqualToString:@"/ping"] || [path isEqualToString:@"/status"]) {
        __block NSDictionary *stOut = @{@"ok": @(YES), @"daemon": @"MitaEdgeOverlay", @"version": @"5.1.0", @"port": @(19081)};
        MitaEdgeRootViewController *strongVC = weakVC;
        if (strongVC) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                stOut = [strongVC liveOverlayStatusDict];
            });
        }
        MitaEdgeSendHttp(fd, 200, stOut);
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
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_cursor_tap", @"x": @(rx), @"y": @(ry), @"version": @"5.1.0"});
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
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_cursor_swipe", @"version": @"5.1.0"});
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
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_thinking", @"active": @(active), @"version": @"5.1.0"});
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
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_control_mode", @"control_mode": @"off", @"version": @"5.1.0"});
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
                    if (st[@"edge_enabled"] == nil || [st[@"edge_enabled"] boolValue]) {
                        st[@"edge_enabled"] = @(YES);
                        st[@"remote_enabled"] = @(YES);
                        st[@"updated_at"] = @([[NSDate date] timeIntervalSince1970]);
                        NSData *jd = [NSJSONSerialization dataWithJSONObject:st options:0 error:nil];
                        if (jd) {
                            [jd writeToFile:gStateFilePath atomically:YES];
                            chmod([gStateFilePath UTF8String], 0666);
                        }
                    }
                }
                MitaEdgeRootViewController *strongVC = weakVC;
                if (strongVC) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [strongVC applyControlModeFromExternal:mode ttlSec:ttlSec pcUrl:pcUrl];
                    });
                }
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_control_mode", @"control_mode": MitaControlModeName(mode), @"version": @"5.1.0"});
            }
        } else if ([actType isEqualToString:@"passthrough"]) {
            double pMs = dict[@"ms"] ? [dict[@"ms"] doubleValue] : (dict[@"passthrough_ms"] ? [dict[@"passthrough_ms"] doubleValue] : 600.0);
            MitaEdgeRootViewController *strongVC = weakVC;
            if (strongVC) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [strongVC openPassthroughGateMs:pMs];
                });
            }
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_passthrough", @"ms": @(pMs), @"version": @"5.1.0"});
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
            MitaEdgeSendHttp(fd, 200, @{@"ok": @(opened), @"channel": @"edge_19081_lsworkspace", @"bundle_id": bid ?: @"", @"steps": @[@{@"ok": @(opened)}], @"version": @"5.1.0"});
        } else {
            NSString *txt = MitaEdgeExtractCopyText(dict);
            if (txt.length > 0) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [UIPasteboard generalPasteboard].string = txt;
                });
                MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081", @"len": @(txt.length), @"version": @"5.1.0"});
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
        MitaEdgeSendHttp(fd, 200, @{@"ok": @(YES), @"channel": @"edge_19081_pulse", @"version": @"5.1.0"});
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
#ifdef SO_REUSEPORT
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_port = htons(19081);
            addr.sin_addr.s_addr = INADDR_ANY;
            if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 24) != 0) {
                close(fd);
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
    if (self.rootVC.shieldWindow && self.rootVC.controlMode == MitaControlModeAiLocked && !self.rootVC.screenLocked) {
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
