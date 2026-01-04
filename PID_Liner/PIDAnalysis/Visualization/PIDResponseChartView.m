//
//  PIDResponseChartView.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID响应图表视图实现
//

#import "PIDResponseChartView.h"
#import "PIDHeatmapView.h"

#pragma mark - PIDResponseData

@implementation PIDResponseData

+ (instancetype)dataWithTime:(NSArray<NSNumber *> *)time
                stepResponse:(NSArray<NSNumber *> *)stepResponse
             responseHeatmap:(NSArray<NSArray<NSNumber *> *> *)responseHeatmap
                 throttleAxis:(NSArray<NSNumber *> *)throttleAxis
            responseTimeAxis:(NSArray<NSNumber *> *)responseTimeAxis
                    axisName:(NSString *)axisName
                  pidString:(NSString *)pidString {
    PIDResponseData *data = [[PIDResponseData alloc] init];
    data.time = time;
    data.stepResponse = stepResponse;
    data.responseHeatmap = responseHeatmap;
    data.throttleAxis = throttleAxis;
    data.responseTimeAxis = responseTimeAxis;
    data.axisName = axisName;
    data.pidString = pidString;
    return data;
}

@end

#pragma mark - PIDResponseChartView

@interface PIDResponseChartView ()

// 子视图区域
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

// 顶部：Gyro vs Input 图表
@property (nonatomic, strong) UIView *gyroInputContainer;

// 中部：Response vs Throttle 热力图
@property (nonatomic, strong) PIDHeatmapView *heatmapView;

// 底部：Step Response 图表
@property (nonatomic, strong) UIView *stepResponseContainer;

// 数据
@property (nonatomic, strong) NSArray<NSNumber *> *gyroData;
@property (nonatomic, strong) NSArray<NSNumber *> *inputData;
@property (nonatomic, strong) NSArray<NSNumber *> *throttleData;

@end

@implementation PIDResponseChartView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _threshold = 500.0;

        [self setupViews];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _threshold = 500.0;
        [self setupViews];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    self.backgroundColor = [UIColor whiteColor];

    // 滚动视图
    _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.showsHorizontalScrollIndicator = YES;
    _scrollView.showsVerticalScrollIndicator = YES;
    _scrollView.minimumZoomScale = 0.5;
    _scrollView.maximumZoomScale = 2.0;
    [self addSubview:_scrollView];

    // 内容视图
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1200)];
    _contentView.backgroundColor = [UIColor whiteColor];
    [_scrollView addSubview:_contentView];

    // 1. Gyro vs Input 区域
    [self setupGyroInputSection];

    // 2. Response vs Throttle 热力图区域
    [self setupHeatmapSection];

    // 3. Step Response 区域
    [self setupStepResponseSection];
}

/**
 * 设置 Gyro vs Input 区域
 */
- (void)setupGyroInputSection {
    CGFloat y = 20;
    CGFloat height = 250;

    _gyroInputContainer = [[UIView alloc] initWithFrame:CGRectMake(15, y, _contentView.bounds.size.width - 30, height)];
    _gyroInputContainer.backgroundColor = [UIColor clearColor];
    _gyroInputContainer.layer.borderColor = [UIColor lightGrayColor].CGColor;
    _gyroInputContainer.layer.borderWidth = 0.5;
    [_contentView addSubview:_gyroInputContainer];

    // 标题
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, _gyroInputContainer.bounds.size.width - 20, 25)];
    titleLabel.text = @"Gyro vs PID Input";
    titleLabel.font = [UIFont boldSystemFontOfSize:14];
    titleLabel.textColor = [UIColor blackColor];
    [_gyroInputContainer addSubview:titleLabel];
}

/**
 * 设置热力图区域
 */
- (void)setupHeatmapSection {
    CGFloat y = _gyroInputContainer.frame.origin.y + _gyroInputContainer.frame.size.height + 15;
    CGFloat height = 300;

    PIDHeatmapConfig *config = [PIDHeatmapConfig defaultConfig];
    config.title = @"Response vs Throttle";
    config.xAxisLabel = @"Throttle (%)";
    config.yAxisLabel = @"Response Time (s)";
    config.minValue = 0.0;
    config.maxValue = 2.0;

    _heatmapView = [[PIDHeatmapView alloc] initWithFrame:CGRectMake(15, y, _contentView.bounds.size.width - 30, height)
                                                    config:config];
    [_contentView addSubview:_heatmapView];
}

/**
 * 设置 Step Response 区域
 */
- (void)setupStepResponseSection {
    CGFloat y = _heatmapView.frame.origin.y + _heatmapView.frame.size.height + 15;
    CGFloat height = 400;

    _stepResponseContainer = [[UIView alloc] initWithFrame:CGRectMake(15, y, _contentView.bounds.size.width - 30, height)];
    _stepResponseContainer.backgroundColor = [UIColor clearColor];
    _stepResponseContainer.layer.borderColor = [UIColor lightGrayColor].CGColor;
    _stepResponseContainer.layer.borderWidth = 0.5;
    [_contentView addSubview:_stepResponseContainer];

    // 标题
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, _stepResponseContainer.bounds.size.width - 20, 25)];
    titleLabel.text = @"Step Response";
    titleLabel.font = [UIFont boldSystemFontOfSize:14];
    titleLabel.textColor = [UIColor blackColor];
    [_stepResponseContainer addSubview:titleLabel];

    // 图例
    UILabel *legendLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, height - 30, _stepResponseContainer.bounds.size.width - 20, 20)];
    legendLabel.text = @"";
    legendLabel.font = [UIFont systemFontOfSize:11];
    legendLabel.textColor = [UIColor grayColor];
    legendLabel.tag = 100;
    [_stepResponseContainer addSubview:legendLabel];

    // 更新内容视图高度
    CGRect contentFrame = _contentView.frame;
    contentFrame.size.height = y + height + 20;
    _contentView.frame = contentFrame;

    _scrollView.contentSize = contentFrame.size;
}

#pragma mark - Public Methods

- (void)setLowResponseData:(PIDResponseData *)lowData
          highResponseData:(PIDResponseData *)highData {
    _lowResponseData = lowData;
    _highResponseData = highData;

    [self refreshDisplay];
}

- (void)refreshDisplay {
    if (!_lowResponseData) {
        return;
    }

    // 更新热力图
    if (_lowResponseData.responseHeatmap && _lowResponseData.responseHeatmap.count > 0) {
        _heatmapView.data = _lowResponseData.responseHeatmap;
        _heatmapView.xAxisValues = _lowResponseData.throttleAxis;
        _heatmapView.yAxisValues = _lowResponseData.responseTimeAxis;
        [_heatmapView refreshDisplay];
    }

    // 重绘所有区域
    [_gyroInputContainer setNeedsDisplay];
    [_stepResponseContainer setNeedsDisplay];

    [self updateLegend];
}

- (UIImage *)exportImage {
    UIGraphicsBeginImageContextWithOptions(_contentView.bounds.size, NO, 0.0);
    [_contentView.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)clearData {
    _lowResponseData = nil;
    _highResponseData = nil;
    _gyroData = nil;
    _inputData = nil;
    _throttleData = nil;

    _heatmapView.data = nil;
    [_heatmapView refreshDisplay];

    [_gyroInputContainer setNeedsDisplay];
    [_stepResponseContainer setNeedsDisplay];
}

- (void)setThreshold:(double)threshold {
    _threshold = threshold;
    [self updateLegend];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];

    // 绘制 Gyro vs Input
    [self drawGyroInputChart];

    // 绘制 Step Response
    [self drawStepResponseChart];
}

/**
 * 绘制 Gyro vs Input 图表
 */
- (void)drawGyroInputChart {
    // 清除旧的绘制层
    for (UIView *subview in _gyroInputContainer.subviews) {
        if ([subview isKindOfClass:[UIView class]] && subview.tag >= 200) {
            [subview removeFromSuperview];
        }
    }

    if (!_gyroData || !_inputData || _gyroData.count == 0) {
        return;
    }

    CGRect plotRect = CGRectMake(50, 35, _gyroInputContainer.bounds.size.width - 70, _gyroInputContainer.bounds.size.height - 50);

    // 创建绘制视图
    UIView *chartView = [[UIView alloc] initWithFrame:plotRect];
    chartView.tag = 200;
    chartView.backgroundColor = [UIColor clearColor];
    [_gyroInputContainer addSubview:chartView];

    // 绘制
    chartView.layer.delegate = (id<CALayerDelegate>)self;
    [chartView.layer setNeedsDisplay];
}

/**
 * 绘制 Step Response 图表
 */
- (void)drawStepResponseChart {
    // 清除旧的绘制层
    for (UIView *subview in _stepResponseContainer.subviews) {
        if ([subview isKindOfClass:[UIView class]] && subview.tag >= 300) {
            [subview removeFromSuperview];
        }
    }

    CGRect plotRect = CGRectMake(60, 35, _stepResponseContainer.bounds.size.width - 80, _stepResponseContainer.bounds.size.height - 70);

    // 创建绘制视图
    UIView *chartView = [[UIView alloc] initWithFrame:plotRect];
    chartView.tag = 300;
    chartView.backgroundColor = [UIColor clearColor];
    chartView.layer.delegate = (id<CALayerDelegate>)self;
    [chartView.layer setNeedsDisplay];
    [_stepResponseContainer addSubview:chartView];

    // 绘制坐标轴
    [self drawAxesInRect:plotRect];
}

/**
 * 绘制坐标轴
 */
- (void)drawAxesInRect:(CGRect)rect {
    // 清除旧的坐标轴视图
    for (UIView *subview in _stepResponseContainer.subviews) {
        if (subview.tag == 310) {
            [subview removeFromSuperview];
        }
    }

    UIView *axisView = [[UIView alloc] initWithFrame:rect];
    axisView.tag = 310;
    axisView.backgroundColor = [UIColor clearColor];
    [_stepResponseContainer addSubview:axisView];

    // 使用CALayer绘制
    axisView.layer.delegate = (id<CALayerDelegate>)self;
}

/**
 * 更新图例
 */
- (void)updateLegend {
    UILabel *legendLabel = [_stepResponseContainer viewWithTag:100];
    if (!legendLabel) return;

    NSMutableString *legend = [NSMutableString string];

    if (_lowResponseData) {
        [legend appendFormat:@"Blue: %@ step response (<%.0f)", _lowResponseData.axisName, _threshold];
        if (_lowResponseData.pidString.length > 0) {
            [legend appendFormat:@" PID %@", _lowResponseData.pidString];
        }
    }

    if (_highResponseData) {
        if (legend.length > 0) [legend appendString:@" | "];
        [legend appendFormat:@"Orange: %@ step response (>%.0f)", _highResponseData.axisName, _threshold];
        if (_highResponseData.pidString.length > 0) {
            [legend appendFormat:@" PID %@", _highResponseData.pidString];
        }
    }

    legendLabel.text = legend;
}

#pragma mark - CALayerDelegate

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context {
    // 获取父视图来确定绘制区域
    UIView *parentView = (UIView *)layer.delegate;

    if (parentView.tag == 200) {
        // Gyro vs Input 图表
        [self drawGyroInputInContext:context rect:parentView.bounds];
    } else if (parentView.tag == 300) {
        // Step Response 图表
        [self drawStepResponseInContext:context rect:parentView.bounds];
    } else if (parentView.tag == 310) {
        // 坐标轴
        [self drawAxisLinesInContext:context rect:parentView.bounds];
    }
}

/**
 * 绘制 Gyro vs Input
 * 🔥 修复：使用对称 Y 轴（以 0 为中心），同时绘制 gyro 和 input 两条曲线
 * 对应 Python: tracelim = np.max([np.abs(tr.gyro),np.abs(tr.input)]); plt.ylim([-tracelim*1.1, tracelim*1.1])
 */
- (void)drawGyroInputInContext:(CGContextRef)context rect:(CGRect)rect {
    if (!_gyroData || !_inputData) return;

    // 🔥 计算 gyro 和 input 的最大绝对值（对称 Y 轴范围）
    double maxAbs = 0;
    for (NSNumber *num in _gyroData) {
        maxAbs = MAX(maxAbs, ABS([num doubleValue]));
    }
    for (NSNumber *num in _inputData) {
        maxAbs = MAX(maxAbs, ABS([num doubleValue]));
    }

    // 设置对称 Y 轴范围（以 0 为中心）
    double tracelim = maxAbs * 1.1;  // 留 10% 余量
    double yMin = -tracelim;
    double yMax = +tracelim;

    // 绘制零线（X轴在图表中间）
    CGContextSetStrokeColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextSetLineWidth(context, 1.0);
    double zeroY = rect.origin.y + rect.size.height * (0.0 - yMin) / (yMax - yMin);
    CGContextMoveToPoint(context, rect.origin.x, zeroY);
    CGContextAddLineToPoint(context, rect.origin.x + rect.size.width, zeroY);
    CGContextStrokePath(context);

    // 绘制网格
    CGContextSetStrokeColorWithColor(context, [UIColor lightGrayColor].CGColor);
    CGContextSetLineWidth(context, 0.5);

    // 水平网格线
    for (NSInteger i = 0; i <= 4; i++) {
        CGFloat y = rect.origin.y + (rect.size.height / 4.0) * i;
        CGContextMoveToPoint(context, rect.origin.x, y);
        CGContextAddLineToPoint(context, rect.origin.x + rect.size.width, y);
    }
    CGContextStrokePath(context);

    // 🔥 绘制 gyro 曲线（红色）
    [self drawLineInContext:context
                       rect:rect
                       data:_gyroData
                      color:[UIColor redColor]
                  lineWidth:2.0
                  yMin:yMin
                  yMax:yMax];

    // 🔥 绘制 input 曲线（蓝色）
    [self drawLineInContext:context
                       rect:rect
                       data:_inputData
                      color:[UIColor blueColor]
                  lineWidth:2.0
                  yMin:yMin
                  yMax:yMax];
}

/**
 * 绘制 Step Response
 */
- (void)drawStepResponseInContext:(CGContextRef)context rect:(CGRect)rect {
    // 绘制低输入响应曲线（蓝色）
    if (_lowResponseData && _lowResponseData.stepResponse) {
        [self drawLineInContext:context
                           rect:rect
                           data:_lowResponseData.stepResponse
                          color:[UIColor blueColor]
                      lineWidth:2.5];
    }

    // 绘制高输入响应曲线（橙色）
    if (_highResponseData && _highResponseData.stepResponse) {
        [self drawLineInContext:context
                           rect:rect
                           data:_highResponseData.stepResponse
                          color:[UIColor orangeColor]
                      lineWidth:2.5];
    }

    // 绘制等高线背景（简化版本）
    if (_lowResponseData) {
        [self drawContourBackgroundInContext:context rect:rect color:[UIColor blueColor] alpha:0.1];
    }
    if (_highResponseData) {
        [self drawContourBackgroundInContext:context rect:rect color:[UIColor orangeColor] alpha:0.1];
    }
}

/**
 * 绘制坐标轴
 */
- (void)drawAxisLinesInContext:(CGContextRef)context rect:(CGRect)rect {
    // Y轴
    CGContextSetStrokeColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextSetLineWidth(context, 1.0);
    CGContextMoveToPoint(context, 0, 0);
    CGContextAddLineToPoint(context, 0, rect.size.height);
    CGContextStrokePath(context);

    // X轴
    CGContextMoveToPoint(context, 0, rect.size.height);
    CGContextAddLineToPoint(context, rect.size.width, rect.size.height);
    CGContextStrokePath(context);

    // Y轴标签 (Strength 0-2)
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor blackColor]
    };

    for (NSInteger i = 0; i <= 4; i++) {
        double value = 2.0 * i / 4.0;
        NSString *label = [NSString stringWithFormat:@"%.1f", value];
        CGFloat y = rect.size.height - (rect.size.height / 4.0) * i;
        CGSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:CGPointMake(-size.width - 3, y - size.height / 2) withAttributes:attrs];
    }

    // X轴标签 (Time 0-0.5s)
    for (NSInteger i = 0; i <= 5; i++) {
        double value = 0.5 * i / 5.0;
        NSString *label = [NSString stringWithFormat:@"%.2f", value];
        CGFloat x = (rect.size.width / 5.0) * i;
        CGSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:CGPointMake(x - size.width / 2, rect.size.height + 3) withAttributes:attrs];
    }
}

/**
 * 绘制等高线背景（简化版本：渐变填充）
 */
- (void)drawContourBackgroundInContext:(CGContextRef)context rect:(CGRect)rect color:(UIColor *)color alpha:(double)alpha {
    CGContextSaveGState(context);

    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];

    // 创建渐变
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[] = { 0.0, 1.0 };
    CGFloat components[] = { r, g, b, 0.0, r, g, b, alpha };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, locations, 2);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, rect.size.height), CGPointMake(0, 0), 0);

    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    CGContextRestoreGState(context);
}

/**
 * 绘制折线（使用硬编码范围 [0, 2]，用于 Step Response 图表）
 */
- (void)drawLineInContext:(CGContextRef)context
                     rect:(CGRect)rect
                     data:(NSArray<NSNumber *> *)data
                    color:(UIColor *)color
                lineWidth:(CGFloat)lineWidth {
    [self drawLineInContext:context rect:rect data:data color:color lineWidth:lineWidth yMin:0.0 yMax:2.0];
}

/**
 * 绘制平滑曲线（支持自定义 Y 轴范围）
 * 🔥 使用 Catmull-Rom 样条插值算法，曲线通过所有数据点
 */
- (void)drawLineInContext:(CGContextRef)context
                     rect:(CGRect)rect
                     data:(NSArray<NSNumber *> *)data
                    color:(UIColor *)color
                lineWidth:(CGFloat)lineWidth
                    yMin:(double)yMin
                    yMax:(double)yMax {
    if (!data || data.count < 2) return;

    // 数据点少于3个时，直接画折线
    if (data.count < 3) {
        [self drawStraightLineInContext:context rect:rect data:data color:color lineWidth:lineWidth yMin:yMin yMax:yMax];
        return;
    }

    // 计算所有点的坐标
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:data.count];
    CGFloat xStep = rect.size.width / (data.count - 1);

    for (NSInteger i = 0; i < data.count; i++) {
        double value = [data[i] doubleValue];
        double normalized = (value - yMin) / (yMax - yMin);
        normalized = MAX(0.0, MIN(1.0, normalized));

        CGFloat x = rect.origin.x + xStep * i;
        CGFloat y = rect.origin.y + rect.size.height * (1.0 - normalized);
        [points addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
    }

    // 绘制平滑曲线
    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, lineWidth);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextBeginPath(context);

    CGPoint p0 = [points[0] CGPointValue];
    CGContextMoveToPoint(context, p0.x, p0.y);

    // 使用 Catmull-Rom 样条绘制曲线
    // 对于每4个连续点 p[i-1], p[i], p[i+1], p[i+2]，绘制 p[i] 到 p[i+1] 的曲线段
    for (NSInteger i = 0; i < points.count - 1; i++) {
        CGPoint p1 = [points[i] CGPointValue];
        CGPoint p2 = [points[i + 1] CGPointValue];

        // 边界处理：首尾点重复
        CGPoint p0 = (i > 0) ? [points[i - 1] CGPointValue] : p1;
        CGPoint p3 = (i < points.count - 2) ? [points[i + 2] CGPointValue] : p2;

        // 计算控制点（Catmull-Rom 转 Cubic Bezier）
        // Catmull-Rom 样条公式转贝塞尔控制点
        CGPoint cp1 = CGPointMake(
            p1.x + (p2.x - p0.x) / 6.0,
            p1.y + (p2.y - p0.y) / 6.0
        );
        CGPoint cp2 = CGPointMake(
            p2.x - (p3.x - p1.x) / 6.0,
            p2.y - (p3.y - p1.y) / 6.0
        );

        CGContextAddCurveToPoint(context, cp1.x, cp1.y, cp2.x, cp2.y, p2.x, p2.y);
    }

    CGContextStrokePath(context);
}

/**
 * 绘制普通折线（用于数据点较少时的回退方案）
 */
- (void)drawStraightLineInContext:(CGContextRef)context
                            rect:(CGRect)rect
                            data:(NSArray<NSNumber *> *)data
                           color:(UIColor *)color
                       lineWidth:(CGFloat)lineWidth
                           yMin:(double)yMin
                           yMax:(double)yMax {
    if (!data || data.count < 2) return;

    CGContextSetStrokeColorWithColor(context, color.CGColor);
    CGContextSetLineWidth(context, lineWidth);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextBeginPath(context);

    CGFloat xStep = rect.size.width / (data.count - 1);

    for (NSInteger i = 0; i < data.count; i++) {
        double value = [data[i] doubleValue];
        double normalized = (value - yMin) / (yMax - yMin);
        normalized = MAX(0.0, MIN(1.0, normalized));

        CGFloat x = rect.origin.x + xStep * i;
        CGFloat y = rect.origin.y + rect.size.height * (1.0 - normalized);

        if (i == 0) {
            CGContextMoveToPoint(context, x, y);
        } else {
            CGContextAddLineToPoint(context, x, y);
        }
    }

    CGContextStrokePath(context);
}

@end
