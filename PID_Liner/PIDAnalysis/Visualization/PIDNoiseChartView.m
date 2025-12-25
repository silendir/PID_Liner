//
//  PIDNoiseChartView.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID噪声图表视图实现
//

#import "PIDNoiseChartView.h"
#import "PIDHeatmapView.h"

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

// 热力图视图数组（按行优先排列）
@property (nonatomic, strong) NSMutableArray<PIDHeatmapView *> *heatmapViews;

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

        _heatmapViews = [NSMutableArray array];

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

        _heatmapViews = [NSMutableArray array];

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
 * 设置热力图网格
 * 布局：3行 x 3列（Gyro/Debug/D-term x Roll/Pitch/Yaw）
 */
- (void)setupHeatmapGrid {
    CGFloat margin = 10;
    CGFloat heatmapHeight = 280;

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

    // 创建3行 x 3列热力图
    NSArray *rowTitles = @[@"Roll", @"Pitch", @"Yaw"];

    for (NSInteger row = 0; row < 3; row++) {
        CGFloat y = 40 + row * (heatmapHeight + margin);

        // 行标题
        UILabel *rowLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, y + heatmapHeight / 2 - 10, 35, 20)];
        rowLabel.text = rowTitles[row];
        rowLabel.font = [UIFont systemFontOfSize:12];
        rowLabel.textColor = [UIColor grayColor];
        [_contentView addSubview:rowLabel];

        for (NSInteger col = 0; col < numCols; col++) {
            CGFloat x = margin + col * (colWidth + margin);

            // 创建热力图
            PIDHeatmapConfig *config = [PIDHeatmapConfig defaultConfig];
            config.useLogScale = YES;  // 噪声频谱使用对数刻度
            config.minValue = 0.1;
            config.maxValue = 10.0;
            config.showColorBar = YES;
            config.xAxisLabel = @"Throttle (%)";
            config.yAxisLabel = @"Frequency (Hz)";
            config.title = @"";

            PIDHeatmapView *heatmap = [[PIDHeatmapView alloc] initWithFrame:CGRectMake(x, y, colWidth, heatmapHeight)
                                                                       config:config];
            heatmap.tag = row * 10 + col;  // 用于定位
            [_contentView addSubview:heatmap];
            [_heatmapViews addObject:heatmap];
        }
    }

    // 更新内容视图大小
    CGFloat totalHeight = 40 + 3 * (heatmapHeight + margin) + 150;  // +150 for filter pass
    CGRect contentFrame = _contentView.frame;
    contentFrame.size.height = totalHeight;
    _contentView.frame = contentFrame;
    _scrollView.contentSize = contentFrame.size;
}

/**
 * 设置滤波器透过率视图
 */
- (void)setupFilterPassView {
    CGFloat y = _heatmapViews.lastObject.frame.origin.y +
                _heatmapViews.lastObject.frame.size.height + 20;

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

    for (PIDHeatmapView *heatmap in _heatmapViews) {
        heatmap.data = nil;
        [heatmap refreshDisplay];
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
 * 更新单个热力图
 */
- (void)updateHeatmapAtRow:(NSInteger)row column:(NSInteger)col withData:(PIDNoiseSpectrumData *)data {
    NSInteger index = row * 3 + col;

    if (index >= _heatmapViews.count) return;

    PIDHeatmapView *heatmap = _heatmapViews[index];
    heatmap.data = data.spectrumHeatmap;
    heatmap.xAxisValues = data.throttleAxis;
    heatmap.yAxisValues = data.frequencies;

    // 更新配置以使用对数刻度
    heatmap.config.useLogScale = YES;

    [heatmap refreshDisplay];
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
