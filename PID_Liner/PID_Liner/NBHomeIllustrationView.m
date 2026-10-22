//
//  NBHomeIllustrationView.m
//  PID_Liner
//
//  场景实现说明:所有几何在设计坐标系(入口卡 130×74 / 摔机 40×34)里定义,
//  layoutSubviews 时按 bounds 等比缩放居中——卡片宽度跨机型变化不失真。
//  描线动画:CABasicAnimation strokeEnd(模型值建层即置 1,动画结束自然停在终态)。
//

#import "NBHomeIllustrationView.h"
#import "NBTheme.h"

/// 插图内部专用辅色(只在这里出现,不进全局令牌)
static UIColor *NBIC(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}
static UIColor *NBIMint(void)      { return NBIC(0x5EEAD4); }  // BBL 标签/LED 荧光绿
static UIColor *NBICBlackbox(void) { return NBIC(0x1B2233); }  // 匣体深藏青
static UIColor *NBICMidTeal(void)  { return NBIC(0x5FC3A8); }  // 中间轮曲线
static UIColor *NBICLightCoral(void) { return NBIC(0xF09390); } // 断落臂浅珊瑚
static UIColor *NBICCrack(void)    { return NBIC(0xF2BCBA); }  // 地面裂纹
static UIColor *NBICBaseline(void) { return NBIC(0xCDEDE1); }  // 渐紧曲线基线

@interface NBHomeIllustrationView ()
@property (nonatomic, assign) NBHomeScene scene;
@property (nonatomic, strong) NSMutableArray<CALayer *> *strokeLayers;  // 参与描线动画
@property (nonatomic, strong) NSMutableArray<CALayer *> *fillLayers;    // 填充件(淡入)
@property (nonatomic, strong) NSMutableArray<UILabel *> *fadeLabels;    // 文字标注(延迟淡入)
@property (nonatomic, assign) CGSize laidSize;                          // 已建层时的 bounds(防重复重建)
@property (nonatomic, assign) BOOL played;
@end

@implementation NBHomeIllustrationView

- (instancetype)initWithFrame:(CGRect)frame scene:(NBHomeScene)scene {
    self = [super initWithFrame:frame];
    if (self) {
        _scene = scene;
        _strokeLayers = [NSMutableArray array];
        _fillLayers = [NSMutableArray array];
        _fadeLabels = [NSMutableArray array];
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;  // 整卡点击在手势层,插图不抢
        if (scene != NBHomeSceneCrashMini) {
            // 色晕吃掉卡片顶角;圆角裁在自己身上,不裁卡片(卡片要投影)
            self.layer.cornerRadius = 16;
            self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
            self.layer.masksToBounds = YES;
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize b = self.bounds.size;
    if (b.width <= 0 || b.height <= 0) return;
    if (CGSizeEqualToSize(b, _laidSize)) return;
    _laidSize = b;
    [self rebuild];
}

#pragma mark - 场景构建

- (void)rebuild {
    for (CALayer *l in self.layer.sublayers.copy) [l removeFromSuperlayer];
    for (UILabel *l in _fadeLabels.copy) [l removeFromSuperview];
    [_strokeLayers removeAllObjects];
    [_fillLayers removeAllObjects];
    [_fadeLabels removeAllObjects];

    CGRect b = self.bounds;
    BOOL isCrash = (_scene == NBHomeSceneCrashMini);
    CGSize design = isCrash ? CGSizeMake(40, 34) : CGSizeMake(130, 74);
    CGFloat scale = MIN(b.size.width / design.width, b.size.height / design.height);
    CGPoint origin = CGPointMake((b.size.width - design.width * scale) / 2.0,
                                 (b.size.height - design.height * scale) / 2.0);
    __block CGPoint (^pt)(CGFloat, CGFloat) = ^CGPoint(CGFloat x, CGFloat y) {
        return CGPointMake(origin.x + x * scale, origin.y + y * scale);
    };

    // 色晕渐变底(摔机小图无渐变,底色由容器 ico 给)
    if (!isCrash) {
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = b;
        NSArray *colors = (_scene == NBHomeSceneIndependent)
            ? @[(__bridge id)NBTheme.accentBlueTint.CGColor, (__bridge id)NBIC(0xF7F9FF).CGColor]
            : @[(__bridge id)NBTheme.accentGreenTint.CGColor, (__bridge id)NBIC(0xF4FBF8).CGColor];
        g.colors = colors;
        g.startPoint = CGPointMake(0, 0);
        g.endPoint = CGPointMake(0, 1);
        [self.layer insertSublayer:g atIndex:0];
    }

    switch (_scene) {
        case NBHomeSceneIndependent: [self buildIndependent:pt scale:scale]; break;
        case NBHomeSceneIteration:   [self buildIteration:pt scale:scale];   break;
        case NBHomeSceneCrashMini:   [self buildCrashMini:pt scale:scale];   break;
    }
}

/// 独立分析:黑匣子匣体(BBL+LED) → 读出射线 → 曲线卡(目标线+超调曲线+8.9%)
- (void)buildIndependent:(CGPoint (^)(CGFloat, CGFloat))pt scale:(CGFloat)scale {
    // 黑匣子匣体
    [self fillLayerWithPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(pt(8, 13).x, pt(8, 13).y, 34 * scale, 48 * scale)
                                                                     cornerRadius:7 * scale]
                      color:NBICBlackbox() stroke:nil strokeWidth:0];
    // BBL 标签牌
    [self strokeLayerWithPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(pt(13, 20).x, pt(13, 20).y, 24 * scale, 11 * scale)
                                                                        cornerRadius:3 * scale]
                        color:NBIMint() width:1.1 * scale dash:nil];
    [self fadeLabel:@"BBL"
               font:[UIFont monospacedSystemFontOfSize:7.5 * scale weight:UIFontWeightMedium]
              color:NBIMint() atFrame:CGRectMake(pt(16.5, 21.5).x, pt(16.5, 21.5).y, 20 * scale, 9 * scale)];
    // LED
    [self fillLayerWithPath:[UIBezierPath bezierPathWithArcCenter:pt(35, 53) radius:2 * scale
                                                        startAngle:0 endAngle:M_PI * 2 clockwise:YES]
                      color:NBIMint() stroke:nil strokeWidth:0];
    // 读出射线(匣体 → 曲线卡)
    NSArray *rays = @[
        @[[NSValue valueWithCGPoint:pt(47, 25)], [NSValue valueWithCGPoint:pt(56, 20)]],
        @[[NSValue valueWithCGPoint:pt(49, 37)], [NSValue valueWithCGPoint:pt(60, 37)]],
        @[[NSValue valueWithCGPoint:pt(47, 49)], [NSValue valueWithCGPoint:pt(56, 54)]],
    ];
    for (NSArray *r in rays) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:[r.firstObject CGPointValue]];
        [p addLineToPoint:[r.lastObject CGPointValue]];
        [self strokeLayerWithPath:p
                            color:[NBTheme.accentBlue colorWithAlphaComponent:0.7]
                            width:1.5 * scale dash:nil];
    }
    // 曲线卡(白底 + 描边,内含目标线与响应曲线)
    [self fillLayerWithPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(pt(63, 17).x, pt(63, 17).y, 60 * scale, 40 * scale)
                                                                     cornerRadius:5 * scale]
                      color:NBTheme.card stroke:NBTheme.accentBlueLine strokeWidth:1 * scale];
    UIBezierPath *target = [UIBezierPath bezierPath];
    [target moveToPoint:pt(69, 29)];
    [target addLineToPoint:pt(117, 29)];
    [self strokeLayerWithPath:target color:NBTheme.accentBlueLine width:1 * scale dash:@[@3, @3]];
    [self strokeLayerWithPath:[self responseCurveFrom:pt(69, 49)
                                            plateauTo:pt(84, 49)
                                                peakTo:pt(105, 26)
                                              settleVia:pt(111, 26)
                                             through:pt(114, 33.5)
                                                   to:pt(118, 33.5)]
                        color:NBTheme.accentBlue width:2.3 * scale dash:nil];
    // 超调标注
    [self fillLayerWithPath:[UIBezierPath bezierPathWithArcCenter:pt(105, 26) radius:2.8 * scale
                                                        startAngle:0 endAngle:M_PI * 2 clockwise:YES]
                      color:NBTheme.accentBlue stroke:nil strokeWidth:0];
    [self fadeLabel:@"8.9%"
               font:[UIFont monospacedSystemFontOfSize:6.5 * scale weight:UIFontWeightSemibold]
              color:NBTheme.accentBlue atFrame:CGRectMake(pt(95, 14).x, pt(95, 14).y, 22 * scale, 9 * scale)];
}

/// 方案迭代:迷你四轴 → 飞一轮箭头 → 三轮渐紧曲线 + R1→R3 轮次链
- (void)buildIteration:(CGPoint (^)(CGFloat, CGFloat))pt scale:(CGFloat)scale {
    // 迷你四轴(俯视):4 臂 + 4 旋翼盘 + 机身
    CGPoint hub = pt(19, 33);
    NSArray *propOffsets = @[ @[@(-8.5), @(-8.5)], @[@8.5, @(-8.5)], @[@(-8.5), @8.5], @[@8.5, @8.5] ];
    for (NSArray *off in propOffsets) {
        CGPoint end = CGPointMake(hub.x + [off[0] floatValue] * scale, hub.y + [off[1] floatValue] * scale);
        UIBezierPath *arm = [UIBezierPath bezierPath];
        [arm moveToPoint:hub];
        [arm addLineToPoint:end];
        [self strokeLayerWithPath:arm color:NBTheme.accentGreen width:2 * scale dash:nil];
        [self fillLayerWithPath:[UIBezierPath bezierPathWithArcCenter:end radius:3 * scale
                                                            startAngle:0 endAngle:M_PI * 2 clockwise:YES]
                          color:NBTheme.card stroke:NBTheme.accentGreen strokeWidth:1.2 * scale];
    }
    [self fillLayerWithPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(hub.x - 3.4 * scale, hub.y - 3.4 * scale, 6.8 * scale, 6.8 * scale)
                                                                     cornerRadius:2 * scale]
                      color:NBTheme.accentGreen stroke:nil strokeWidth:0];
    // 飞一轮箭头
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:pt(38, 33)];
    [arrow addLineToPoint:pt(45, 33)];
    [arrow moveToPoint:pt(42, 30)];
    [arrow addLineToPoint:pt(46, 33)];
    [arrow addLineToPoint:pt(42, 36)];
    [self strokeLayerWithPath:arrow color:NBICMidTeal() width:1.5 * scale dash:nil];
    // 目标线 + 基线
    UIBezierPath *tl = [UIBezierPath bezierPath];
    [tl moveToPoint:pt(52, 20)]; [tl addLineToPoint:pt(122, 20)];
    [self strokeLayerWithPath:tl color:NBTheme.accentGreenLine width:1 * scale dash:@[@3, @3]];
    UIBezierPath *bl = [UIBezierPath bezierPath];
    [bl moveToPoint:pt(52, 44)]; [bl addLineToPoint:pt(122, 44)];
    [self strokeLayerWithPath:bl color:NBICBaseline() width:1 * scale dash:nil];
    // 三轮渐紧(R1 松 → R3 贴目标)
    [self strokeLayerWithPath:[self responseCurveFrom:pt(52, 44) plateauTo:pt(62, 44) peakTo:pt(86, 12) settleVia:pt(96, 12) through:pt(100, 36) to:pt(122, 23)]
                        color:NBTheme.accentGreenLine width:1.6 * scale dash:nil];
    [self strokeLayerWithPath:[self responseCurveFrom:pt(52, 44) plateauTo:pt(66, 44) peakTo:pt(90, 15) settleVia:pt(100, 15) through:pt(106, 29) to:pt(122, 21.5)]
                        color:NBICMidTeal() width:1.6 * scale dash:nil];
    [self strokeLayerWithPath:[self responseCurveFrom:pt(52, 44) plateauTo:pt(70, 44) peakTo:pt(94, 19) settleVia:pt(102, 19) through:pt(110, 20.5) to:pt(122, 20.5)]
                        color:NBTheme.accentGreen width:2.2 * scale dash:nil];
    // 轮次链 R1 R2 R3(空心 → 半实 → 实,间距 20 与 HTML 一致)
    NSArray *chainDots = @[
        @[[NSValue valueWithCGPoint:pt(40, 62)], @3.0, NBTheme.accentGreenLine, NBTheme.card],
        @[[NSValue valueWithCGPoint:pt(60, 62)], @3.0, NBICMidTeal(), NBICMidTeal()],
        @[[NSValue valueWithCGPoint:pt(80, 62)], @3.4, NBTheme.accentGreen, NBTheme.accentGreen],
    ];
    for (NSArray *d in chainDots) {
        CGPoint c = [d[0] CGPointValue];
        [self fillLayerWithPath:[UIBezierPath bezierPathWithArcCenter:c radius:[d[1] floatValue] * scale
                                                            startAngle:0 endAngle:M_PI * 2 clockwise:YES]
                          color:d[3] stroke:d[2] strokeWidth:1.2 * scale];
    }
    [self fadeLabel:@"R1" font:[UIFont monospacedSystemFontOfSize:6 * scale weight:UIFontWeightRegular] color:NBTheme.faint
           atFrame:CGRectMake(pt(36, 66).x, pt(36, 66).y, 10 * scale, 8 * scale)];
    [self fadeLabel:@"R2" font:[UIFont monospacedSystemFontOfSize:6 * scale weight:UIFontWeightRegular] color:NBTheme.faint
           atFrame:CGRectMake(pt(56, 66).x, pt(56, 66).y, 10 * scale, 8 * scale)];
    [self fadeLabel:@"R3" font:[UIFont monospacedSystemFontOfSize:6 * scale weight:UIFontWeightBold] color:NBTheme.accentGreen
           atFrame:CGRectMake(pt(76, 66).x, pt(76, 66).y, 10 * scale, 8 * scale)];
    [self fadeLabel:@"→" font:[UIFont systemFontOfSize:8 * scale weight:UIFontWeightSemibold] color:NBTheme.accentGreen
           atFrame:CGRectMake(pt(92, 61).x, pt(92, 61).y, 12 * scale, 10 * scale)];
}

/// 炸机诊断小场景:摔到地面断开的四轴俯视(机身侧翻+断臂残桩+断落摆臂+地面裂纹)
- (void)buildCrashMini:(CGPoint (^)(CGFloat, CGFloat))pt scale:(CGFloat)scale {
    // 地面裂纹
    NSArray *cracks = @[
        @[[NSValue valueWithCGPoint:pt(27, 23)], [NSValue valueWithCGPoint:pt(34, 19)]],
        @[[NSValue valueWithCGPoint:pt(28.5, 25)], [NSValue valueWithCGPoint:pt(36, 25.5)]],
        @[[NSValue valueWithCGPoint:pt(26.5, 26.5)], [NSValue valueWithCGPoint:pt(31, 32)]],
    ];
    for (NSArray *c in cracks) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:[c.firstObject CGPointValue]];
        [p addLineToPoint:[c.lastObject CGPointValue]];
        [self strokeLayerWithPath:p color:NBICCrack() width:1.2 * scale dash:nil];
    }
    // 断落的摆臂 + 桨盘(整体绕落点旋转)
    UIBezierPath *arm = [UIBezierPath bezierPath];
    [arm moveToPoint:pt(30, 28)];
    [arm addLineToPoint:pt(35.5, 24.5)];
    UIBezierPath *blade = [UIBezierPath bezierPath];
    [blade moveToPoint:pt(33.4, 24.5)];
    [blade addLineToPoint:pt(37.6, 24.5)];
    UIBezierPath *disc = [UIBezierPath bezierPathWithArcCenter:pt(35.5, 24.5) radius:3.6 * scale
                                                     startAngle:0 endAngle:M_PI * 2 clockwise:YES];
    CGAffineTransform t = [self rotateAbout:pt(32, 27) degrees:26];
    [arm applyTransform:t]; [blade applyTransform:t]; [disc applyTransform:t];
    [self strokeLayerWithPath:arm color:NBICLightCoral() width:3 * scale dash:nil];
    [self strokeLayerWithPath:blade color:NBICLightCoral() width:1 * scale dash:nil];
    [self fillLayerWithPath:disc color:NBTheme.card stroke:NBICLightCoral() strokeWidth:1.2 * scale];
    // 机身(三臂完好 + 断臂残桩,整体侧翻 -16°);臂/桨盘/桨叶分层画,避免 appendPath 连接线伪影
    CGPoint hub = pt(14, 13);
    NSArray *armEnds = @[ [NSValue valueWithCGPoint:pt(4.5, 4)], [NSValue valueWithCGPoint:pt(23.5, 4)], [NSValue valueWithCGPoint:pt(4.5, 22)] ];
    CGAffineTransform rot = [self rotateAbout:hub degrees:-16];
    UIBezierPath *arms = [UIBezierPath bezierPath];
    for (NSValue *v in armEnds) {
        [arms moveToPoint:hub];
        [arms addLineToPoint:v.CGPointValue];
    }
    [arms moveToPoint:hub];                    // 断臂残桩
    [arms addLineToPoint:pt(19.5, 18.2)];
    [arms applyTransform:rot];
    [self strokeLayerWithPath:arms color:NBTheme.accentCoral width:3 * scale dash:nil];
    for (NSValue *v in armEnds) {              // 桨盘(细描边圆)
        UIBezierPath *disc = [UIBezierPath bezierPathWithArcCenter:v.CGPointValue radius:4.2 * scale
                                                         startAngle:0 endAngle:M_PI * 2 clockwise:YES];
        [disc applyTransform:rot];
        [self strokeLayerWithPath:disc color:NBTheme.accentCoral width:1.3 * scale dash:nil];
    }
    UIBezierPath *blades = [UIBezierPath bezierPath];
    for (NSValue *v in armEnds) {              // 桨叶线
        CGPoint c = v.CGPointValue;
        [blades moveToPoint:CGPointMake(c.x - 2.3 * scale, c.y)];
        [blades addLineToPoint:CGPointMake(c.x + 2.3 * scale, c.y)];
    }
    [blades applyTransform:rot];
    [self strokeLayerWithPath:blades color:NBTheme.accentCoral width:1.3 * scale dash:nil];
    // 机身高亮块
    UIBezierPath *h = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(pt(9.8, 8.8).x, pt(9.8, 8.8).y, 8.4 * scale, 8.4 * scale)
                                                                cornerRadius:2.4 * scale];
    [h applyTransform:rot];
    [self fillLayerWithPath:h color:NBTheme.accentCoral stroke:nil strokeWidth:0];
}

#pragma mark - 私有辅助

/// 响应曲线:平台段 → 拐点上冲到峰值 → 回落经 through → 收敛到 to(三轮共用,渐紧靠参数)
- (UIBezierPath *)responseCurveFrom:(CGPoint)from plateauTo:(CGPoint)plateau peakTo:(CGPoint)peak
                          settleVia:(CGPoint)via through:(CGPoint)through to:(CGPoint)to {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:from];
    [p addLineToPoint:plateau];
    CGFloat c1x = plateau.x + (peak.x - plateau.x) * 0.45;
    [p addCurveToPoint:peak controlPoint1:CGPointMake(c1x, plateau.y) controlPoint2:CGPointMake(plateau.x + (peak.x - plateau.x) * 0.75, peak.y)];
    CGFloat c2x = peak.x + (to.x - peak.x) * 0.25;
    [p addCurveToPoint:to controlPoint1:CGPointMake(c2x, via.y) controlPoint2:CGPointMake(through.x, through.y)];
    return p;
}

- (CGAffineTransform)rotateAbout:(CGPoint)c degrees:(CGFloat)deg {
    CGAffineTransform t = CGAffineTransformMakeTranslation(c.x, c.y);
    t = CGAffineTransformRotate(t, deg * M_PI / 180.0);
    return CGAffineTransformTranslate(t, -c.x, -c.y);
}

/// 描线层(strokeEnd 模型值=1;动画由 playIntro 一次性加)
- (CAShapeLayer *)strokeLayerWithPath:(UIBezierPath *)path color:(UIColor *)color width:(CGFloat)width dash:(NSArray *)dash {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.path = path.CGPath;
    l.strokeColor = color.CGColor;
    l.fillColor = nil;
    l.lineWidth = width;
    l.lineCap = kCALineCapRound;
    l.lineJoin = kCALineJoinRound;
    l.lineDashPattern = dash;
    l.strokeEnd = 1;
    [self.layer addSublayer:l];
    [_strokeLayers addObject:l];
    return l;
}

/// 填充层(可带描边;淡入)
- (CAShapeLayer *)fillLayerWithPath:(UIBezierPath *)path color:(UIColor *)color stroke:(UIColor *)strokeColor strokeWidth:(CGFloat)width {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.path = path.CGPath;
    l.fillColor = color.CGColor;
    l.strokeColor = strokeColor.CGColor;
    l.lineWidth = width;
    l.lineCap = kCALineCapRound;
    l.lineJoin = kCALineJoinRound;
    [self.layer addSublayer:l];
    [_fillLayers addObject:l];
    return l;
}

/// 文字标注(alpha 终态=1;playIntro 时先置 0 再淡入,保证动画丢失时也可见)
- (void)fadeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color atFrame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.alpha = _played ? 1 : 0;  // 已播过(如 bounds 重建)直接终态
    l.userInteractionEnabled = NO;
    [self addSubview:l];
    [_fadeLabels addObject:l];
}

#pragma mark - 入场动画

- (void)playIntroAnimationOnce {
    if (_played) return;
    _played = YES;
    CFTimeInterval t0 = CACurrentMediaTime() + 0.15;
    CFTimeInterval i = 0;
    for (CAShapeLayer *l in _strokeLayers) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        a.fromValue = @0;
        a.toValue = @1;
        a.duration = 1.1;
        a.beginTime = t0 + i * 0.08;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        a.fillMode = kCAFillModeBackwards;
        [l addAnimation:a forKey:@"nbIntro"];
        i += 1;
    }
    for (CALayer *l in _fillLayers) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @0;
        a.toValue = @(l.opacity);
        a.duration = 0.4;
        a.beginTime = t0 + 0.55;
        a.fillMode = kCAFillModeBackwards;
        [l addAnimation:a forKey:@"nbFade"];
    }
    for (UILabel *l in _fadeLabels) {
        l.alpha = 0;
        [UIView animateWithDuration:0.35
                              delay:0.9
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ l.alpha = 1; }
                         completion:nil];
    }
}

#pragma mark - 导航自绘图标

+ (UIGraphicsImageRenderer *)renderer24 {
    UIGraphicsImageRendererFormat *f = [[UIGraphicsImageRendererFormat alloc] init];
    f.scale = [UIScreen mainScreen].scale;
    return [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24) format:f];
}

+ (UIImage *)navBluetoothImage {
    UIImage *img = [[self renderer24] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(12, 2.5)]; [p addLineToPoint:CGPointMake(12, 21.5)];          // 竖干
        [p moveToPoint:CGPointMake(12, 2.5)];                                                    // 上半枝
        [p addLineToPoint:CGPointMake(17.3, 7.4)]; [p addLineToPoint:CGPointMake(6.7, 16.8)];
        [p moveToPoint:CGPointMake(12, 21.5)];                                                   // 下半枝
        [p addLineToPoint:CGPointMake(17.3, 16.6)]; [p addLineToPoint:CGPointMake(6.7, 7.2)];
        p.lineWidth = 2;
        p.lineCapStyle = kCGLineCapRound;
        p.lineJoinStyle = kCGLineJoinRound;
        [UIColor.blackColor setStroke];
        [p stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)navEraseBlackboxImage {
    UIImage *img = [[self renderer24] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // 匣体
        UIBezierPath *box = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 3.5, 13, 15)
                                                                     cornerRadius:3];
        [NBICBlackbox() setFill];
        [box fill];
        // 标签线
        UIBezierPath *lbl = [UIBezierPath bezierPath];
        [lbl moveToPoint:CGPointMake(6, 7.5)];
        [lbl addLineToPoint:CGPointMake(13, 7.5)];
        lbl.lineWidth = 1.6;
        lbl.lineCapStyle = kCGLineCapRound;
        [[NBIMint() colorWithAlphaComponent:0.9] setStroke];
        [lbl stroke];
        // 清空 ✕(压在匣体右下角)
        UIBezierPath *x = [UIBezierPath bezierPath];
        [x moveToPoint:CGPointMake(15.2, 15.2)]; [x addLineToPoint:CGPointMake(21.2, 21.2)];
        [x moveToPoint:CGPointMake(21.2, 15.2)]; [x addLineToPoint:CGPointMake(15.2, 21.2)];
        x.lineWidth = 2.2;
        x.lineCapStyle = kCGLineCapRound;
        [NBTheme.accentCoral setStroke];
        [x stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@end
