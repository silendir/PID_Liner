//
//  PIDNoiseChartView.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID噪声图表视图实现 - 使用 AAChartKit 散点图替代热力图
//

#import "PIDNoiseChartView.h"
#import <AAChartKit/AAChartKit.h>

#pragma mark - PIDNoiseSpectrumData

@implementation PIDNoiseSpectrumData

+ (instancetype)dataWithFrequencies:(NSArray<NSNumber *> *)frequencies
                   spectrumHeatmap:(NSArray<NSArray<NSNumber *> *> *)spectrumHeatmap
                       throttleAxis:(NSArray<NSNumber *> *)throttleAxis
                          axisName:(NSString *)axisName {
    PIDNoiseSpectrumData *data = [[PIDNoiseSpectrumData alloc] init];
    data.frequencies = frequencies;
    data.spectrumHeatmap = spectrumHeatmap;
    data.throttleAxis = throttleAxis;
    data.axisName = axisName;
    return data;
}

@end

#pragma mark - PIDFilterPassData

@implementation PIDFilterPassData

+ (instancetype)dataWithFrequencies:(NSArray<NSNumber *> *)frequencies
                         passThrough:(NSArray<NSNumber *> *)passThrough {
    PIDFilterPassData *data = [[PIDFilterPassData alloc] init];
    data.frequencies = frequencies;
    data.passThrough = passThrough;
    return data;
}

@end

#pragma mark - PIDNoiseChartView

@interface PIDNoiseChartView ()

// 滚动视图
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *contentView;

// 🔥 使用 AAChartView 替代热力图 - 性能更好，自带交互
@property (nonatomic, strong) NSMutableArray<AAChartView *> *chartViews;

// 滤波器透过率视图
@property (nonatomic, strong) UIView *filterPassView;

@end

@implementation PIDNoiseChartView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minFreq = 10.0;   // 默认显示范围：10-500Hz
        _maxFreq = 500.0;
        _showDTerm = YES;

        _chartViews = [NSMutableArray array];

        [self setupViews];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _minFreq = 10.0;
        _maxFreq = 500.0;
        _showDTerm = YES;

        _chartViews = [NSMutableArray array];

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
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 1400)];
    _contentView.backgroundColor = [UIColor whiteColor];
    [_scrollView addSubview:_contentView];

    // 创建热力图网格
    [self setupHeatmapGrid];

    // 创建滤波器透过率视图
    [self setupFilterPassView];
}

/**
 * 🔥 设置噪声图网格 - 使用 AAChartKit 散点图替代热力图
 * 布局：3行 x 3列（Gyro/Debug/D-term x Roll/Pitch/Yaw）
 */
- (void)setupHeatmapGrid {
    CGFloat margin = 10;
    CGFloat chartHeight = 280;

    // 计算列宽
    NSInteger numCols = _showDTerm ? 3 : 2;
    CGFloat colWidth = (_contentView.bounds.size.width - margin * (numCols + 1)) / numCols;

    // 列标题
    NSArray *columnTitles = @[@"Gyro", @"Debug", @"D-term"];

    for (NSInteger col = 0; col < numCols; col++) {
        CGFloat x = margin + col * (colWidth + margin);

        // 列标题
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, 10, colWidth, 25)];
        titleLabel.text = columnTitles[col];
        titleLabel.font = [UIFont boldSystemFontOfSize:14];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.textColor = [UIColor blackColor];
        [_contentView addSubview:titleLabel];
    }

    // 🔥 创建3行 x 3列 AAChartView 散点图
    NSArray *rowTitles = @[@"Roll", @"Pitch", @"Yaw"];

    for (NSInteger row = 0; row < 3; row++) {
        CGFloat y = 40 + row * (chartHeight + margin);

        // 行标题
        UILabel *rowLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, y + chartHeight / 2 - 10, 35, 20)];
        rowLabel.text = rowTitles[row];
        rowLabel.font = [UIFont systemFontOfSize:12];
        rowLabel.textColor = [UIColor grayColor];
        [_contentView addSubview:rowLabel];

        for (NSInteger col = 0; col < numCols; col++) {
            CGFloat x = margin + col * (colWidth + margin);

            // 🔥 创建 AAChartView（散点图模拟热力图）
            AAChartView *chartView = [[AAChartView alloc] initWithFrame:CGRectMake(x, y, colWidth, chartHeight)];
            chartView.tag = row * 10 + col;  // 用于定位
            chartView.scrollEnabled = YES;  // 启用缩放
            [_contentView addSubview:chartView];
            [_chartViews addObject:chartView];

            // 设置空白图表占位
            [self configureEmptyChart:chartView title:@""];
        }
    }

    // 更新内容视图大小
    CGFloat totalHeight = 40 + 3 * (chartHeight + margin) + 150;  // +150 for filter pass
    CGRect contentFrame = _contentView.frame;
    contentFrame.size.height = totalHeight;
    _contentView.frame = contentFrame;
    _scrollView.contentSize = contentFrame.size;
}

/**
 * 配置空白占位图表
 */
- (void)configureEmptyChart:(AAChartView *)chartView title:(NSString *)title {
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeColumn;  // 直方图
    chartModel.title = title;
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @0;
    chartModel.yAxisMin = @0;  // Y轴从0开始

    AASeriesElement *series = [[AASeriesElement alloc] init];
    series.name = @"";
    series.data = @[];
    chartModel.series = @[series];

    [chartView aa_drawChartWithChartModel:chartModel];
}

/**
 * 设置滤波器透过率视图
 */
- (void)setupFilterPassView {
    CGFloat y = _chartViews.lastObject.frame.origin.y +
                _chartViews.lastObject.frame.size.height + 20;

    CGFloat height = 120;
    CGFloat margin = 10;
    CGFloat width = _contentView.bounds.size.width - 2 * margin;

    _filterPassView = [[UIView alloc] initWithFrame:CGRectMake(margin, y, width, height)];
    _filterPassView.backgroundColor = [UIColor clearColor];
    _filterPassView.layer.borderColor = [UIColor lightGrayColor].CGColor;
    _filterPassView.layer.borderWidth = 0.5;
    [_contentView addSubview:_filterPassView];

    // 标题
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, width - 20, 20)];
    titleLabel.text = @"Filter Pass Through";
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = [UIColor blackColor];
    [_filterPassView addSubview:titleLabel];

    // 图表区域
    UIView *chartView = [[UIView alloc] initWithFrame:CGRectMake(50, 25, width - 70, height - 40)];
    chartView.tag = 500;
    chartView.backgroundColor = [UIColor clearColor];
    [_filterPassView addSubview:chartView];
}

#pragma mark - Public Methods

- (void)setGyroNoiseData:(NSArray<PIDNoiseSpectrumData *> *)gyroData
            debugNoiseData:(NSArray<PIDNoiseSpectrumData *> *)debugData
             dTermNoiseData:(NSArray<PIDNoiseSpectrumData *> *)dTermData {
    _gyroNoiseData = gyroData;
    _debugNoiseData = debugData;
    _dTermNoiseData = dTermData;

    [self refreshDisplay];
}

- (void)refreshDisplay {
    [self updateHeatmaps];
    [self updateFilterPass];
}

- (UIImage *)exportImage {
    UIGraphicsBeginImageContextWithOptions(_contentView.bounds.size, NO, 0.0);
    [_contentView.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)clearData {
    _gyroNoiseData = nil;
    _debugNoiseData = nil;
    _dTermNoiseData = nil;
    _filterPassData = nil;

    // 🔥 清空 AAChartView 图表
    for (AAChartView *chartView in _chartViews) {
        [self configureEmptyChart:chartView title:@""];
    }

    UIView *chartView = [_filterPassView viewWithTag:500];
    [chartView setNeedsDisplay];
}

#pragma mark - Updates

/**
 * 更新所有热力图
 */
- (void)updateHeatmaps {
    // 数据布局：
    // row=0: Roll, row=1: Pitch, row=2: Yaw
    // col=0: Gyro, col=1: Debug, col=2: D-term

    for (NSInteger row = 0; row < 3; row++) {
        // Gyro (col=0)
        if (row < _gyroNoiseData.count) {
            PIDNoiseSpectrumData *data = _gyroNoiseData[row];
            [self updateHeatmapAtRow:row column:0 withData:data];
        }

        // Debug (col=1)
        if (row < _debugNoiseData.count) {
            PIDNoiseSpectrumData *data = _debugNoiseData[row];
            [self updateHeatmapAtRow:row column:1 withData:data];
        }

        // D-term (col=2)
        if (_showDTerm && _dTermNoiseData && row < _dTermNoiseData.count) {
            PIDNoiseSpectrumData *data = _dTermNoiseData[row];
            [self updateHeatmapAtRow:row column:2 withData:data];
        }
    }
}

/**
 * 🔥 更新单个噪声图 - 使用 AAChartKit 直方图
 * 简化方案：X轴=频率，Y轴=振幅，显示最大振幅包络线
 */
- (void)updateHeatmapAtRow:(NSInteger)row column:(NSInteger)col withData:(PIDNoiseSpectrumData *)data {
    NSInteger index = row * 3 + col;

    if (index >= _chartViews.count) return;

    AAChartView *chartView = _chartViews[index];

    // 🔧 简化数据：对每个频率点，取所有油门位置的最大振幅
    // X轴=频率(Hz)，Y轴=振幅
    NSArray<NSArray<NSNumber *> *> *spectrumHeatmap = data.spectrumHeatmap;
    NSArray<NSNumber *> *frequencies = data.frequencies;

    // 只需要 frequencies.count 个数据点
    NSMutableArray<NSNumber *> *maxAmplitudes = [NSMutableArray arrayWithCapacity:frequencies.count];

    for (NSInteger f = 0; f < frequencies.count; f++) {
        double frequency = [frequencies[f] doubleValue];
        double maxAmp = 0;

        // 遍历所有油门位置，找该频率下的最大振幅
        for (NSInteger t = 0; t < spectrumHeatmap.count; t++) {
            NSArray<NSNumber *> *freqAmplitudes = spectrumHeatmap[t];
            if (f < freqAmplitudes.count) {
                double amp = [freqAmplitudes[f] doubleValue];
                if (amp > maxAmp) {
                    maxAmp = amp;
                }
            }
        }

        [maxAmplitudes addObject:@(maxAmp)];
    }

    // 构造直方图数据
    // 🔧 AAChartKit 柱状图需要：categories (X轴标签) + data (Y轴数值数组)
    NSMutableArray<NSNumber *> *amplitudeData = [NSMutableArray array];
    NSMutableArray<NSString *> *categories = [NSMutableArray array];

    for (NSInteger f = 0; f < frequencies.count; f++) {
        double frequency = [frequencies[f] doubleValue];
        double amplitude = [maxAmplitudes[f] doubleValue];

        // 🔧 截断负值到0，确保Y轴无负数
        amplitude = MAX(0.0, amplitude);

        // 限制频率范围
        if (frequency >= self.minFreq && frequency <= self.maxFreq) {
            [amplitudeData addObject:@(amplitude)];
            // X轴标签：显示频率值
            [categories addObject:[NSString stringWithFormat:@"%.0f", frequency]];
        }
    }

    // 🔥 使用 AAChartModel 配置直方图
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeColumn;  // 柱状直方图
    chartModel.title = @"";
    chartModel.subtitle = @"";
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @0;
    chartModel.zoomType = AAChartZoomTypeXY;

    // 轴配置 - Y轴从0开始，无负数
    chartModel.yAxisTitle = @"Amplitude";
    chartModel.yAxisMin = @0;  // Y轴最小值为0
    // X轴：频率分类标签
    chartModel.categories = categories;

    // 颜色
    NSString *color;
    switch (col) {
        case 0:  // Gyro - 蓝色
            color = @"#007AFF";
            break;
        case 1:  // Debug - 橙色
            color = @"#FF9500";
            break;
        case 2:  // D-term - 绿色
            color = @"#34C759";
            break;
        default:
            color = @"#007AFF";
    }

    // 配置数据系列
    AASeriesElement *series = [[AASeriesElement alloc] init];
    series.name = data.axisName;
    series.data = amplitudeData;  // Y轴数值数组
    series.color = color;

    // 直方图不需要标记点
    AAMarker *marker = [[AAMarker alloc] init];
    marker.enabled = @NO;
    series.marker = marker;

    chartModel.series = @[series];

    [chartView aa_drawChartWithChartModel:chartModel];
}

/**
 * 更新滤波器透过率图表
 */
- (void)updateFilterPass {
    UIView *chartView = [_filterPassView viewWithTag:500];
    [chartView setNeedsDisplay];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    // 绘制由子视图处理
}

@end
