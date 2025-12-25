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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // 布局完成后更新图表（如果有数据的话）
    [self updateChartsIfNeeded];
}

- (void)updateChartsIfNeeded {
    // 只有在Tab视图可见且有数据时才更新图表
    if (!_tabBarController.view.hidden && (_rollResponse || _rollSpectrum || _parsedData)) {
        [self updateCharts];
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

    // 🔍 调试：检查输入数据
    NSLog(@"🔍 轴%ld原始数据检查:", (long)axisIndex);
    NSLog(@"   rcCommand.count=%lu, 前3个值: %@, %@, %@",
          (unsigned long)rcCommand.count,
          rcCommand.count > 0 ? rcCommand[0] : @"N/A",
          rcCommand.count > 1 ? rcCommand[1] : @"N/A",
          rcCommand.count > 2 ? rcCommand[2] : @"N/A");
    NSLog(@"   gyroADC.count=%lu, 前3个值: %@, %@, %@",
          (unsigned long)gyroADC.count,
          gyroADC.count > 0 ? gyroADC[0] : @"N/A",
          gyroADC.count > 1 ? gyroADC[1] : @"N/A",
          gyroADC.count > 2 ? gyroADC[2] : @"N/A");

    // 检查axisP数据
    NSArray<NSNumber *> *axisP = nil;
    switch (axisIndex) {
        case 0: axisP = _parsedData.axisP0; break;
        case 1: axisP = _parsedData.axisP1; break;
        case 2: axisP = _parsedData.axisP2; break;
    }
    NSLog(@"   axisP.count=%lu, 前3个值: %@, %@, %@",
          (unsigned long)axisP.count,
          axisP.count > 0 ? axisP[0] : @"N/A",
          axisP.count > 1 ? axisP[1] : @"N/A",
          axisP.count > 2 ? axisP[2] : @"N/A");

    // 创建指定轴的堆叠窗口数据
    PIDStackData *stackData = [PIDStackData stackFromData:_parsedData
                                                 axisIndex:axisIndex
                                                windowSize:windowSize
                                                  overlap:overlap];

    // 验证堆叠数据
    if (stackData.windowCount == 0) {
        NSLog(@"⚠️ 轴%ld堆叠数据为空", (long)axisIndex);
        return;
    }

    NSLog(@"✅ 轴%ld堆叠数据创建成功: %ld个窗口", (long)axisIndex, (long)stackData.windowCount);

    // 🔍 调试：检查堆叠后的input数据
    if (stackData.input.count > 0) {
        NSArray<NSNumber *> *firstWindow = stackData.input[0];
        NSLog(@"🔍 堆叠后input[0]前5个值: %@, %@, %@, %@, %@",
              firstWindow.count > 0 ? firstWindow[0] : @"N/A",
              firstWindow.count > 1 ? firstWindow[1] : @"N/A",
              firstWindow.count > 2 ? firstWindow[2] : @"N/A",
              firstWindow.count > 3 ? firstWindow[3] : @"N/A",
              firstWindow.count > 4 ? firstWindow[4] : @"N/A");
    }

    if (stackData.gyro.count > 0) {
        NSArray<NSNumber *> *firstGyro = stackData.gyro[0];
        NSLog(@"🔍 堆叠后gyro[0]前5个值: %@, %@, %@, %@, %@",
              firstGyro.count > 0 ? firstGyro[0] : @"N/A",
              firstGyro.count > 1 ? firstGyro[1] : @"N/A",
              firstGyro.count > 2 ? firstGyro[2] : @"N/A",
              firstGyro.count > 3 ? firstGyro[3] : @"N/A",
              firstGyro.count > 4 ? firstGyro[4] : @"N/A");
    }

    // 生成Tukey窗函数（用于stackResponse分析）
    NSArray<NSNumber *> *window = [analyzer tukeyWindowWithLength:windowSize alpha:0.5];

    // 响应分析 - 调用stackResponse获取阶跃响应结果
    PIDResponseResult *response = [analyzer stackResponse:stackData window:window];
    if (response && response.stepResponse.count > 0) {
        // 确保responses数组有足够空间
        while (responses.count <= axisIndex) {
            [responses addObject:[[PIDResponseResult alloc] init]];
        }
        responses[axisIndex] = response;
        NSLog(@"✅ 轴%ld响应分析完成: stepResponse.count=%lu",
              (long)axisIndex, (unsigned long)response.stepResponse.count);
    } else {
        NSLog(@"⚠️ 轴%ld响应分析失败", (long)axisIndex);
    }

    // 频谱分析
    PIDSpectrumResult *spectrum = [analyzer spectrumWithTime:_parsedData.timeSeconds
                                                        traces:stackData.gyro];
    if (spectrums.count <= axisIndex) {
        [spectrums addObject:spectrum];
    }
}

/**
 * 更新图表显示 - 确保在主线程且视图已布局后执行
 */
- (void)updateCharts {
    // 确保在主线程执行
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCharts];
        });
        return;
    }

    // 更新响应图 - 使用AAChartView
    AAChartView *responseChart = objc_getAssociatedObject(_responseViewController, @"aaChartView");

    // 检查视图是否已布局（frame不为0）
    if (responseChart && responseChart.bounds.size.width > 0 && responseChart.bounds.size.height > 0) {
        if (_rollResponse || _parsedData) {
            [self configureResponseChart:responseChart];
        } else {
            [self showEmptyStateChart:responseChart message:@"暂无数据\n请确保CSV文件包含完整的PID参数"];
        }
    }

    // 更新噪声图 - 使用AAChartView
    AAChartView *noiseChart = objc_getAssociatedObject(_noiseViewController, @"aaNoiseChartView");

    if (noiseChart && noiseChart.bounds.size.width > 0 && noiseChart.bounds.size.height > 0) {
        if (_rollSpectrum || _parsedData) {
            [self configureNoiseChart:noiseChart];
        } else {
            [self showEmptyStateChart:noiseChart message:@"暂无数据\n请确保CSV文件包含完整的陀螺仪数据"];
        }
    }
}

/**
 * 配置响应图（阶跃响应）- 使用真实的 stepResponse 数据
 */
- (void)configureResponseChart:(AAChartView *)chartView {
    // 检查是否有真实的响应数据
    if (!_rollResponse || !_rollResponse.stepResponse || _rollResponse.stepResponse.count == 0) {
        [self showEmptyStateChart:chartView message:@"暂无响应数据\n请确保CSV文件包含完整的RC命令和陀螺仪数据"];
        return;
    }

    // 使用真实的时间数据 (avgTime)
    NSArray<NSNumber *> *timeData = _rollResponse.avgTime;
    NSMutableArray<NSString *> *timeCategories = [NSMutableArray arrayWithCapacity:timeData.count];
    for (NSNumber *t in timeData) {
        [timeCategories addObject:[NSString stringWithFormat:@"%.3f", t.doubleValue]];
    }

    // 使用真实的阶跃响应数据 (stepResponse)
    // stepResponse[0] 是 Roll, stepResponse[1] 是 Pitch, stepResponse[2] 是 Yaw
    NSArray<NSNumber *> *rollData = _rollResponse.stepResponse.count > 0 ? _rollResponse.stepResponse[0] : @[];
    NSArray<NSNumber *> *pitchData = _rollResponse.stepResponse.count > 1 ? _rollResponse.stepResponse[1] : @[];
    NSArray<NSNumber *> *yawData = _rollResponse.stepResponse.count > 2 ? _rollResponse.stepResponse[2] : @[];

    // 如果当前轴数据不足，尝试从其他响应对象获取
    if (rollData.count == 0 && _pitchResponse && _pitchResponse.stepResponse.count > 0) {
        rollData = _pitchResponse.stepResponse[0];
    }
    if (pitchData.count == 0 && _pitchResponse && _pitchResponse.stepResponse.count > 1) {
        pitchData = _pitchResponse.stepResponse[1];
    }
    if (yawData.count == 0 && _yawResponse && _yawResponse.stepResponse.count > 2) {
        yawData = _yawResponse.stepResponse[2];
    }

    // 如果仍然没有数据，显示空状态
    if (rollData.count == 0 && pitchData.count == 0 && yawData.count == 0) {
        [self showEmptyStateChart:chartView message:@"暂无响应数据 请确保CSV文件包含完整的RC命令和陀螺仪数据"];
        return;
    }

    // 🔧 清理数据：移除NaN和Infinity值，替换为0（避免JSON序列化崩溃）
    rollData = [self cleanNaNValuesInArray:rollData replaceWithZero:YES];
    pitchData = [self cleanNaNValuesInArray:pitchData replaceWithZero:YES];
    yawData = [self cleanNaNValuesInArray:yawData replaceWithZero:YES];

    // 配置AAChartModel
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeLine;
    chartModel.title = @"阶跃响应";
    chartModel.subtitle = @"Roll/Pitch/Yaw 响应曲线 (真实数据)";
    chartModel.categories = timeCategories;
    chartModel.yAxisTitle = @"响应值";
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @800;
    chartModel.markerSymbol = AAChartSymbolTypeCircle;

    // 创建数据系列 - 只添加有数据的系列
    NSMutableArray<AASeriesElement *> *series = [NSMutableArray array];

    if (rollData.count > 0) {
        AASeriesElement *rollSeries = [[AASeriesElement alloc] init];
        rollSeries.name = @"Roll";
        rollSeries.data = rollData;
        rollSeries.color = @"#FF6B6B";
        [series addObject:rollSeries];
    }

    if (pitchData.count > 0) {
        AASeriesElement *pitchSeries = [[AASeriesElement alloc] init];
        pitchSeries.name = @"Pitch";
        pitchSeries.data = pitchData;
        pitchSeries.color = @"#4ECDC4";
        [series addObject:pitchSeries];
    }

    if (yawData.count > 0) {
        AASeriesElement *yawSeries = [[AASeriesElement alloc] init];
        yawSeries.name = @"Yaw";
        yawSeries.data = yawData;
        yawSeries.color = @"#95E1D3";
        [series addObject:yawSeries];
    }

    chartModel.series = series;

    [chartView aa_drawChartWithChartModel:chartModel];
}

/**
 * 配置噪声频谱图 - 使用真实的 spectrum 数据
 */
- (void)configureNoiseChart:(AAChartView *)chartView {
    // 检查是否有真实的频谱数据
    if (!_rollSpectrum || !_rollSpectrum.frequencies || _rollSpectrum.frequencies.count == 0) {
        [self showEmptyStateChart:chartView message:@"暂无频谱数据\n请确保CSV文件包含完整的陀螺仪数据"];
        return;
    }

    // 使用真实的频率数据
    NSArray<NSNumber *> *frequencies = _rollSpectrum.frequencies;
    NSMutableArray<NSString *> *freqCategories = [NSMutableArray arrayWithCapacity:frequencies.count];
    for (NSNumber *freq in frequencies) {
        [freqCategories addObject:[NSString stringWithFormat:@"%.0f", freq.doubleValue]];
    }

    // 使用真实的频谱幅度数据
    // spectrum 是 [窗口][频率点] 的二维数组
    // 我们需要对所有窗口的频谱取平均值，得到每个轴的单一频谱

    // 辅助函数：计算频谱数组在所有窗口上的平均值
    NSArray<NSNumber *> * (^averageSpectrumAcrossWindows)(NSArray<NSArray<NSNumber *> *> *) = ^ NSArray<NSNumber *> * (NSArray<NSArray<NSNumber *> *> *spectrumData) {
        if (!spectrumData || spectrumData.count == 0) {
            return @[];
        }

        NSInteger windowCount = spectrumData.count;
        NSInteger freqCount = spectrumData[0].count;

        NSMutableArray<NSNumber *> *avgSpectrum = [NSMutableArray arrayWithCapacity:freqCount];

        for (NSInteger i = 0; i < freqCount; i++) {
            double sum = 0.0;
            NSInteger validCount = 0;

            for (NSInteger w = 0; w < windowCount; w++) {
                if (i < spectrumData[w].count) {
                    sum += spectrumData[w][i].doubleValue;
                    validCount++;
                }
            }

            if (validCount > 0) {
                [avgSpectrum addObject:@(sum / validCount)];
            } else {
                [avgSpectrum addObject:@0];
            }
        }

        return [avgSpectrum copy];
    };

    // 获取各轴的平均频谱数据
    NSArray<NSNumber *> *rollNoise = averageSpectrumAcrossWindows(_rollSpectrum.spectrum);
    NSArray<NSNumber *> *pitchNoise = averageSpectrumAcrossWindows(_pitchSpectrum.spectrum);
    NSArray<NSNumber *> *yawNoise = averageSpectrumAcrossWindows(_yawSpectrum.spectrum);

    // 如果仍然没有数据，显示空状态
    if (rollNoise.count == 0 && pitchNoise.count == 0 && yawNoise.count == 0) {
        [self showEmptyStateChart:chartView message:@"暂无频谱数据 请确保CSV文件包含完整的陀螺仪数据"];
        return;
    }

    // 🔧 清理数据：移除NaN和Infinity值，替换为0（避免JSON序列化崩溃）
    rollNoise = [self cleanNaNValuesInArray:rollNoise replaceWithZero:YES];
    pitchNoise = [self cleanNaNValuesInArray:pitchNoise replaceWithZero:YES];
    yawNoise = [self cleanNaNValuesInArray:yawNoise replaceWithZero:YES];

    // 配置AAChartModel - 使用面积图
    AAChartModel *chartModel = [[AAChartModel alloc] init];
    chartModel.chartType = AAChartTypeAreaspline;
    chartModel.title = @"噪声频谱";
    chartModel.subtitle = @"陀螺仪噪声分析 (真实数据)";
    chartModel.categories = freqCategories;
    chartModel.yAxisTitle = @"噪声强度";
    chartModel.animationType = AAChartAnimationEaseOutCubic;
    chartModel.animationDuration = @800;

    // 创建数据系列 - 只添加有数据的系列
    NSMutableArray<AASeriesElement *> *series = [NSMutableArray array];

    if (rollNoise.count > 0) {
        AASeriesElement *rollSeries = [[AASeriesElement alloc] init];
        rollSeries.name = @"Roll";
        rollSeries.data = rollNoise;
        rollSeries.color = @"#FF6B6B";
        rollSeries.fillOpacity = @0.3;
        [series addObject:rollSeries];
    }

    if (pitchNoise.count > 0) {
        AASeriesElement *pitchSeries = [[AASeriesElement alloc] init];
        pitchSeries.name = @"Pitch";
        pitchSeries.data = pitchNoise;
        pitchSeries.color = @"#4ECDC4";
        pitchSeries.fillOpacity = @0.3;
        [series addObject:pitchSeries];
    }

    if (yawNoise.count > 0) {
        AASeriesElement *yawSeries = [[AASeriesElement alloc] init];
        yawSeries.name = @"Yaw";
        yawSeries.data = yawNoise;
        yawSeries.color = @"#95E1D3";
        yawSeries.fillOpacity = @0.3;
        [series addObject:yawSeries];
    }

    chartModel.series = series;

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
    // 将换行符替换为空格，避免JSON解析失败
    NSString *safeMessage = [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    chartModel.subtitle = safeMessage;
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

#pragma mark - Data Cleaning

/**
 * 过滤数组中的NaN和Infinity值，替换为0或nil
 * @param array 原始数据数组
 * @param replaceWithZero YES:替换为0, NO:移除该值
 * @return 清理后的数组
 */
- (NSArray<NSNumber *> *)cleanNaNValuesInArray:(NSArray<NSNumber *> *)array replaceWithZero:(BOOL)replaceWithZero {
    if (!array || array.count == 0) {
        return array;
    }

    NSMutableArray<NSNumber *> *cleaned = [NSMutableArray arrayWithCapacity:array.count];
    for (NSNumber *num in array) {
        double value = num.doubleValue;
        // 检查是否为NaN或Infinity
        if (isnan(value) || isinf(value)) {
            if (replaceWithZero) {
                [cleaned addObject:@0];
            }
            // 如果replaceWithZero为NO，则跳过该值
        } else {
            [cleaned addObject:num];
        }
    }

    return [cleaned copy];
}

/**
 * 过滤二维数组中的NaN和Infinity值
 * @param array2D 原始二维数组
 * @param replaceWithZero YES:替换为0, NO:移除该值
 * @return 清理后的二维数组
 */
- (NSArray<NSArray<NSNumber *> *> *)cleanNaNValuesIn2DArray:(NSArray<NSArray<NSNumber *> *> *)array2D replaceWithZero:(BOOL)replaceWithZero {
    if (!array2D || array2D.count == 0) {
        return array2D;
    }

    NSMutableArray<NSArray<NSNumber *> *> *cleaned = [NSMutableArray arrayWithCapacity:array2D.count];
    for (NSArray<NSNumber *> *innerArray in array2D) {
        NSArray<NSNumber *> *cleanedInner = [self cleanNaNValuesInArray:innerArray replaceWithZero:replaceWithZero];
        [cleaned addObject:cleanedInner];
    }

    return [cleaned copy];
}

@end
