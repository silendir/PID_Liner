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
#import "PIDCurveDiagnostic.h"
#import "PIDRecommendationEngine.h"
#import "PIDCLIGenerator.h"
#import <objc/runtime.h>
#import <AAChartKit/AAChartKit.h>
#import <SVProgressHUD/SVProgressHUD.h>
#import <mach/mach_time.h>

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

// 🔑 第3~5层：诊断/推荐/CLI 数据
@property (nonatomic, strong) PIDResponseFeatures *rollFeatures;
@property (nonatomic, strong) PIDResponseFeatures *pitchFeatures;
@property (nonatomic, strong) PIDResponseFeatures *yawFeatures;
@property (nonatomic, strong) PIDTuningResult *rollTuningResult;
@property (nonatomic, strong) PIDTuningResult *pitchTuningResult;
@property (nonatomic, strong) PIDTuningResult *yawTuningResult;
@property (nonatomic, copy) NSString *cliCommands;

// UI状态
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIProgressView *progressView;  // 🔥 进度条

// 🔥 新增：响应图显示点数切换
@property (nonatomic, assign) NSInteger responseDisplayPoints;  // 50 或 100

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

    // 🔥 从 UserDefaults 读取显示点数偏好，默认 50
    NSInteger savedPoints = [[NSUserDefaults standardUserDefaults] integerForKey:@"responseDisplayPoints"];
    // 范围检查：50 ~ 1000，默认 50
    if (savedPoints < 50 || savedPoints > 1000) {
        savedPoints = 50;
    }
    _responseDisplayPoints = savedPoints;

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

    // 🔥 进度条
    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.progress = 0;
    _progressView.hidden = YES;  // 初始隐藏
    [self.view addSubview:_progressView];

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
        [_activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],

        [_statusLabel.topAnchor constraintEqualToAnchor:_activityIndicator.bottomAnchor constant:16],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],

        // 🔥 进度条约束
        [_progressView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:12],
        [_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
        [_progressView.heightAnchor constraintEqualToConstant:4],

        [_retryButton.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor constant:20],
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

    // 🔥 创建固定在顶部的滑块容器
    UIView *sliderContainer = [[UIView alloc] init];
    sliderContainer.translatesAutoresizingMaskIntoConstraints = NO;
    sliderContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    sliderContainer.layer.cornerRadius = 8;
    [vc.view addSubview:sliderContainer];

    // 标题标签
    UILabel *sliderLabel = [[UILabel alloc] init];
    sliderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    sliderLabel.font = [UIFont systemFontOfSize:13];
    sliderLabel.text = [NSString stringWithFormat:@"显示精度: %ld 点", (long)_responseDisplayPoints];
    sliderLabel.textAlignment = NSTextAlignmentCenter;
    [sliderContainer addSubview:sliderLabel];

    // 滑块
    UISlider *slider = [[UISlider alloc] init];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.minimumValue = 50;
    slider.maximumValue = 1000;  // 🔥 从 4000 改为 1000
    slider.value = _responseDisplayPoints;
    // 🔥 值改变时只更新标签，不触发刷新
    [slider addTarget:self action:@selector(responseDisplayPointsSliderChanged:) forControlEvents:UIControlEventValueChanged];
    // 🔥 松手时立即显示 HUD 并刷新
    [slider addTarget:self action:@selector(responseDisplayPointsSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside];
    [slider addTarget:self action:@selector(responseDisplayPointsSliderTouchUp:) forControlEvents:UIControlEventTouchUpOutside];
    [sliderContainer addSubview:slider];

    // 预设说明标签
    UILabel *presetsLabel = [[UILabel alloc] init];
    presetsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    presetsLabel.font = [UIFont systemFontOfSize:11];
    presetsLabel.text = @"50 ← 平滑 | 精确 → 1000";
    presetsLabel.textColor = [UIColor secondaryLabelColor];
    presetsLabel.textAlignment = NSTextAlignmentCenter;
    [sliderContainer addSubview:presetsLabel];

    // 保存控件引用
    objc_setAssociatedObject(vc, "displayPointsSlider", slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, "displayPointsSliderLabel", sliderLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 创建滚动视图以容纳三个图表
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = YES;
    scrollView.showsHorizontalScrollIndicator = NO;
    [vc.view addSubview:scrollView];

    // 创建内容视图
    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];

    // 图表高度配置
    CGFloat chartHeight = 540;  // 每个图表高度 (原300 * 1.8)
    CGFloat spacing = 15;        // 图表间距

    // 用于保存三个图表视图的引用
    AAChartView *rollChartView = nil;
    AAChartView *pitchChartView = nil;
    AAChartView *yawChartView = nil;

    // 创建三个独立的 AAChartView (Roll, Pitch, Yaw)
    for (NSInteger i = 0; i < 3; i++) {
        AAChartView *chartView = [[AAChartView alloc] init];
        chartView.translatesAutoresizingMaskIntoConstraints = NO;
        chartView.contentHeight = chartHeight;
        // 启用AAChartView的内置缩放功能
        chartView.scrollEnabled = YES;  // 允许滚动缩放
        [contentView addSubview:chartView];

        // 保存引用
        if (i == 0) rollChartView = chartView;
        else if (i == 1) pitchChartView = chartView;
        else if (i == 2) yawChartView = chartView;

        // 设置约束 - 垂直排列
        [NSLayoutConstraint activateConstraints:@[
            [chartView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:10],
            [chartView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-10],
            [chartView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:spacing + i * (chartHeight + spacing)],
            [chartView.heightAnchor constraintEqualToConstant:chartHeight]
        ]];

        // 保存每个图表的引用，使用静态char指针作为key
        static char const *const kChartViewKeys[] = {"aaChartView0", "aaChartView1", "aaChartView2"};
        objc_setAssociatedObject(vc, kChartViewKeys[i], chartView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 设置内容视图底部约束（按钮的底部）
    // 🔑 CLI复制按钮放在最下面
    UIButton *cliCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cliCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cliCopyButton setTitle:@"📋 复制 CLI 调参命令" forState:UIControlStateNormal];
    cliCopyButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    cliCopyButton.backgroundColor = [UIColor systemBlueColor];
    [cliCopyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cliCopyButton.layer.cornerRadius = 10;
    cliCopyButton.clipsToBounds = YES;
    cliCopyButton.contentEdgeInsets = UIEdgeInsetsMake(12, 20, 12, 20);
    cliCopyButton.hidden = YES;  // 初始隐藏，等诊断完成后显示
    [cliCopyButton addTarget:self action:@selector(copyCLICommands) forControlEvents:UIControlEventTouchUpInside];
    [contentView addSubview:cliCopyButton];

    // 保存按钮引用
    objc_setAssociatedObject(vc, "cliCopyButton", cliCopyButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        [cliCopyButton.topAnchor constraintEqualToAnchor:yawChartView.bottomAnchor constant:spacing],
        [cliCopyButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [cliCopyButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
        [cliCopyButton.heightAnchor constraintEqualToConstant:48],
        [contentView.bottomAnchor constraintEqualToAnchor:cliCopyButton.bottomAnchor constant:spacing]
    ]];

    // 🔥 设置滑块容器约束（固定在顶部）
    [NSLayoutConstraint activateConstraints:@[
        [sliderContainer.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:10],
        [sliderContainer.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:15],
        [sliderContainer.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-15],
        [sliderContainer.heightAnchor constraintEqualToConstant:70],
        [sliderLabel.topAnchor constraintEqualToAnchor:sliderContainer.topAnchor constant:8],
        [sliderLabel.leadingAnchor constraintEqualToAnchor:sliderContainer.leadingAnchor constant:10],
        [sliderLabel.trailingAnchor constraintEqualToAnchor:sliderContainer.trailingAnchor constant:-10],
        [slider.topAnchor constraintEqualToAnchor:sliderLabel.bottomAnchor constant:4],
        [slider.leadingAnchor constraintEqualToAnchor:sliderContainer.leadingAnchor constant:15],
        [slider.trailingAnchor constraintEqualToAnchor:sliderContainer.trailingAnchor constant:-15],
        [presetsLabel.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:2],
        [presetsLabel.leadingAnchor constraintEqualToAnchor:sliderContainer.leadingAnchor constant:10],
        [presetsLabel.trailingAnchor constraintEqualToAnchor:sliderContainer.trailingAnchor constant:-10],
    ]];

    // 设置滚动视图约束（从滑块容器下方开始）
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:sliderContainer.bottomAnchor constant:10],
        [scrollView.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
        [contentView.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.widthAnchor]
    ]];

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

#pragma mark - Progress

/**
 * 🔥 更新分析进度
 * @param progress 进度值 (0.0 ~ 1.0)
 * @param status 状态描述
 */
- (void)updateProgress:(float)progress status:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 显示进度条
        self.progressView.hidden = NO;
        self.progressView.progress = progress;

        // 更新状态文字
        if (status) {
            self.statusLabel.text = status;
        }
    });
}

#pragma mark - Analysis

/**
 * 解析并分析CSV数据
 */
- (void)parseAndAnalyze {
    [_activityIndicator startAnimating];
    _progressView.hidden = NO;
    _progressView.progress = 0;
    _statusLabel.text = @"正在解析 CSV 文件...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            // 🔥 解析前更新进度 (0% → 10%)
            [self updateProgress:0.05f status:@"正在读取 CSV 文件..."];

            // 解析CSV
            PIDCSVParser *parser = [PIDCSVParser parser];
            PIDCSVData *data = [parser parseCSV:self->_csvFilePath];

            // 🔥 解析完成更新进度 (10% → 20%)
            [self updateProgress:0.20f status:@"正在准备分析..."];

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
        // 🔥 关键修复：使用实际采样率而非硬编码的8000Hz
        // 实际数据可能来自不同采样率的黑盒子日志（如931Hz, 1kHz, 8kHz等）
        double actualSampleRate = _parsedData.sampleRate > 0 ? _parsedData.sampleRate : 8000.0;
        NSLog(@"🔍 [分析] 使用实际采样率: %.2fHz", actualSampleRate);

        // 🔧 修正：Python使用cutfreq=25Hz而非150Hz
        PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc]
            initWithSampleRate:actualSampleRate
            cutFreq:25.0];

        // 🔧 修正：Python使用superpos=16，对应overlap=15/16=0.9375
        // 🔥 关键：窗口大小保持固定值 8000，确保 FFT 分辨率和信号质量
        // - 如果根据采样率动态计算 windowSize，会导致：
        //   1. FFT 分辨率降低（windowSize 越小，频率分辨率越低）
        //   2. 反卷积结果列数减少（columnCount = windowSize/2）
        //   3. 信号能量大幅减少（窗函数能量与 windowSize 成正比）
        // - 正确做法：保持 windowSize 固定，只修正时间轴计算
        // TODO: 理想情况下应该重采样数据到 8kHz，但当前保持 windowSize=8000
        NSInteger windowSize = 8000;  // 固定窗口大小（用于 FFT/反卷积）
        double overlap = 0.9375;

        // 分析每个轴
        NSMutableArray<PIDResponseResult *> *responses = [NSMutableArray array];
        NSMutableArray<PIDSpectrumResult *> *spectrums = [NSMutableArray array];

        NSArray<NSNumber *> *axisP0 = _parsedData.axisP0;
        NSArray<NSNumber *> *axisP1 = _parsedData.axisP1;
        NSArray<NSNumber *> *axisP2 = _parsedData.axisP2;

        // 🔥 计数器，用于确定当前分析的是第几个轴
        NSInteger axisCount = 0;
        if (axisP0 && axisP0.count > 0) axisCount++;
        if (axisP1 && axisP1.count > 0) axisCount++;
        if (axisP2 && axisP2.count > 0) axisCount++;

        // 🔥 分析进度范围：20% → 95%（每个轴约 25%）
        float progressPerAxis = 0.75f / (axisCount > 0 ? axisCount : 3);

        // Roll (轴0) - 20% → 45%
        if (axisP0 && axisP0.count > 0) {
            [self updateProgress:0.20f status:@"正在分析 Roll 轴..."];
            [self analyzeAxis:0
                withPValues:axisP0
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
            [self updateProgress:(0.20f + progressPerAxis) status:@"正在分析 Pitch 轴..."];
        }

        // Pitch (轴1) - 45% → 70%
        if (axisP1 && axisP1.count > 0) {
            [self updateProgress:0.45f status:@"正在分析 Pitch 轴..."];
            [self analyzeAxis:1
                withPValues:axisP1
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
            [self updateProgress:(0.45f + progressPerAxis) status:@"正在分析 Yaw 轴..."];
        }

        // Yaw (轴2) - 70% → 95%
        if (axisP2 && axisP2.count > 0) {
            [self updateProgress:0.70f status:@"正在分析 Yaw 轴..."];
            [self analyzeAxis:2
                withPValues:axisP2
                analyzer:analyzer
                windowSize:windowSize
                overlap:overlap
                responses:responses
                spectrums:spectrums];
            [self updateProgress:0.95f status:@"正在生成图表..."];
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

    // 🔧 修正：添加pGain参数（使用默认值45，后续可从CSV头解析）
    // 不同轴的P增益值：Roll=45, Pitch=50, Yaw=55（常见配置）
    double pGain = 45.0;
    switch (axisIndex) {
        case 0: pGain = 45.0; break;  // Roll
        case 1: pGain = 50.0; break;  // Pitch
        case 2: pGain = 55.0; break;  // Yaw
    }

    // 创建指定轴的堆叠窗口数据
    PIDStackData *stackData = [PIDStackData stackFromData:_parsedData
                                                 axisIndex:axisIndex
                                                windowSize:windowSize
                                                  overlap:overlap
                                                     pGain:pGain];

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

    // 🔧 修正：Python使用Hanning窗而非Tukey窗
    // 生成Hanning窗函数（用于stackResponse分析）
    NSArray<NSNumber *> *window = [PIDTraceAnalyzer hanningWindowWithLength:windowSize];

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
    NSLog(@"🔍🔍🔍 [updateCharts] ========== 开始执行 ==========");

    // 确保在主线程执行
    if (![NSThread isMainThread]) {
        NSLog(@"🔍 [updateCharts] 不在主线程，切换到主线程");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCharts];
        });
        return;
    }

    // 定义静态key（与createResponseViewController中的key保持一致）
    static char const *const kChartViewKeys[] = {"aaChartView0", "aaChartView1", "aaChartView2"};

    // 获取第一个响应图表来检查是否已布局
    AAChartView *firstChartView = objc_getAssociatedObject(_responseViewController, kChartViewKeys[0]);

    // 检查视图是否已布局（frame不为0）
    if (firstChartView && firstChartView.bounds.size.width > 0 && firstChartView.bounds.size.height > 0) {
        if (_rollResponse || _pitchResponse || _yawResponse) {
            [self configureResponseCharts];
        } else if (_parsedData) {
            [self configureResponseCharts];
        } else {
            // 显示空状态
            for (NSInteger i = 0; i < 3; i++) {
                AAChartView *chartView = objc_getAssociatedObject(_responseViewController, kChartViewKeys[i]);
                if (chartView) {
                    [self showEmptyStateChart:chartView message:@"暂无数据\n请确保CSV文件包含完整的PID参数"];
                }
            }
        }
    } else {
        NSLog(@"⚠️ 响应图表视图未布局，bounds=%@", NSStringFromCGRect(firstChartView ? firstChartView.bounds : CGRectZero));
    }

    // 更新噪声图 - 使用AAChartView
    AAChartView *noiseChart = objc_getAssociatedObject(_noiseViewController, @"aaNoiseChartView");

    NSLog(@"🔍 [updateCharts] _noiseViewController = %@", _noiseViewController ? @"存在" : @"nil");
    NSLog(@"🔍 [updateCharts] noiseChart = %@", noiseChart ? @"存在" : @"nil");
    NSLog(@"🔍 [updateCharts] noiseChart.bounds = %@",
          noiseChart ? NSStringFromCGRect(noiseChart.bounds) : @"N/A");
    NSLog(@"🔍 [updateCharts] _rollSpectrum = %@", _rollSpectrum ? @"存在" : @"nil");

    // 🔥 移除 bounds 检查，强制更新噪声图（真机可能 bounds 为 0 但仍可绘制）
    if (noiseChart) {
        if (_rollSpectrum || _parsedData) {
            NSLog(@"🔍 [updateCharts] 调用 configureNoiseChart (强制执行)");
            [self configureNoiseChart:noiseChart];
        } else {
            NSLog(@"⚠️ [updateCharts] 无 rollSpectrum 数据");
            [self showEmptyStateChart:noiseChart message:@"暂无数据\n请确保CSV文件包含完整的陀螺仪数据"];
        }
    } else {
        NSLog(@"⚠️ [updateCharts] noiseChart 为 nil!");
    }
}

/**
 * 配置响应图（阶跃响应）- 使用真实的 stepResponse 数据
 * 为每个轴创建独立的图表
 */
- (void)configureResponseChart:(AAChartView *)chartView {
    // 此方法不再使用，改为 configureResponseCharts
    // 保留此方法以避免编译错误
    [self configureResponseCharts];
}

/**
 * 配置三个独立的响应图（Roll, Pitch, Yaw）
 */
- (void)configureResponseCharts {
    // 定义静态key（与createResponseViewController中的key保持一致）
    static char const *const kChartViewKeys[] = {"aaChartView0", "aaChartView1", "aaChartView2"};

    // 检查是否有响应数据
    if (!_rollResponse && !_pitchResponse && !_yawResponse) {
        // 显示空状态
        for (NSInteger i = 0; i < 3; i++) {
            AAChartView *chartView = objc_getAssociatedObject(_responseViewController, kChartViewKeys[i]);
            if (chartView) {
                [self showEmptyStateChart:chartView message:@"暂无响应数据\n请确保CSV文件包含完整的RC命令和陀螺仪数据"];
            }
        }
        return;
    }

    // 配置每个轴的图表
    // 🔑 先执行诊断，生成预测曲线数据，再配置图表（这样图表可以一次性画出实线+虚线）
    [self runDiagnosisPipeline];

    [self configureSingleAxisChart:0 responseResult:_rollResponse axisName:@"Roll" color:@"#FF6B6B"];
    [self configureSingleAxisChart:1 responseResult:_pitchResponse axisName:@"Pitch" color:@"#4ECDC4"];
    [self configureSingleAxisChart:2 responseResult:_yawResponse axisName:@"Yaw" color:@"#95E1D3"];

    // 显示复制按钮
    UIButton *cliButton = objc_getAssociatedObject(_responseViewController, "cliCopyButton");
    if (cliButton && self.cliCommands.length > 0) {
        cliButton.hidden = NO;
    }
}

/**
 * 配置单个轴的响应图表
 * 🔑 修复版本：使用low_high_mask分离低/高输入响应，显示两条曲线
 *
 * @param axisIndex 轴索引 (0=Roll, 1=Pitch, 2=Yaw)
 * @param responseResult 响应结果对象
 * @param axisName 轴名称
 * @param color 图表颜色 (HEX) - 仅用于低输入曲线，高输入曲线自动使用橙色
 */
- (void)configureSingleAxisChart:(NSInteger)axisIndex
                  responseResult:(PIDResponseResult *)responseResult
                        axisName:(NSString *)axisName
                           color:(NSString *)color {

    // 定义静态key（与createResponseViewController中的key保持一致）
    static char const *const kChartViewKeys[] = {"aaChartView0", "aaChartView1", "aaChartView2"};

    // 获取对应的图表视图
    AAChartView *chartView = objc_getAssociatedObject(_responseViewController, kChartViewKeys[axisIndex]);

    if (!chartView) {
        NSLog(@"⚠️ 轴%@的图表视图不存在", axisName);
        return;
    }

    // 检查视图是否已布局（frame不为0）
    if (chartView.bounds.size.width == 0 || chartView.bounds.size.height == 0) {
        NSLog(@"⚠️ 轴%@的图表视图未布局，延迟配置", axisName);
        return;
    }

    // 检查是否有响应数据
    if (!responseResult || !responseResult.stepResponse || responseResult.stepResponse.count == 0) {
        [self showEmptyStateChart:chartView message:[NSString stringWithFormat:@"暂无%@响应数据", axisName]];
        return;
    }

    NSInteger windowCount = responseResult.stepResponse.count;
    if (windowCount == 0) {
        [self showEmptyStateChart:chartView message:[NSString stringWithFormat:@"%@响应数据为空", axisName]];
        return;
    }

    // 🔑🔑🔑 关键修复：实现Python的数据分离逻辑 🔑🔑🔑
    // Python: low_mask, high_mask = low_high_mask(max_in, threshold)
    //         toolow_mask = low_high_mask(max_in, 20)[1]
    //         resp_low_mask = low_mask * toolow_mask
    //         resp_high_mask = high_mask * toolow_mask

    // 1. 计算low/high mask (threshold=500)
    NSDictionary *masks = [PIDTraceAnalyzer lowHighMask:responseResult.maxInput threshold:500.0];
    NSArray<NSNumber *> *lowMask = masks[@"low"];
    NSArray<NSNumber *> *highMask = masks[@"high"];

    // 2. 计算toolow_mask (threshold=20)
    // Python: toolow_mask = low_high_mask(max_in, 20)[1] (取high部分，即>20)
    NSDictionary *tooLowMasks = [PIDTraceAnalyzer lowHighMask:responseResult.maxInput threshold:20.0];
    NSArray<NSNumber *> *toolowMask = tooLowMasks[@"high"];  // 取high部分（>20）

    // 3. 组合mask
    NSMutableArray<NSNumber *> *respLowMask = [NSMutableArray array];
    NSMutableArray<NSNumber *> *respHighMask = [NSMutableArray array];

    for (NSInteger i = 0; i < MIN(lowMask.count, toolowMask.count); i++) {
        double lowVal = [lowMask[i] doubleValue];
        double toolowVal = [toolowMask[i] doubleValue];
        [respLowMask addObject:@(lowVal * toolowVal)];  // low AND toolow
    }

    for (NSInteger i = 0; i < MIN(highMask.count, toolowMask.count); i++) {
        double highVal = [highMask[i] doubleValue];
        double toolowVal = [toolowMask[i] doubleValue];
        [respHighMask addObject:@(highVal * toolowVal)];  // high AND toolow
    }

    // 4. 计算分离的响应曲线
    NSArray<NSNumber *> *vertRange = @[@(-1.5), @(3.5)];
    // 🔥 使用实际采样率
    double sampleRate = _parsedData.sampleRate > 0 ? _parsedData.sampleRate : 8000.0;

    // 🔥 新增：质量过滤机制（对应Python的resp_quality）
    // 第一步：使用初步mask计算初始平均响应
    NSArray<NSNumber *> *respLowInitial = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:
        responseResult.stepResponse
        avgTime:responseResult.avgTime
        dataMask:respLowMask  // 使用low mask
        vertRange:vertRange
        vertBins:1000
        sampleRate:sampleRate];

    // 第二步：计算响应质量mask（过滤偏离平均响应过大的窗口）
    NSArray<NSNumber *> *qualityMask = [PIDTraceAnalyzer calculateResponseQualityMask:
        responseResult.stepResponse
        referenceResponse:respLowInitial];

    // 第三步：组合low mask和quality mask
    NSArray<NSNumber *> *respLowMaskCombined = [PIDTraceAnalyzer combineMasks:respLowMask withMask:qualityMask];

    // 第四步：使用组合后的mask重新计算最终响应
    // 🔥 加权平均内部已经应用了高斯平滑（对histogram2d），不需要额外平滑
    // 额外平滑会导致边缘效应，使起点不为0
    NSArray<NSNumber *> *respLow = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:
        responseResult.stepResponse
        avgTime:responseResult.avgTime
        dataMask:respLowMaskCombined  // 🔑 使用low + quality组合mask
        vertRange:vertRange
        vertBins:1000
        sampleRate:sampleRate];

    // 🔑 第1层验证：从曲线提取时域特征
    PIDResponseFeatures *lowFeatures = [PIDTraceAnalyzer extractFeaturesFromResponse:respLow
                                                                          sampleRate:sampleRate];
    NSLog(@"📊 [%@ 低输入] 超调=%.1f%%, 上升=%.1fms, 建立=%.1fms, 震荡=%ld次, 稳态=%.3f, 峰值=%.3f",
          axisName,
          lowFeatures.overshoot * 100.0,
          lowFeatures.riseTime,
          lowFeatures.settlingTime,
          (long)lowFeatures.oscillationCount,
          lowFeatures.steadyState,
          lowFeatures.peakValue);

    // 🔑 存储特征到属性（供后续诊断使用）
    switch (axisIndex) {
        case 0: self.rollFeatures = lowFeatures; break;
        case 1: self.pitchFeatures = lowFeatures; break;
        case 2: self.yawFeatures = lowFeatures; break;
    }

    // 🔑 获取该轴的预测曲线结果（由 runDiagnosisPipeline 预先计算）
    PIDTuningResult *tuningResult = nil;
    switch (axisIndex) {
        case 0: tuningResult = self.rollTuningResult; break;
        case 1: tuningResult = self.pitchTuningResult; break;
        case 2: tuningResult = self.yawTuningResult; break;
    }

    // 🔍 调试：打印respLow的数据范围
    if (respLow && respLow.count > 0) {
        double minVal = [respLow[0] doubleValue];
        double maxVal = [respLow[0] doubleValue];
        for (NSNumber *num in respLow) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 [%@] respLow范围(质量过滤后): [%.3f, %.3f]，起点=%.3f，终点=%.3f",
              axisName, minVal, maxVal, [respLow[0] doubleValue], [respLow[respLow.count-1] doubleValue]);
    }

    NSArray<NSNumber *> *respHigh = nil;
    BOOL hasHighData = NO;

    // 检查是否有高输入数据
    NSInteger highWindowCount = 0;
    for (NSNumber *maskVal in respHighMask) {
        if ([maskVal doubleValue] > 0.5) {
            highWindowCount++;
        }
    }

    if (highWindowCount >= 10) {  // 至少10个窗口
        NSLog(@"🔍 [%@] 开始计算高输入响应... (%ld窗口)", axisName, (long)highWindowCount);

        // 🔥 新增：高输入响应也应用质量过滤
        // 第一步：计算初始高输入响应
        NSArray<NSNumber *> *respHighInitial = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:
            responseResult.stepResponse
            avgTime:responseResult.avgTime
            dataMask:respHighMask
            vertRange:vertRange
            vertBins:1000
            sampleRate:sampleRate];

        // 第二步：计算质量mask（使用同一个参考响应respLowInitial，因为所有窗口应该趋向同一个稳态响应）
        NSArray<NSNumber *> *qualityMaskHigh = [PIDTraceAnalyzer calculateResponseQualityMask:
            responseResult.stepResponse
            referenceResponse:respLowInitial];

        // 第三步：组合high mask和quality mask
        NSArray<NSNumber *> *respHighMaskCombined = [PIDTraceAnalyzer combineMasks:respHighMask withMask:qualityMaskHigh];

        // 第四步：使用组合后的mask重新计算最终高输入响应
        // 🔥 加权平均内部已经应用了高斯平滑，不需要额外平滑
        respHigh = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:
            responseResult.stepResponse
            avgTime:responseResult.avgTime
            dataMask:respHighMaskCombined  // 🔑 使用high + quality组合mask
            vertRange:vertRange
            vertBins:1000
            sampleRate:sampleRate];

        hasHighData = YES;

        // 🔑 第1层验证：高输入曲线特征提取
        if (respHigh && respHigh.count > 10) {
            PIDResponseFeatures *highFeatures = [PIDTraceAnalyzer extractFeaturesFromResponse:respHigh
                                                                                    sampleRate:sampleRate];
            NSLog(@"📊 [%@ 高输入] 超调=%.1f%%, 上升=%.1fms, 建立=%.1fms, 震荡=%ld次, 稳态=%.3f, 峰值=%.3f",
                  axisName,
                  highFeatures.overshoot * 100.0,
                  highFeatures.riseTime,
                  highFeatures.settlingTime,
                  (long)highFeatures.oscillationCount,
                  highFeatures.steadyState,
                  highFeatures.peakValue);
        }

        // 🔍 调试：打印respHigh的数据范围
        if (respHigh && respHigh.count > 0) {
            double minVal = [respHigh[0] doubleValue];
            double maxVal = minVal;
            for (NSNumber *num in respHigh) {
                double v = [num doubleValue];
                if (v < minVal) minVal = v;
                if (v > maxVal) maxVal = v;
            }
            NSLog(@"✅ [%@] 高输入响应计算成功 (%ld窗口)", axisName, (long)highWindowCount);
            NSLog(@"🔍 [%@] respHigh范围: [%.3f, %.3f]，起点=%.3f，终点=%.3f",
                  axisName, minVal, maxVal, [respHigh[0] doubleValue], [respHigh[respHigh.count-1] doubleValue]);
        } else {
            NSLog(@"⚠️ [%@] respHigh为空！", axisName);
        }
    } else {
        NSLog(@"⚠️ %@: 高输入窗口数(%ld) < 10，跳过高输入曲线", axisName, (long)highWindowCount);
    }

    // 5. 准备图表数据
    NSInteger lowWindowCount = 0;
    for (NSNumber *maskVal in respLowMask) {
        if ([maskVal doubleValue] > 0.5) {
            lowWindowCount++;
        }
    }

    // 🔥 使用可配置的显示点数 + 分块平均降采样（保留精度）
    // 通过 UISegmentedControl 切换：50点(平滑) 或 100点(精确)
    NSInteger displayPoints = _responseDisplayPoints;
    NSMutableArray<NSString *> *timeCategories = [NSMutableArray arrayWithCapacity:displayPoints];
    NSMutableArray<NSNumber *> *displayLowData = [NSMutableArray arrayWithCapacity:displayPoints];
    NSMutableArray<NSNumber *> *displayHighData = hasHighData ? [NSMutableArray arrayWithCapacity:displayPoints] : nil;

    // 🔑 降采样预测曲线（与实线同样的 displayPoints）
    NSArray<NSNumber *> *displayPredData = nil;
    if (tuningResult && tuningResult.predictedCurve.count > 10) {
        NSArray<NSNumber *> *predCurve = tuningResult.predictedCurve;
        NSInteger pLen = predCurve.count;
        NSInteger ppBlock = (pLen - 1) / (displayPoints - 1);
        if (ppBlock < 1) ppBlock = 1;
        NSMutableArray<NSNumber *> *predDisplay = [NSMutableArray arrayWithCapacity:displayPoints];
        for (NSInteger j = 0; j < displayPoints; j++) {
            if (j == 0) {
                [predDisplay addObject:@0];
            } else {
                NSInteger si = 1 + (j - 1) * ppBlock;
                NSInteger ei = MIN(1 + j * ppBlock, pLen);
                if (si < pLen && ei > si) {
                    double sum = 0; NSInteger cnt = 0;
                    for (NSInteger k = si; k < ei; k++) { sum += [predCurve[k] doubleValue]; cnt++; }
                    [predDisplay addObject:@(sum / cnt)];
                } else {
                    [predDisplay addObject:@([predCurve.lastObject doubleValue])];
                }
            }
        }
        displayPredData = [predDisplay copy];
    }

    double duration = 0.5;  // 响应时长0.5秒
    NSInteger pointsPerBlock = (respLow.count - 1) / (displayPoints - 1);

    for (NSInteger i = 0; i < displayPoints; i++) {
        double t = (i * duration) / (displayPoints - 1);
        [timeCategories addObject:[NSString stringWithFormat:@"%.3f", t]];

        if (i == 0) {
            // 第一个点直接取原始值（确保起点为0）
            [displayLowData addObject:respLow[0]];
            if (hasHighData && respHigh && displayHighData) {
                [displayHighData addObject:respHigh[0]];
            }
        } else {
            // 分块平均降采样
            NSInteger startIdx = 1 + (i - 1) * pointsPerBlock;
            NSInteger endIdx = MIN(1 + i * pointsPerBlock, respLow.count);

            if (startIdx < respLow.count && endIdx > startIdx) {
                double sum = 0.0;
                NSInteger count = 0;
                for (NSInteger j = startIdx; j < endIdx; j++) {
                    sum += [respLow[j] doubleValue];
                    count++;
                }
                [displayLowData addObject:@(sum / count)];
            } else {
                [displayLowData addObject:respLow[respLow.count - 1]];
            }

            if (hasHighData && respHigh && displayHighData) {
                NSInteger startHigh = 1 + (i - 1) * pointsPerBlock;
                NSInteger endHigh = MIN(1 + i * pointsPerBlock, respHigh.count);

                if (startHigh < respHigh.count && endHigh > startHigh) {
                    double sum = 0.0;
                    NSInteger count = 0;
                    for (NSInteger j = startHigh; j < endHigh; j++) {
                        sum += [respHigh[j] doubleValue];
                        count++;
                    }
                    [displayHighData addObject:@(sum / count)];
                } else {
                    [displayHighData addObject:respHigh[respHigh.count - 1]];
                }
            }
        }
    }

    // 6. 配置图表显示两条曲线 - 使用 AAOptions 以支持 tooltip 样式
    AAOptions *aaOptions = [[AAOptions alloc] init];

    // Chart 配置
    aaOptions.chart = [[AAChart alloc] init];
    aaOptions.chart.type = AAChartTypeSpline;  // 🔥 平滑曲线样式
    aaOptions.chart.pinchType = @"xy";  // 🔥 启用双指缩放（iOS用pinchType）

    // Title 配置
    aaOptions.title = [[AATitle alloc] init];
    aaOptions.title.text = [NSString stringWithFormat:@"%@ 阶跃响应 (分离)", axisName];

    // Subtitle 配置
    AASubtitle *subtitle = [[AASubtitle alloc] init];
    NSString *subtitleText;
    if (hasHighData) {
        subtitleText = [NSString stringWithFormat:@"蓝: ≤500°/s (%ld窗口) | 橙: >500°/s (%ld窗口)",
                       (long)lowWindowCount, (long)highWindowCount];
    } else {
        subtitleText = [NSString stringWithFormat:@"蓝: ≤500°/s (%ld窗口) | 橙: >500°/s (无数据，需更激烈的操纵)",
                       (long)lowWindowCount];
    }
    subtitle.text = subtitleText;
    aaOptions.subtitle = subtitle;

    // X轴配置
    AAXAxis *xAxis = [[AAXAxis alloc] init];
    xAxis.categories = timeCategories;
    aaOptions.xAxis = xAxis;

    // Y轴配置
    AAYAxis *yAxis = [[AAYAxis alloc] init];
    yAxis.title = [[AAAxisTitle alloc] init];
    yAxis.title.text = @"响应值";
    yAxis.min = @0;
    yAxis.max = @2;
    yAxis.tickInterval = @0.25;  // 每0.25一个刻度：0, 0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 1.75, 2.00
    yAxis.allowDecimals = @YES;  // 允许小数刻度
    aaOptions.yAxis = yAxis;

    // 🔧 Tooltip 配置：与噪声图相同的样式
    AATooltip *tooltip = [[AATooltip alloc] init];
    tooltip.enabled = @YES;
    tooltip.useHTML = @YES;
    tooltip.valueDecimals = @2;  // 保留2位小数
    tooltip.backgroundColor = @"rgba(0, 0, 0, 0.5)";  // 50%不透明度的黑色背景
    tooltip.borderColor = @"rgba(0, 0, 0, 0.5)";
    tooltip.borderWidth = @1;
    tooltip.shadow = @NO;  // 无阴影
    tooltip.style = [[AAStyle alloc] init];
    tooltip.style.color = @"#ffffff";  // 白色文字
    aaOptions.tooltip = tooltip;

    // 创建数据系列
    NSMutableArray<AASeriesElement *> *series = [NSMutableArray array];

    // 低输入响应曲线（蓝色）
    AASeriesElement *lowSeries = [[AASeriesElement alloc] init];
    lowSeries.name = [NSString stringWithFormat:@"%@ 低输入 (≤500°/s)", axisName];
    lowSeries.data = displayLowData;
    lowSeries.color = @"#007AFF";  // 蓝色
    lowSeries.lineWidth = @2.5;
    AAMarker *lowMarker = [[AAMarker alloc] init];
    lowMarker.radius = @0;
    lowSeries.marker = lowMarker;
    [series addObject:lowSeries];

    // 🔑 修复：即使没有高输入数据，也要在图例中显示橙色线
    // 如果有数据，显示实际曲线；如果没有数据，显示一条平线表示无数据
    AASeriesElement *highSeries = [[AASeriesElement alloc] init];
    highSeries.name = [NSString stringWithFormat:@"%@ 高输入 (>500°/s)", axisName];

    if (hasHighData && displayHighData) {
        // 有数据：显示实际曲线
        highSeries.data = displayHighData;
        highSeries.color = @"#FF9500";  // 橙色
        highSeries.lineWidth = @2.5;
        highSeries.enableMouseTracking = @YES;
    } else {
        // 无数据：显示一条值为0的平线，让图例可见但曲线不明显
        NSMutableArray<NSNumber *> *zeroData = [NSMutableArray arrayWithCapacity:displayPoints];
        for (NSInteger i = 0; i < displayPoints; i++) {
            [zeroData addObject:@0];
        }
        highSeries.data = zeroData;
        highSeries.color = @"#FFCCAA";  // 浅橙色（表示无数据）
        highSeries.lineWidth = @1.0;     // 更细的线
        highSeries.dashStyle = @"Dash";  // 虚线表示无数据
        highSeries.enableMouseTracking = @NO;  // 禁用鼠标跟踪
    }
    AAMarker *highMarker = [[AAMarker alloc] init];
    highMarker.radius = @0;
    highSeries.marker = highMarker;
    [series addObject:highSeries];  // 🔑 始终添加到图例中

    // 🔑 预测虚线曲线（绿色虚线）
    if (displayPredData) {
        AASeriesElement *predSeries = [[AASeriesElement alloc] init];
        predSeries.name = @"预测曲线 (CLI生效后)";
        predSeries.data = displayPredData;
        predSeries.color = @"#34C759";  // 绿色
        predSeries.lineWidth = @2;
        predSeries.dashStyle = @"Dash";  // 虚线
        AAMarker *predMarker = [[AAMarker alloc] init];
        predMarker.radius = @0;
        predSeries.marker = predMarker;
        [series addObject:predSeries];
    }

    aaOptions.series = series;

    // 🔥 使用 AAOptions 绘制图表
    [chartView aa_drawChartWithOptions:aaOptions];

    NSLog(@"✅ %@阶跃响应图表配置完成: 低输入=%ld窗口, 高输入=%ld窗口, 显示点数=%ld",
          axisName, (long)lowWindowCount, (long)highWindowCount, (long)displayPoints);
}

/**
 * 🔥 滑块值改变时只更新标签（不触发刷新）
 * @param sender UISlider 控件
 */
- (void)responseDisplayPointsSliderChanged:(UISlider *)sender {
    // 使用四舍五入取整
    NSInteger newPoints = (NSInteger)round(sender.value);

    if (_responseDisplayPoints != newPoints) {
        _responseDisplayPoints = newPoints;

        // 保存到 UserDefaults
        [[NSUserDefaults standardUserDefaults] setInteger:newPoints forKey:@"responseDisplayPoints"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // 更新标签显示
        UILabel *sliderLabel = objc_getAssociatedObject(_responseViewController, "displayPointsSliderLabel");
        sliderLabel.text = [NSString stringWithFormat:@"显示精度: %ld 点", (long)newPoints];

        NSLog(@"🔄 滑块值改变: %ld", (long)newPoints);
    }
}

/**
 * 🔥 滑块松手时立即显示 HUD 并刷新
 * @param sender UISlider 控件
 */
- (void)responseDisplayPointsSliderTouchUp:(UISlider *)sender {
    NSLog(@"🎯 滑块松手，触发刷新: %ld 点", (long)_responseDisplayPoints);

    // 🔥 松手那一刻立即显示 HUD
    [SVProgressHUD showWithStatus:@"调整精度中..."];

    // 🔥 延迟一小段时间让 HUD 渲染，然后执行刷新
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 执行刷新
        [self updateCharts];

        // 🔥 刷新完成后隐藏 HUD
        [SVProgressHUD dismiss];
    });
}

/**
 * 配置噪声频谱图 - 使用真实的 spectrum 数据
 * 🔥 改为直方图显示，Y轴从0开始
 */
- (void)configureNoiseChart:(AAChartView *)chartView {
    NSLog(@"🔍 [噪声图] configureNoiseChart 开始执行");
    NSLog(@"🔍 [噪声图] chartView.bounds = %@", NSStringFromCGRect(chartView.bounds));

    // 检查 chartView 是否有效
    if (!chartView) {
        NSLog(@"⚠️ [噪声图] chartView 为 nil!");
        return;
    }

    NSLog(@"🔍 [噪声图] _rollSpectrum = %@", _rollSpectrum ? @"存在" : @"nil");
    NSLog(@"🔍 [噪声图] _rollSpectrum.frequencies.count = %lu",
          _rollSpectrum ? (unsigned long)_rollSpectrum.frequencies.count : 0);

    // 检查是否有真实的频谱数据
    if (!_rollSpectrum || !_rollSpectrum.frequencies || _rollSpectrum.frequencies.count == 0) {
        NSLog(@"⚠️ [噪声图] 无频谱数据，显示空状态");
        [self showEmptyStateChart:chartView message:@"暂无频谱数据\n请确保CSV文件包含完整的陀螺仪数据"];
        return;
    }

    // 使用真实的频率数据
    NSArray<NSNumber *> *frequencies = _rollSpectrum.frequencies;
    NSLog(@"🔍 [噪声图] frequencies.count = %lu", (unsigned long)frequencies.count);
    NSLog(@"🔍 [噪声图] frequencies 前3个: %@, %@, %@",
          frequencies.count > 0 ? frequencies[0] : @"N/A",
          frequencies.count > 1 ? frequencies[1] : @"N/A",
          frequencies.count > 2 ? frequencies[2] : @"N/A");

    // 🔥 X轴添加 Hz 单位
    NSMutableArray<NSString *> *freqCategories = [NSMutableArray arrayWithCapacity:frequencies.count];
    for (NSNumber *freq in frequencies) {
        [freqCategories addObject:[NSString stringWithFormat:@"%.0f Hz", freq.doubleValue]];
    }
    NSLog(@"🔍 [噪声图] freqCategories.count = %lu", (unsigned long)freqCategories.count);

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

    NSLog(@"🔍 [噪声图] rollNoise.count = %lu", (unsigned long)rollNoise.count);
    NSLog(@"🔍 [噪声图] pitchNoise.count = %lu", (unsigned long)pitchNoise.count);
    NSLog(@"🔍 [噪声图] yawNoise.count = %lu", (unsigned long)yawNoise.count);

    // 如果仍然没有数据，显示空状态
    if (rollNoise.count == 0 && pitchNoise.count == 0 && yawNoise.count == 0) {
        NSLog(@"⚠️ [噪声图] 所有轴数据为空");
        [self showEmptyStateChart:chartView message:@"暂无频谱数据 请确保CSV文件包含完整的陀螺仪数据"];
        return;
    }

    // 🔧 清理数据：移除NaN和Infinity值，替换为0（避免JSON序列化崩溃）
    rollNoise = [self cleanNaNValuesInArray:rollNoise replaceWithZero:YES];
    pitchNoise = [self cleanNaNValuesInArray:pitchNoise replaceWithZero:YES];
    yawNoise = [self cleanNaNValuesInArray:yawNoise replaceWithZero:YES];

    // 🔧 确保所有值为非负数（截断负值到0）
    rollNoise = [self ensureNonNegativeValues:rollNoise];
    pitchNoise = [self ensureNonNegativeValues:pitchNoise];
    yawNoise = [self ensureNonNegativeValues:yawNoise];

    // 🔥 配置AAChartModel - 改为柱状直方图，Y轴从0开始
    // 使用 AAOptions 以获得更完整的 tooltip 样式控制
    AAOptions *aaOptions = [[AAOptions alloc] init];

    // Chart 配置
    aaOptions.chart = [[AAChart alloc] init];
    aaOptions.chart.type = AAChartTypeColumn;
    aaOptions.chart.animation = @NO;
    aaOptions.chart.pinchType = @"xy";  // 🔥 启用双指缩放（iOS用pinchType）

    // Title 配置
    aaOptions.title = [[AATitle alloc] init];
    aaOptions.title.text = @"噪声频谱";

    // Subtitle 配置
    AASubtitle *subtitle = [[AASubtitle alloc] init];
    subtitle.text = @"陀螺仪噪声分析 (真实数据)";
    aaOptions.subtitle = subtitle;

    // X轴配置
    AAXAxis *xAxis = [[AAXAxis alloc] init];
    xAxis.categories = freqCategories;
    aaOptions.xAxis = xAxis;

    // Y轴配置
    AAYAxis *yAxis = [[AAYAxis alloc] init];
    yAxis.title = [[AAAxisTitle alloc] init];
    yAxis.title.text = @"噪声功率";
    yAxis.min = @0;
    aaOptions.yAxis = yAxis;

    // 🔧 Tooltip 配置：半透明黑色背景 + 2位小数
    AATooltip *tooltip = [[AATooltip alloc] init];
    tooltip.enabled = @YES;
    tooltip.useHTML = @YES;  // 🔥 关键：启用HTML格式
    tooltip.valueDecimals = @2;  // 保留2位小数
    tooltip.backgroundColor = @"rgba(0, 0, 0, 0.5)";  // 50%不透明度的黑色背景
    tooltip.borderColor = @"rgba(0, 0, 0, 0.5)";  // 边框同色
    tooltip.borderWidth = @1;
    tooltip.shadow = @NO;  // 无阴影
    tooltip.style = [[AAStyle alloc] init];
    tooltip.style.color = @"#ffffff";  // 白色文字
    aaOptions.tooltip = tooltip;

    // 创建数据系列 - 只添加有数据的系列
    NSMutableArray<AASeriesElement *> *series = [NSMutableArray array];

    if (rollNoise.count > 0) {
        AASeriesElement *rollSeries = [[AASeriesElement alloc] init];
        rollSeries.name = @"Roll";
        rollSeries.data = rollNoise;
        rollSeries.color = @"#FF6B6B";
        [series addObject:rollSeries];
    }

    if (pitchNoise.count > 0) {
        AASeriesElement *pitchSeries = [[AASeriesElement alloc] init];
        pitchSeries.name = @"Pitch";
        pitchSeries.data = pitchNoise;
        pitchSeries.color = @"#4ECDC4";
        [series addObject:pitchSeries];
    }

    if (yawNoise.count > 0) {
        AASeriesElement *yawSeries = [[AASeriesElement alloc] init];
        yawSeries.name = @"Yaw";
        yawSeries.data = yawNoise;
        yawSeries.color = @"#95E1D3";
        [series addObject:yawSeries];
    }

    aaOptions.series = series;

    NSLog(@"🔍 [噪声图] chartModel.series.count = %lu", (unsigned long)series.count);
    NSLog(@"🔍 [噪声图] 准备绘制图表...");

    // 🔥 使用 AAOptions 绘制图表
    [chartView aa_drawChartWithOptions:aaOptions];

    NSLog(@"✅ [噪声图] 图表绘制完成");
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
    // 🔥 更新进度到 100%
    _progressView.progress = 1.0;

    [_activityIndicator stopAnimating];
    _statusLabel.hidden = YES;
    _retryButton.hidden = YES;

    // 🔥 隐藏进度条
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _progressView.hidden = YES;
    });

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
 * 确保数组中所有值为非负数（截断负值到0）
 * @param array 原始数据数组
 * @return 处理后的数组，负值被截断为0
 */
- (NSArray<NSNumber *> *)ensureNonNegativeValues:(NSArray<NSNumber *> *)array {
    if (!array || array.count == 0) {
        return array;
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:array.count];
    for (NSNumber *num in array) {
        double value = num.doubleValue;
        // 截断负值到0
        [result addObject:@(MAX(0.0, value))];
    }

    return [result copy];
}

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

#pragma mark - 第3~5层：诊断 → 推荐 → 虚线叠加 → CLI命令

/**
 * 执行诊断→推荐→生成预测曲线→生成CLI
 * 在 configureSingleAxisChart 之前调用，预测曲线数据存到属性供图表使用
 * 耗时 <10ms
 */
- (void)runDiagnosisPipeline {
    // 检查是否至少有一轴特征
    if (!self.rollFeatures && !self.pitchFeatures && !self.yawFeatures) {
        NSLog(@"⚠️ [诊断] 无特征数据，跳过");
        return;
    }

    uint64_t startTime = mach_absolute_time();

    // ===== 第3层：诊断 =====
    NSArray<PIDResponseFeatures *> *features = @[
        self.rollFeatures ?: [[PIDResponseFeatures alloc] init],
        self.pitchFeatures ?: [[PIDResponseFeatures alloc] init],
        self.yawFeatures ?: [[PIDResponseFeatures alloc] init]
    ];
    PIDCurveDiagnostic *diagnostic = [PIDCurveDiagnostic diagnoseWithFeatures:features];
    NSLog(@"📊 [诊断评分] 综合=%.0f分", diagnostic.overallScore);

    // ===== 第2层：获取当前PID =====
    // 尝试从BBL header获取（如果有）
    PIDValues *currentPID = nil;
    // TODO: 从 BlackboxDecoder.logHeader.currentPIDValues 提取，当前先用默认值
    if (!currentPID) {
        currentPID = [[PIDValues alloc] init];
        currentPID.p = 42;
        currentPID.i = 85;
        currentPID.d = 35;
        currentPID.ff = 65;
    }

    // ===== 第4层：推荐 + 预测曲线 =====
    double sampleRate = _parsedData.sampleRate > 0 ? _parsedData.sampleRate : 8000.0;
    PIDRecommendationEngine *engine = [[PIDRecommendationEngine alloc] init];

    // 为每个有诊断的轴生成推荐
    NSArray<PIDAxisDiagnosis *> *diagnoses = diagnostic.axisDiagnoses;
    NSArray<PIDResponseResult *> *responses = @[_rollResponse, _pitchResponse, _yawResponse];

    NSMutableArray<PIDTuningResult *> *tuningResults = [NSMutableArray arrayWithCapacity:3];

    for (NSInteger i = 0; i < MIN(diagnoses.count, (NSUInteger)3); i++) {
        PIDAxisDiagnosis *axisDiag = diagnoses[i];
        PIDResponseResult *response = responses[i];

        // 获取该轴的当前PID
        PIDValues *axisPID = [self pidValuesForAxis:i fromCurrent:currentPID];

        // 获取当前阶跃响应曲线（低输入）
        NSArray<NSNumber *> *currentCurve = nil;
        if (response && response.stepResponse.count > 0) {
            // 使用加权平均计算低输入曲线（与图表一致）
            NSDictionary *masks = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:500.0];
            NSArray<NSNumber *> *lowMask = masks[@"low"];
            NSDictionary *tooLowMasks = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:20.0];
            NSArray<NSNumber *> *toolowMask = tooLowMasks[@"high"];

            NSMutableArray<NSNumber *> *respLowMask = [NSMutableArray array];
            for (NSInteger j = 0; j < MIN(lowMask.count, toolowMask.count); j++) {
                [respLowMask addObject:@([lowMask[j] doubleValue] * [toolowMask[j] doubleValue])];
            }

            currentCurve = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:response.stepResponse
                                                                        avgTime:response.avgTime
                                                                       dataMask:respLowMask
                                                                     vertRange:@[@(-1.5), @(3.5)]
                                                                      vertBins:1000
                                                                   sampleRate:sampleRate];
        }

        PIDTuningResult *result = [engine generateRecommendationWithDiagnosis:axisDiag
                                                                    currentPID:axisPID
                                                               currentResponse:currentCurve ?: @[]
                                                                   sampleRate:sampleRate];
        [tuningResults addObject:result];
    }

    self.rollTuningResult = tuningResults.count > 0 ? tuningResults[0] : nil;
    self.pitchTuningResult = tuningResults.count > 1 ? tuningResults[1] : nil;
    self.yawTuningResult = tuningResults.count > 2 ? tuningResults[2] : nil;

    // ===== 第5层：生成 CLI 命令 =====
    self.cliCommands = [PIDCLIGenerator generateCLICommands:self.rollTuningResult
                                                pitchResult:self.pitchTuningResult
                                                  yawResult:self.yawTuningResult
                                                  currentPID:currentPID.toDictionary
                                             firmwareVersion:0];  // TODO: 从BBL header获取

    NSLog(@"📋 [CLI命令]\n%@", self.cliCommands);

    // 性能统计
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    uint64_t endTime = mach_absolute_time();
    double elapsedMs = (double)(endTime - startTime) * info.numer / info.denom / 1e6;
    NSLog(@"⏱️ [诊断→推荐→CLI] 总耗时: %.1fms", elapsedMs);
}

/// 从统一PID提取单轴PID值
- (PIDValues *)pidValuesForAxis:(NSInteger)axisIndex fromCurrent:(PIDValues *)current {
    PIDValues *axisPID = [[PIDValues alloc] init];
    // TODO: 如果有每轴不同的PID，从configParameters提取
    axisPID.p = current.p;
    axisPID.i = current.i;
    axisPID.d = current.d;
    axisPID.ff = current.ff;
    return axisPID;
}

/// 将 NSNumber 数组转为 JS 数组字符串
- (NSString *)jsArrayFromNumbers:(NSArray<NSNumber *> *)numbers {
    NSMutableString *js = [NSMutableString stringWithString:@"["];
    for (NSInteger i = 0; i < numbers.count; i++) {
        if (i > 0) [js appendString:@","];
        [js appendFormat:@"%.4f", [numbers[i] doubleValue]];
    }
    [js appendString:@"]"];
    return [js copy];
}

/// 复制CLI命令到剪贴板
- (void)copyCLICommands {
    if (!self.cliCommands || self.cliCommands.length == 0) {
        [SVProgressHUD showErrorWithStatus:@"暂无CLI命令"];
        return;
    }

    [UIPasteboard generalPasteboard].string = self.cliCommands;
    [SVProgressHUD showSuccessWithStatus:@"CLI命令已复制"];
    NSLog(@"📋 CLI命令已复制到剪贴板 (%lu字符)", (unsigned long)self.cliCommands.length);
}

@end
