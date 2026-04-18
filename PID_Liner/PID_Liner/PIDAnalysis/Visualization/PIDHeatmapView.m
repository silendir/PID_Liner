//
//  PIDHeatmapView.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  热力图视图实现 - 使用Core Graphics绘制
//

#import "PIDHeatmapView.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - PIDHeatmapConfig

@implementation PIDHeatmapConfig

+ (instancetype)defaultConfig {
    PIDHeatmapConfig *config = [[PIDHeatmapConfig alloc] init];
    config.colors = [self blueColorScale];
    config.minValue = 0.0;
    config.maxValue = 2.0;
    config.useLogScale = NO;
    config.showColorBar = YES;
    config.xAxisLabel = @"X";
    config.yAxisLabel = @"Y";
    config.title = @"";
    return config;
}

+ (instancetype)orangeConfig {
    PIDHeatmapConfig *config = [[PIDHeatmapConfig alloc] init];
    config.colors = [self orangeColorScale];
    config.minValue = 0.0;
    config.maxValue = 2.0;
    config.useLogScale = NO;
    config.showColorBar = YES;
    config.xAxisLabel = @"X";
    config.yAxisLabel = @"Y";
    config.title = @"";
    return config;
}

+ (instancetype)gradientConfigFromColor:(UIColor *)startColor
                                toColor:(UIColor *)endColor
                                  steps:(NSInteger)steps {
    PIDHeatmapConfig *config = [[PIDHeatmapConfig alloc] init];
    config.colors = [self generateGradientFromColor:startColor toColor:endColor steps:steps];
    config.minValue = 0.0;
    config.maxValue = 1.0;
    config.useLogScale = NO;
    config.showColorBar = YES;
    return config;
}

#pragma mark - Color Scales

/**
 * 生成蓝色色阶（Blues colormap）
 */
+ (NSArray<UIColor *> *)blueColorScale {
    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:256];

    // 从浅蓝到深蓝的渐变
    for (NSInteger i = 0; i < 256; i++) {
        double t = (double)i / 255.0;
        // RGB渐变: (247,251,255) -> (8,48,107)
        double r = 247.0 + (8.0 - 247.0) * t;
        double g = 251.0 + (48.0 - 251.0) * t;
        double b = 255.0 + (107.0 - 255.0) * t;
        [colors addObject:[UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:0.8]];
    }

    return [colors copy];
}

/**
 * 生成橙色色阶（Oranges colormap）
 */
+ (NSArray<UIColor *> *)orangeColorScale {
    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:256];

    // 从浅橙到深橙的渐变
    for (NSInteger i = 0; i < 256; i++) {
        double t = (double)i / 255.0;
        // RGB渐变: (255,245,235) -> (127,39,4)
        double r = 255.0 + (127.0 - 255.0) * t;
        double g = 245.0 + (39.0 - 245.0) * t;
        double b = 235.0 + (4.0 - 235.0) * t;
        [colors addObject:[UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:0.8]];
    }

    return [colors copy];
}

/**
 * 生成自定义渐变
 */
+ (NSArray<UIColor *> *)generateGradientFromColor:(UIColor *)startColor
                                          toColor:(UIColor *)endColor
                                            steps:(NSInteger)steps {
    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:steps];

    CGFloat startR, startG, startB, startA;
    CGFloat endR, endG, endB, endA;

    [startColor getRed:&startR green:&startG blue:&startB alpha:&startA];
    [endColor getRed:&endR green:&endG blue:&endB alpha:&endA];

    for (NSInteger i = 0; i < steps; i++) {
        double t = (double)i / (double)(steps - 1);
        CGFloat r = startR + (endR - startR) * t;
        CGFloat g = startG + (endG - startG) * t;
        CGFloat b = startB + (endB - startB) * t;
        CGFloat a = startA + (endA - startA) * t;
        [colors addObject:[UIColor colorWithRed:r green:g blue:b alpha:a]];
    }

    return [colors copy];
}

@end

#pragma mark - PIDHeatmapView

@interface PIDHeatmapView () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIImageView *heatmapImageView;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, assign) CGPoint offset;

@end

@implementation PIDHeatmapView

- (instancetype)initWithFrame:(CGRect)frame config:(PIDHeatmapConfig *)config {
    self = [super initWithFrame:frame];
    if (self) {
        _config = config ?: [PIDHeatmapConfig defaultConfig];
        _scale = 1.0;
        _offset = CGPointZero;

        [self setupViews];
        [self setupGestures];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame config:[PIDHeatmapConfig defaultConfig]];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _config = [PIDHeatmapConfig defaultConfig];
        _scale = 1.0;
        _offset = CGPointZero;

        [self setupViews];
        [self setupGestures];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    self.backgroundColor = [UIColor whiteColor];
    self.contentMode = UIViewContentModeRedraw;

    // 热力图图像视图
    _heatmapImageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _heatmapImageView.contentMode = UIViewContentModeScaleAspectFit;
    _heatmapImageView.backgroundColor = [UIColor clearColor];
    [self addSubview:_heatmapImageView];
}

- (void)setupGestures {
    // 捏合缩放
    UIPinchGestureRecognizer *pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:pinchGesture];

    // 拖动平移
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:panGesture];
}

#pragma mark - Gestures

- (void)handlePinch:(UIPinchGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // 记录初始缩放
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat newScale = _scale * gesture.scale;
        // 限制缩放范围
        newScale = MAX(0.5, MIN(5.0, newScale));
        _scale = newScale;

        CGAffineTransform transform = CGAffineTransformMakeScale(_scale, _scale);
        transform = CGAffineTransformTranslate(transform, _offset.x, _offset.y);
        _heatmapImageView.transform = transform;
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        gesture.scale = 1.0;
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // 记录初始位置
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self];
        _offset = CGPointMake(_offset.x + translation.x, _offset.y + translation.y);

        CGAffineTransform transform = CGAffineTransformMakeScale(_scale, _scale);
        transform = CGAffineTransformTranslate(transform, _offset.x, _offset.y);
        _heatmapImageView.transform = transform;

        [gesture setTranslation:CGPointZero inView:self];
    }
}

#pragma mark - Public Methods

- (void)setData:(NSArray<NSArray<NSNumber *> *> *)data {
    _data = data;
    [self refreshDisplay];
}

- (void)setXAxisValues:(NSArray<NSNumber *> *)xAxisValues {
    _xAxisValues = xAxisValues;
    [self refreshDisplay];
}

- (void)setYAxisValues:(NSArray<NSNumber *> *)yAxisValues {
    _yAxisValues = yAxisValues;
    [self refreshDisplay];
}

- (void)setConfig:(PIDHeatmapConfig *)config {
    _config = config;
    [self refreshDisplay];
}

- (void)refreshDisplay {
    if (!_data || _data.count == 0) {
        return;
    }

    // 生成热力图
    UIImage *heatmapImage = [self generateHeatmapImage];
    _heatmapImageView.image = heatmapImage;
    _heatmapImageView.frame = self.bounds;

    [self setNeedsDisplay];
}

- (UIImage *)exportImage {
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, 0.0);
    [self.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Draw

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];

    CGContextRef context = UIGraphicsGetCurrentContext();

    // 绘制标题
    if (_config.title.length > 0) {
        [self drawTitleInContext:context rect:rect];
    }

    // 绘制轴标签
    [self drawAxisLabelsInContext:context rect:rect];

    // 绘制刻度值
    [self drawTickLabelsInContext:context rect:rect];

    // 绘制颜色条
    if (_config.showColorBar) {
        [self drawColorBarInContext:context rect:rect];
    }
}

#pragma mark - Heatmap Generation

/**
 * 生成热力图图像
 */
- (UIImage *)generateHeatmapImage {
    if (!_data || _data.count == 0) {
        return nil;
    }

    NSInteger rows = _data.count;
    NSInteger cols = _data[0].count;

    // 创建位图上下文
    size_t width = (size_t)self.bounds.size.width;
    size_t height = (size_t)self.bounds.size.height;

    // 计算每个单元格的大小
    CGFloat cellWidth = width / (CGFloat)cols;
    CGFloat cellHeight = height / (CGFloat)rows;

    // 创建图像
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();

    // 绘制每个单元格
    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger col = 0; col < cols; col++) {
            if (col >= _data[row].count) continue;

            double value = [_data[row][col] doubleValue];

            // 归一化值到 [0, 1]
            double normalizedValue = [self normalizeValue:value];

            // 获取对应颜色
            UIColor *color = [self colorForNormalizedValue:normalizedValue];

            // 计算矩形
            CGRect cellRect = CGRectMake(col * cellWidth, row * cellHeight, cellWidth, cellHeight);

            // 填充颜色
            CGContextSetFillColorWithColor(context, color.CGColor);
            CGContextFillRect(context, cellRect);
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return image;
}

/**
 * 归一化值
 */
- (double)normalizeValue:(double)value {
    double range = _config.maxValue - _config.minValue;
    if (range < 1e-9) return 0.5;

    double normalized = (value - _config.minValue) / range;
    return MAX(0.0, MIN(1.0, normalized));
}

/**
 * 获取归一化值对应的颜色
 */
- (UIColor *)colorForNormalizedValue:(double)normalizedValue {
    NSInteger index = (NSInteger)(normalizedValue * (_config.colors.count - 1));
    index = MAX(0, MIN(_config.colors.count - 1, index));
    return _config.colors[index];
}

#pragma mark - Drawing Helpers

- (void)drawTitleInContext:(CGContextRef)context rect:(CGRect)rect {
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor blackColor]
    };

    CGSize size = [_config.title sizeWithAttributes:attrs];
    CGPoint origin = CGPointMake((rect.size.width - size.width) / 2.0, 10);

    [_config.title drawAtPoint:origin withAttributes:attrs];
}

- (void)drawAxisLabelsInContext:(CGContextRef)context rect:(CGRect)rect {
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor blackColor]
    };

    // X轴标签
    CGSize xSize = [_config.xAxisLabel sizeWithAttributes:attrs];
    [_config.xAxisLabel drawAtPoint:CGPointMake((rect.size.width - xSize.width) / 2.0, rect.size.height - 20)
                      withAttributes:attrs];

    // Y轴标签（旋转）
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 15, rect.size.height / 2.0);
    CGContextRotateCTM(context, -M_PI_2);

    CGSize ySize = [_config.yAxisLabel sizeWithAttributes:attrs];
    [_config.yAxisLabel drawAtPoint:CGPointMake(-ySize.width / 2.0, -ySize.height / 2.0)
                      withAttributes:attrs];

    CGContextRestoreGState(context);
}

- (void)drawTickLabelsInContext:(CGContextRef)context rect:(CGRect)rect {
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:10],
        NSForegroundColorAttributeName: [UIColor grayColor]
    };

    CGFloat margin = 40;
    CGFloat plotWidth = rect.size.width - margin - (_config.showColorBar ? 40 : 0);
    CGFloat plotHeight = rect.size.height - margin - 30;

    // X轴刻度
    if (_xAxisValues && _xAxisValues.count > 0) {
        NSInteger numTicks = MIN(5, _xAxisValues.count);
        for (NSInteger i = 0; i < numTicks; i++) {
            NSInteger idx = (i * (_xAxisValues.count - 1)) / (numTicks - 1);
            double value = [_xAxisValues[idx] doubleValue];
            NSString *label = [NSString stringWithFormat:@"%.1f", value];

            CGFloat x = margin + (CGFloat)i / (numTicks - 1) * plotWidth;
            [label drawAtPoint:CGPointMake(x, rect.size.height - 35) withAttributes:attrs];
        }
    }

    // Y轴刻度
    if (_yAxisValues && _yAxisValues.count > 0) {
        NSInteger numTicks = MIN(5, _yAxisValues.count);
        for (NSInteger i = 0; i < numTicks; i++) {
            NSInteger idx = (i * (_yAxisValues.count - 1)) / (numTicks - 1);
            double value = [_yAxisValues[idx] doubleValue];
            NSString *label = [NSString stringWithFormat:@"%.1f", value];

            CGFloat y = rect.size.height - 30 - (CGFloat)i / (numTicks - 1) * plotHeight;
            CGSize size = [label sizeWithAttributes:attrs];
            [label drawAtPoint:CGPointMake(margin - size.width - 5, y - 5) withAttributes:attrs];
        }
    }
}

- (void)drawColorBarInContext:(CGContextRef)context rect:(CGRect)rect {
    CGFloat barWidth = 20;
    CGFloat barHeight = rect.size.height - 80;
    CGFloat barX = rect.size.width - 30;
    CGFloat barY = 50;

    // 绘制颜色条
    for (NSInteger i = 0; i < barHeight; i++) {
        double t = 1.0 - (double)i / barHeight;
        UIColor *color = [self colorForNormalizedValue:t];

        CGRect barRect = CGRectMake(barX, barY + i, barWidth, 1);
        CGContextSetFillColorWithColor(context, color.CGColor);
        CGContextFillRect(context, barRect);
    }

    // 绘制边框
    CGContextSetStrokeColorWithColor(context, [UIColor grayColor].CGColor);
    CGContextStrokeRect(context, CGRectMake(barX, barY, barWidth, barHeight));

    // 绘制刻度标签
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor grayColor]
    };

    // 最大值
    NSString *maxLabel = [NSString stringWithFormat:@"%.2f", _config.maxValue];
    [maxLabel drawAtPoint:CGPointMake(barX + barWidth + 3, barY - 5) withAttributes:attrs];

    // 最小值
    NSString *minLabel = [NSString stringWithFormat:@"%.2f", _config.minValue];
    [minLabel drawAtPoint:CGPointMake(barX + barWidth + 3, barY + barHeight - 5) withAttributes:attrs];
}

@end
