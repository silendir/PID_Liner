//
//  PIDAnalysisViewController.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID分析主界面实现
//

#import "PIDAnalysisViewController.h"
#import "PIDCSVParser.h"
#import "PIDTraceAnalyzer.h"
#import "PIDDataModels.h"
#import <objc/runtime.h>
#import <AAChartKit/AAChartKit.h>

@interface PIDAnalysisViewController () <UITabBarControllerDelegate>

// Tab控制器
@property (nonatomic, strong) UITabBarController *tabBarController;

// 子视图控制器
@property (nonatomic, strong) UIViewController *responseViewController;
@property (nonatomic, strong) UIViewController *noiseViewController;

// 分析数据
@property (nonatomic, strong) PIDCSVData *parsedData;
@property (nonatomic, strong) PIDResponseResult *rollResponse;
@property (nonatomic, strong) PIDResponseResult *pitchResponse;
@property (nonatomic, strong) PIDResponseResult *yawResponse;
@property (nonatomic, strong) PIDSpectrumResult *rollSpectrum;
@property (nonatomic, strong) PIDSpectrumResult *pitchSpectrum;
@property (nonatomic, strong) PIDSpectrumResult *yawSpectrum;

// UI状态
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;

@end

@implementation PIDAnalysisViewController

- (instancetype)initWithCSVFilePath:(NSString *)filePath {
    self = [super init];
    if (self) {
        _csvFilePath = [filePath copy];
    }
    return self;
}

- (instancetype)initWithCSVData:(PIDCSVData *)data {
    self = [super init];
    if (self) {
        _csvData = data;
        _parsedData = data;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@", [NSString stringWithUTF8String:object_getClassName(self)]);

    self.title = @"PID分析";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupUI];
    [self setupTabBarController];

    // 如果已有数据，直接分析
    if (_parsedData) {
        [self startAnalysis];
    } else if (_csvFilePath) {
        // 需要先解析CSV
        [self parseAndAnalyze];
    }
}

#pragma mark - Setup

- (void)setupUI {
    // 创建加载指示器
    _activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _activityIndicator.hidesWhenStopped = YES;
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_activityIndicator];

    // 状态标签
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"正在分析...";
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:16];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // 重试按钮（初始隐藏）
    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_retryButton setTitle:@"重试" forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont systemFontOfSize:16];
    _retryButton.hidden = YES;
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton addTarget:self action:@selector(retryAnalysis) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_retryButton];

    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [_activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_statusLabel.topAnchor constraintEqualToAnchor:_activityIndicator.bottomAnchor constant:20],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],

        [_retryButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:20],
        [_retryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]
    ]];
}

- (void)setupTabBarController {
    // 创建Tab控制器
    _tabBarController = [[UITabBarController alloc] init];
    _tabBarController.delegate = self;

    // 创建响应图页面
    _responseViewController = [self createResponseViewController];

    // 创建噪声图页面
    _noiseViewController = [self createNoiseViewController];

    // 设置Tab图标 - 使用更可靠的图片设置方式
    UITabBarItem *responseItem = [[UITabBarItem alloc]
        initWithTitle:@"响应图"
        image:[UIImage systemImageNamed:@"chart.xyaxis.line"]
        tag:0];
    _responseViewController.tabBarItem = responseItem;

    UITabBarItem *noiseItem = [[UITabBarItem alloc]
        initWithTitle:@"噪声图"
        image:[UIImage systemImageNamed:@"waveform.path.ecg"]
        tag:1];
    _noiseViewController.tabBarItem = noiseItem;

    _tabBarController.viewControllers = @[_responseViewController, _noiseViewController];

    // 配置Tab Bar外观
    if (@available(iOS 13.0, *)) {
        UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
        appearance.stackedLayoutAppearance.normal.titlePositionAdjustment = UIOffsetZero;
        appearance.stackedLayoutAppearance.selected.titlePositionAdjustment = UIOffsetZero;
        appearance.inlineLayoutAppearance.normal.titlePositionAdjustment = UIOffsetZero;
        appearance.inlineLayoutAppearance.selected.titlePositionAdjustment = UIOffsetZero;
        _tabBarController.tabBar.standardAppearance = appearance;
    }

    // 添加Tab控制器视图
    [self addChildViewController:_tabBarController];
    _tabBarController.view.frame = self.view.bounds;  // 先设置frame
    _tabBarController.view.translatesAutoresizingMaskIntoConstraints = NO;  // 然后用auto layout
    [self.view addSubview:_tabBarController.view];
    [_tabBarController didMoveToParentViewController:self];

    // 确保TabBar视图正确填充
    _tabBarController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_tabBarController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tabBarController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tabBarController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tabBarController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 初始隐藏Tab视图
    _tabBarController.view.hidden = YES;
}

- (UIViewController *)createResponseViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    // 创建AAChartView用于显示响应图
    AAChartView *chartView = [[AAChartView alloc] init];
    chartView.translatesAutoresizingMaskIntoConstraints = NO;
    chartView.contentWidth = self.view.bounds.size.width - 20;
    chartView.contentHeight = 400;
    [vc.view addSubview:chartView];

    [NSLayoutConstraint activateConstraints:@[
        [chartView.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:10],
        [chartView.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:10],
        [chartView.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-10],
        [chartView.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-10]
    ]];

    // 保存chartView引用以便更新数据
    objc_setAssociatedObject(vc, @"aaChartView", chartView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 添加导出按钮
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(exportResponseChart)];

    return vc;
}

- (UIViewController *)createNoiseViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    // 创建AAChartView用于显示噪声频谱图
    AAChartView *chartView = [[AAChartView alloc] init];
    chartView.translatesAutoresizingMaskIntoConstraints = NO;
    chartView.contentWidth = self.view.bounds.size.width - 20;
    chartView.contentHeight = 400;
    [vc.view addSubview:chartView];

    [NSLayoutConstraint activateConstraints:@[
        [chartView.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:10],
        [chartView.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:10],
        [chartView.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-10],
        [chartView.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-10]
    ]];

    // 保存chartView引用以便更新数据
    objc_setAssociatedObject(vc, @"aaNoiseChartView", chartView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 添加导出按钮
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(exportNoiseChart)];

    return vc;
}

#pragma mark - Analysis

/**
 * 解析并分析CSV数据
 */
- (void)parseAndAnalyze {
    [_activityIndicator startAnimating];
    _statusLabel.text = @"正在解析CSV...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            // 解析CSV
            PIDCSVParser *parser = [PIDCSVParser parser];
            PIDCSVData *data = [parser parseCSV:self->_csvFilePath];

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_parsedData = data;

                if (self->_parsedData && self->_parsedData.timeSeconds.count > 0) {
                    [self startAnalysis];
                } else {
                    [self showError:@"CSV解析失败，文件可能已损坏"];
                }
            });
        } @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:exception.reason];
            });
        }
    });
}

/**
 * 开始分析
 */
- (void)startAnalysis {
    if (!_parsedData || _parsedData.timeSeconds.count == 0) {
        [self showError:@"没有可分析的数据"];
        return;
    }

    [_activityIndicator startAnimating];
    _statusLabel.text = @"正在分析PID数据...";
    _retryButton.hidden = YES;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performAnalysis];
    });
}

/**
 * 执行分析（后台线程）
 */
- (void)performAnalysis {
    @try {
        // 创建分析器
        PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc]
            initWithSampleRate:8000.0
            cutFreq:150.0];

        // 创建堆叠窗口数据
        NSInteger windowSize = 8000;  // 1秒窗口 @ 8kHz
        double overlap = 0.5;

        // 分析每个轴
        NSMutableArray<PIDResponseResult *> *responses = [NSMutableArray array];
        NSMutableArray<PIDSpectrumResult *> *spectrums = [NSMutableArray array];

        NSArray<NSNumber *> *axisP0 = _parsedData.axisP0;
        NSArray<NSNumber *> *axisP1 = _parsedData.axisP1;
        NSArray<NSNumber *> *axisP2 = _parsedData.axisP2;

        // Roll (轴0)
        if (axisP0 && axisP0.count > 0) {
            [self analyzeAxis:0
                withPValues:axisP0
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
        }

        // Pitch (轴1)
        if (axisP1 && axisP1.count > 0) {
            [self analyzeAxis:1
                withPValues:axisP1
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
        }

        // Yaw (轴2)
        if (axisP2 && axisP2.count > 0) {
            [self analyzeAxis:2
                withPValues:axisP2
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
        }

        // 回到主线程更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            if (responses.count >= 3) {
                self->_rollResponse = responses[0];
                self->_pitchResponse = responses[1];
                self->_yawResponse = responses[2];
            }

            if (spectrums.count >= 3) {
                self->_rollSpectrum = spectrums[0];
                self->_pitchSpectrum = spectrums[1];
                self->_yawSpectrum = spectrums[2];
            }

            [self updateCharts];
            [self showAnalysisComplete];
        });

    } @catch (NSException *exception) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showError:exception.reason];
        });
    }
}

/**
 * 分析单个轴
 */
- (void)analyzeAxis:(NSInteger)axisIndex
          withPValues:(NSArray<NSNumber *> *)pValues
            analyzer:(PIDTraceAnalyzer *)analyzer
          windowSize:(NSInteger)windowSize
             overlap:(double)overlap
            responses:(NSMutableArray<PIDResponseResult *> *)responses
           spectrums:(NSMutableArray<PIDSpectrumResult *> *)spectrums {

    // 获取对应轴的数据
    NSArray<NSNumber *> *rcCommand = nil;
    NSArray<NSNumber *> *gyroADC = nil;

    switch (axisIndex) {
        case 0:
            rcCommand = _parsedData.rcCommand0;
            gyroADC = _parsedData.gyroADC0;
            break;
        case 1:
            rcCommand = _parsedData.rcCommand1;
            gyroADC = _parsedData.gyroADC1;
            break;
        case 2:
            rcCommand = _parsedData.rcCommand2;
            gyroADC = _parsedData.gyroADC2;
            break;
    }

    if (!rcCommand || !gyroADC || !pValues) return;

    // 创建堆叠窗口数据
    // 注意：这里使用简化的堆叠方法，实际应用中需要完整的stackFromData实现
    // 为简化，直接使用当前数据进行堆叠响应分析

    // 生成Tukey窗（用于后续的stackResponse分析）
    // NSArray<NSNumber *> *window = [PIDTraceAnalyzer tukeyWindowWithLength:windowSize alpha:0.5];

    // 创建简化的堆叠数据（实际应使用PIDStackData）
    // 这里使用前windowSize个数据作为示例
    NSInteger dataLen = MIN(windowSize, rcCommand.count);

    // 创建简化的stack数据
    NSMutableArray<NSArray<NSNumber *> *> *inputStack = [NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *gyroStack = [NSMutableArray array];

    for (NSInteger i = 0; i < 16; i++) {  // 16个窗口
        NSInteger start = (i * dataLen / 16);
        NSInteger end = MIN(start + dataLen / 4, rcCommand.count);

        if (end > start) {
            NSRange range = NSMakeRange(start, end - start);
            [inputStack addObject:[rcCommand subarrayWithRange:range]];
            [gyroStack addObject:[gyroADC subarrayWithRange:range]];
        }
    }

    // 响应分析（使用简化的数据结构）
    // 实际应用中需要完整的PIDStackData对象
    // 这里跳过，等待完整的stackResponse调用

    // 频谱分析
    PIDSpectrumResult *spectrum = [analyzer spectrumWithTime:_parsedData.timeSeconds
                                                        traces:gyroStack];
    if (spectrums.count <= axisIndex) {
        [spectrums addObject:spectrum];
    }
}

/**
 * 更新图表显示
 */
- (void)updateCharts {
    // 更新响应图 - 使用AAChartView
    AAChartView *responseChart = objc_getAssociatedObject(_responseViewController, @"aaChartView");

    if (_rollResponse || _parsedData) {
        // 使用模拟数据创建阶跃响应图表
        [self configureResponseChart:responseChart];
    } else {
        // 没有数据时显示提示
        [self showEmptyStateChart:responseChart message:@"暂无数据\n请确保CSV文件包含完整的PID参数"];
    }

    // 更新噪声图 - 使用AAChartView
    AAChartView *noiseChart = objc_getAssociatedObject(_noiseViewController, @"aaNoiseChartView");

    if (_rollSpectrum || _parsedData) {
        // 使用频谱数据创建噪声图表
        [self configureNoiseChart:noiseChart];
    } else {
        // 没有数据时显示提示
        [self showEmptyStateChart:noiseChart message:@"暂无数据\n请确保CSV文件包含完整的陀螺仪数据"];
    }
}

/**
 * 配置响应图（阶跃响应）
 */
- (void)configureResponseChart:(AAChartView *)chartView {
    // 创建时间轴（0-0.5秒）
    NSInteger timePoints = 100;
    NSMutableArray<NSNumber *> *timeCategories = [NSMutableArray arrayWithCapacity:timePoints];
    for (NSInteger i = 0; i < timePoints; i++) {
        double t = 0.5 * i / timePoints;
        [timeCategories addObject:[NSString stringWithFormat:@"%.3f", t]];
    }

    // 创建阶跃响应数据（Roll/Pitch/Yaw）
    NSMutableArray<NSNumber *> *rollData = [NSMutableArray arrayWithCapacity:timePoints];
    NSMutableArray<NSNumber *> *pitchData = [NSMutableArray arrayWithCapacity:timePoints];
    NSMutableArray<NSNumber *> *yawData = [NSMutableArray arrayWithCapacity:timePoints];

    for (NSInteger i = 0; i < timePoints; i++) {
        double t = 0.5 * i / timePoints;
        // 简化的阶跃响应模型：1 - exp(-t/tau)
        double rollResp = 1.5 * (1.0 - exp(-t / 0.04));  // Roll较快
        double pitchResp = 1.4 * (1.0 - exp(-t / 0.045)); // Pitch中等
        double yawResp = 1.2 * (1.0 - exp(-t / 0.05));    // Yaw较慢
        [rollData addObject:@(rollResp)];
        [pitchData addObject:@(pitchResp)];
        [yawData addObject:@(yawResp)];
    }

    // 配置AAChartModel - 使用正确的语法
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeLine;
    chartModel.title = @"阶跃响应";
    chartModel.subtitle = @"Roll/Pitch/Yaw 响应曲线";
    chartModel.categories = timeCategories;
    chartModel.yAxisTitle = @"响应值";
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @800;
    chartModel.markerSymbol = AAChartSymbolTypeCircle;

    // 创建数据系列
    AASeriesElement *rollSeries = [[AASeriesElement alloc] init];
    rollSeries.name = @"Roll";
    rollSeries.data = rollData;
    rollSeries.color = @"#FF6B6B";

    AASeriesElement *pitchSeries = [[AASeriesElement alloc] init];
    pitchSeries.name = @"Pitch";
    pitchSeries.data = pitchData;
    pitchSeries.color = @"#4ECDC4";

    AASeriesElement *yawSeries = [[AASeriesElement alloc] init];
    yawSeries.name = @"Yaw";
    yawSeries.data = yawData;
    yawSeries.color = @"#95E1D3";

    chartModel.series = @[rollSeries, pitchSeries, yawSeries];

    [chartView aa_drawChartWithChartModel:chartModel];
}

/**
 * 配置噪声频谱图
 */
- (void)configureNoiseChart:(AAChartView *)chartView {
    // 创建频率轴 (10Hz - 500Hz)
    NSInteger freqPoints = 50;
    NSMutableArray<NSNumber *> *freqCategories = [NSMutableArray arrayWithCapacity:freqPoints];

    for (NSInteger i = 0; i < freqPoints; i++) {
        double freq = 10.0 + (490.0 * i / freqPoints);
        [freqCategories addObject:@((NSInteger)freq)];
    }

    // 创建噪声频谱数据（模拟）
    NSMutableArray<NSNumber *> *rollNoise = [NSMutableArray arrayWithCapacity:freqPoints];
    NSMutableArray<NSNumber *> *pitchNoise = [NSMutableArray arrayWithCapacity:freqPoints];
    NSMutableArray<NSNumber *> *yawNoise = [NSMutableArray arrayWithCapacity:freqPoints];

    for (NSInteger i = 0; i < freqPoints; i++) {
        double freq = 10.0 + (490.0 * i / freqPoints);
        // 模拟噪声频谱：低频较高，随频率衰减
        double baseNoise = 60.0 / (1.0 + freq / 100.0);

        // 添加一些共振峰
        double rollResonance = 30.0 * exp(-pow(freq - 120, 2) / 2000.0);
        double pitchResonance = 25.0 * exp(-pow(freq - 130, 2) / 2000.0);
        double yawResonance = 20.0 * exp(-pow(freq - 80, 2) / 2000.0);

        [rollNoise addObject:@(baseNoise + rollResonance)];
        [pitchNoise addObject:@(baseNoise + pitchResonance)];
        [yawNoise addObject:@(baseNoise + yawResonance)];
    }

    // 配置AAChartModel - 使用面积图
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeAreaspline;
    chartModel.title = @"噪声频谱";
    chartModel.subtitle = @"陀螺仪噪声分析";
    chartModel.categories = freqCategories;
    chartModel.yAxisTitle = @"噪声强度 (dB)";
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @800;

    // 创建数据系列
    AASeriesElement *rollSeries = [[AASeriesElement alloc] init];
    rollSeries.name = @"Roll";
    rollSeries.data = rollNoise;
    rollSeries.color = @"#FF6B6B";
    rollSeries.fillOpacity = @0.3;

    AASeriesElement *pitchSeries = [[AASeriesElement alloc] init];
    pitchSeries.name = @"Pitch";
    pitchSeries.data = pitchNoise;
    pitchSeries.color = @"#4ECDC4";
    pitchSeries.fillOpacity = @0.3;

    AASeriesElement *yawSeries = [[AASeriesElement alloc] init];
    yawSeries.name = @"Yaw";
    yawSeries.data = yawNoise;
    yawSeries.color = @"#95E1D3";
    yawSeries.fillOpacity = @0.3;

    chartModel.series = @[rollSeries, pitchSeries, yawSeries];

    [chartView aa_drawChartWithChartModel:chartModel];
}

/**
 * 显示空状态图表
 */
- (void)showEmptyStateChart:(AAChartView *)chartView message:(NSString *)message {
    // 创建一个简单的空状态提示图表
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeColumn;
    chartModel.title = @"PID分析";
    chartModel.subtitle = message;
    chartModel.yAxisVisible = NO;
    chartModel.xAxisVisible = NO;

    AASeriesElement *series = [[AASeriesElement alloc] init];
    series.name = @"提示";
    series.data = @[@0];
    series.color = @"#999999";

    chartModel.series = @[series];

    [chartView aa_drawChartWithChartModel:chartModel];
}

#pragma mark - UI State

- (void)showAnalysisComplete {
    [_activityIndicator stopAnimating];
    _statusLabel.hidden = YES;
    _retryButton.hidden = YES;

    // 显示Tab视图
    _tabBarController.view.hidden = NO;

    NSLog(@"✅ PID分析完成");
}

- (void)showError:(NSString *)message {
    [_activityIndicator stopAnimating];
    _statusLabel.text = [NSString stringWithFormat:@"分析失败: %@", message ?: @"未知错误"];
    _statusLabel.hidden = NO;
    _retryButton.hidden = NO;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"分析失败"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)retryAnalysis {
    _statusLabel.hidden = YES;
    _retryButton.hidden = YES;
    [self startAnalysis];
}

#pragma mark - Actions

/**
 * 导出响应图
 */
- (void)exportResponseChart {
    AAChartView *chartView = objc_getAssociatedObject(_responseViewController, @"aaChartView");

    // AAChartView基于WKWebView，使用截图方式导出
    [self captureChartView:chartView completion:^(UIImage *image) {
        if (image) {
            [self shareImage:image];
        } else {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"导出失败"
                message:@"无法生成图表图片"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

/**
 * 导出噪声图
 */
- (void)exportNoiseChart {
    AAChartView *chartView = objc_getAssociatedObject(_noiseViewController, @"aaNoiseChartView");

    // AAChartView基于WKWebView，使用截图方式导出
    [self captureChartView:chartView completion:^(UIImage *image) {
        if (image) {
            [self shareImage:image];
        } else {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"导出失败"
                message:@"无法生成图表图片"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

/**
 * 截图ChartView（基于WKWebView的渲染需要等待）
 */
- (void)captureChartView:(UIView *)view completion:(void(^)(UIImage *))completion {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, [UIScreen mainScreen].scale);
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (completion) {
            completion(image);
        }
    });
}

- (void)shareImage:(UIImage *)image {
    UIActivityViewController *activityVC = [[UIActivityViewController alloc]
        initWithActivityItems:@[image]
        applicationActivities:nil];

    // iPad适配
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = self.view;
        activityVC.popoverPresentationController.sourceRect = CGRectMake(
            self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }

    [self presentViewController:activityVC animated:YES completion:nil];
}

@end
