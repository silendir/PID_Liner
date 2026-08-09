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
#import "IterationChainManager.h"
#import "BlackboxDecoder.h"
#import <objc/runtime.h>
#import <AAChartKit/AAChartKit.h>
#import <SVProgressHUD/SVProgressHUD.h>
#import <mach/mach_time.h>
#import <WebKit/WebKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <CommonCrypto/CommonDigest.h>

@interface PIDAnalysisViewController () <UITabBarControllerDelegate, UIDocumentPickerDelegate>

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

// 🔑 迭代闭环调参历史
@property (nonatomic, copy, nullable) NSString *currentCraftName;
@property (nonatomic, strong) NSArray<PIDTuningRecord *> *tuningHistory;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *hiddenIterationIndexes;  // 勾选控制：被隐藏的轮次索引
@property (nonatomic, assign) BOOL hideCurrentPrediction;  // 是否隐藏本轮预测
@property (nonatomic, assign) BOOL isIterationMode;        // 🔑 是否为迭代调参模式（仅从分析页内部导入新BBL时为YES）
@property (nonatomic, copy, nullable) NSString *currentChainId;  // 🔑 当前迭代链ID

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
        _tuningHistory = @[];
        _hiddenIterationIndexes = [NSMutableSet set];
        _hideCurrentPrediction = NO;
        _isIterationMode = NO;
        // 🔑 不自动加载调参历史 — 从历史页进入的是独立分析
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

    // 🔑 迭代信息栏（显示在顶部）
    UIView *infoBar = [[UIView alloc] init];
    infoBar.translatesAutoresizingMaskIntoConstraints = NO;
    infoBar.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    infoBar.layer.cornerRadius = 8;
    infoBar.hidden = YES;  // 初始隐藏，等有历史时显示
    [vc.view addSubview:infoBar];

    UILabel *infoLabel = [[UILabel alloc] init];
    infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    infoLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    infoLabel.textAlignment = NSTextAlignmentCenter;
    infoLabel.textColor = [UIColor secondaryLabelColor];
    [infoBar addSubview:infoLabel];

    // 🔑 "!" 说明按钮
    UIButton *infoHelpButton = [UIButton buttonWithType:UIButtonTypeInfoLight];
    infoHelpButton.translatesAutoresizingMaskIntoConstraints = NO;
    [infoHelpButton addTarget:self action:@selector(showRenameInfoAlert) forControlEvents:UIControlEventTouchUpInside];
    [infoBar addSubview:infoHelpButton];

    // 🔑 改名按钮（craftName旁边的编辑图标）
    UIButton *renameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    renameButton.translatesAutoresizingMaskIntoConstraints = NO;
    [renameButton setImage:[UIImage systemImageNamed:@"pencil"] forState:UIControlStateNormal];
    renameButton.tintColor = [UIColor secondaryLabelColor];
    renameButton.titleLabel.font = [UIFont systemFontOfSize:12];
    [renameButton addTarget:self action:@selector(renameCraftNameTapped) forControlEvents:UIControlEventTouchUpInside];
    [infoBar addSubview:renameButton];

    // 保存引用
    objc_setAssociatedObject(vc, "iterationInfoLabel", infoLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, "renameButton", renameButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        [infoBar.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:5],
        [infoBar.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:15],
        [infoBar.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-15],
        [infoBar.heightAnchor constraintEqualToConstant:32],
        [infoLabel.leadingAnchor constraintEqualToAnchor:infoBar.leadingAnchor constant:8],
        [infoLabel.centerYAnchor constraintEqualToAnchor:infoBar.centerYAnchor],
        [infoHelpButton.leadingAnchor constraintEqualToAnchor:infoLabel.trailingAnchor constant:4],
        [infoHelpButton.centerYAnchor constraintEqualToAnchor:infoBar.centerYAnchor],
        [renameButton.leadingAnchor constraintEqualToAnchor:infoHelpButton.trailingAnchor constant:4],
        [renameButton.trailingAnchor constraintEqualToAnchor:infoBar.trailingAnchor constant:-8],
        [renameButton.centerYAnchor constraintEqualToAnchor:infoBar.centerYAnchor],
        [renameButton.widthAnchor constraintEqualToConstant:28],
        [renameButton.heightAnchor constraintEqualToConstant:28],
    ]];

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

    // 🔑 虚线显隐控制容器（在图表和CLI按钮之间，初始隐藏）
    UIStackView *toggleContainer = [[UIStackView alloc] init];
    toggleContainer.translatesAutoresizingMaskIntoConstraints = NO;
    toggleContainer.axis = UILayoutConstraintAxisVertical;
    toggleContainer.spacing = 4;
    toggleContainer.alignment = UIStackViewAlignmentFill;
    toggleContainer.hidden = YES;
    [contentView addSubview:toggleContainer];
    objc_setAssociatedObject(vc, "toggleContainer", toggleContainer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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

    // 🔑 导入新一轮 BBL 按钮（在CLI按钮下方）
    UIButton *importNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    importNextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [importNextButton setTitle:@"📂 导入新一轮 BBL" forState:UIControlStateNormal];
    importNextButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    importNextButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [importNextButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    importNextButton.layer.cornerRadius = 10;
    importNextButton.clipsToBounds = YES;
    importNextButton.contentEdgeInsets = UIEdgeInsetsMake(10, 20, 10, 20);
    [importNextButton addTarget:self action:@selector(importNextBBLTapped) forControlEvents:UIControlEventTouchUpInside];
    [contentView addSubview:importNextButton];
    objc_setAssociatedObject(vc, "importNextButton", importNextButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [NSLayoutConstraint activateConstraints:@[
        [toggleContainer.topAnchor constraintEqualToAnchor:yawChartView.bottomAnchor constant:spacing],
        [toggleContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [toggleContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
        [cliCopyButton.topAnchor constraintEqualToAnchor:toggleContainer.bottomAnchor constant:spacing],
        [cliCopyButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [cliCopyButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
        [cliCopyButton.heightAnchor constraintEqualToConstant:48],
        [importNextButton.topAnchor constraintEqualToAnchor:cliCopyButton.bottomAnchor constant:12],
        [importNextButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20],
        [importNextButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20],
        [importNextButton.heightAnchor constraintEqualToConstant:44],
        [contentView.bottomAnchor constraintEqualToAnchor:importNextButton.bottomAnchor constant:spacing]
    ]];

    // 🔥 设置滑块容器约束（固定在顶部）
    [NSLayoutConstraint activateConstraints:@[
        [sliderContainer.topAnchor constraintEqualToAnchor:infoBar.bottomAnchor constant:5],
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

#pragma mark - 容器高度

/// 响应图完全摊开所需总高:与 createResponseViewController 布局常量同步(改那里必改这里)
+ (CGFloat)fullyExpandedRequiredHeight {
    CGFloat infoBarArea = 5 + 32;        // infoBar: top gap + 高度(hidden 仍占位)
    CGFloat sliderArea = 5 + 70;         // sliderContainer: top gap + 固定高度
    CGFloat scrollViewTopGap = 10;       // sliderContainer → scrollView
    CGFloat chartHeight = 540;           // 与 createResponseViewController 行 356 一致
    CGFloat spacing = 15;                // 与行 357 一致
    // contentView 内:top + 3 图(含图间间距) + yaw→toggle + toggle(hidden空) + cli + import + bottom
    CGFloat contentViewHeight = spacing                              // top
                              + 3 * chartHeight + 2 * spacing        // 3 图 + 图间 2 间距
                              + spacing                              // yaw → toggle
                              + 0                                    // toggleContainer(hidden 空)
                              + spacing                              // toggle → cli
                              + 48                                   // cliCopyButton
                              + 12                                   // cli → import
                              + 44                                   // importNextButton
                              + spacing;                             // contentView.bottom
    CGFloat tabBarHeight = 49;
    return infoBarArea + sliderArea + scrollViewTopGap + contentViewHeight + tabBarHeight;
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

    // 🔑 parsedData 已可用，尝试从CSV头恢复迭代链关联
    [self tryRestoreChainAssociation];

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

            // 🔑 保存本轮调参记录（仅执行一次，不在runDiagnosisPipeline里重复保存）
            {
                PIDValues *currentPID = [self currentPIDFromParsedData];
                if (currentPID) {
                    [self saveCurrentTuningRecord:currentPID];
                }
            }

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

    // 🔑 显示迭代信息栏（始终显示，让用户可以改名）
    [self updateIterationInfoBar];
    UILabel *infoLabel = objc_getAssociatedObject(_responseViewController, "iterationInfoLabel");
    UIView *infoBar = infoLabel.superview;
    if (infoBar) {
        infoBar.hidden = NO;
    }

    // 🔑 收敛检测 — 更新CLI按钮状态
    [self checkConvergenceAndUpdateCLIButton];

    // 🔑 更新虚线显隐勾选控件
    [self updateToggleControls];
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

    // 🔑 历史轮次虚线叠加（最多5轮，各色+各线型）
    NSArray<NSString *> *historyColors = @[@"#AF52DE", @"#FF2D55", @"#00C7BE", @"#FFCC00", @"#A2845E"];
    NSArray<NSString *> *historyDashStyles = @[@"Dot", @"ShortDash", @"LongDash", @"DashDot", @"ShortDashDot"];

    for (NSInteger h = 0; h < (NSInteger)self.tuningHistory.count && h < 5; h++) {
        PIDTuningRecord *record = self.tuningHistory[h];
        PIDAxisTuningSnapshot *snapshot = [record snapshotForAxis:axisIndex];
        if (!snapshot || !snapshot.predictedCurve || snapshot.predictedCurve.count < 10) continue;

        // 降采样历史预测曲线
        NSArray<NSNumber *> *histCurve = snapshot.predictedCurve;
        NSInteger hLen = histCurve.count;
        NSInteger hBlock = (hLen - 1) / (displayPoints - 1);
        if (hBlock < 1) hBlock = 1;
        NSMutableArray<NSNumber *> *histDisplay = [NSMutableArray arrayWithCapacity:displayPoints];
        for (NSInteger j = 0; j < displayPoints; j++) {
            if (j == 0) {
                [histDisplay addObject:@0];
            } else {
                NSInteger si = 1 + (j - 1) * hBlock;
                NSInteger ei = MIN(1 + j * hBlock, hLen);
                if (si < hLen && ei > si) {
                    double sum = 0; NSInteger cnt = 0;
                    for (NSInteger k = si; k < ei; k++) { sum += [histCurve[k] doubleValue]; cnt++; }
                    [histDisplay addObject:@(sum / cnt)];
                } else {
                    [histDisplay addObject:@([histCurve.lastObject doubleValue])];
                }
            }
        }

        AASeriesElement *histSeries = [[AASeriesElement alloc] init];
        histSeries.name = [NSString stringWithFormat:@"第%ld轮预测", (long)record.iteration];
        histSeries.data = histDisplay;
        histSeries.color = historyColors[h % 5];
        histSeries.lineWidth = @1.5;
        histSeries.dashStyle = historyDashStyles[h % 5];
        AAMarker *histMarker = [[AAMarker alloc] init];
        histMarker.radius = @0;
        histSeries.marker = histMarker;
        // 🔑 应用隐藏状态（toggle按钮控制的显隐）
        histSeries.visible = ![self.hiddenIterationIndexes containsObject:@(h)];
        [series addObject:histSeries];
    }

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
        // 🔑 应用隐藏状态（toggle按钮控制的显隐）
        predSeries.visible = !self.hideCurrentPrediction;
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
    // 优先从 BBL Header CSV 注释行获取实际PID值
    PIDValues *currentPID = [self currentPIDFromParsedData];

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
    NSInteger fwVersion = _parsedData.firmwareVersionCode;
    self.cliCommands = [PIDCLIGenerator generateCLICommands:self.rollTuningResult
                                                pitchResult:self.pitchTuningResult
                                                  yawResult:self.yawTuningResult
                                                  currentPID:currentPID.toDictionary
                                             firmwareVersion:fwVersion];

    NSLog(@"📋 [CLI命令]\n%@", self.cliCommands);

    // 性能统计
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    uint64_t endTime = mach_absolute_time();
    double elapsedMs = (double)(endTime - startTime) * info.numer / info.denom / 1e6;
    NSLog(@"⏱️ [诊断→推荐→CLI] 总耗时: %.1fms", elapsedMs);
}

#pragma mark - 迭代闭环调参历史

/// 🔧 尝试恢复迭代链关联（仅从CSV头的Chain ID标记恢复）
/// 🔑 只有通过"导入下一轮"生成的CSV才会带 # Chain ID: 标记
/// 首次BBL→CSV的CSV不带此标记，不会被错误关联
- (void)tryRestoreChainAssociation {
    if (self.currentChainId.length) return; // 已有链，不需要恢复
    if (!self.csvFilePath.length) return;

    // 🔑 唯一恢复方式：从CSV头读取 Chain ID（只有"导入下一轮"的CSV才有）
    if (self.parsedData.chainId.length) {
        NSString *csvChainId = self.parsedData.chainId;
        IterationChain *chain = [[IterationChainManager sharedManager] chainForId:csvChainId];
        if (chain) {
            self.currentChainId = csvChainId;
            self.tuningHistory = [chain.records copy];
            self.isIterationMode = YES;
            NSLog(@"🔄 [迭代链] CSV头恢复: 链%@ (%lu轮, 第%ld轮导入)",
                  chain.chainId, (unsigned long)chain.records.count,
                  (long)self.parsedData.chainIteration);
            return;
        }
    }

    NSLog(@"ℹ️ [迭代链] CSV无Chain标记，作为独立分析");
}

/// 加载调参历史（从迭代链中加载）
/// 🔑 仅在迭代模式下调用，从历史页进入时不会调用
- (void)loadTuningHistory {
    if (!self.csvFilePath.length) return;

    // 如果 csvData 已经设置了 craftName（从 CSV 注释行解析），直接使用
    if (self.csvData.craftName.length) {
        self.currentCraftName = self.csvData.craftName;
    }

    // 如果 csvData 还没有，尝试从 CSV 文件直接解析 craftName
    if (!self.currentCraftName.length) {
        PIDCSVParser *parser = [PIDCSVParser parser];
        NSString *craftName = [parser extractCraftNameFromCSV:self.csvFilePath];
        if (craftName.length) {
            self.currentCraftName = craftName;
        }
    }

    if (!self.currentCraftName.length) {
        NSLog(@"ℹ️ [迭代链] craftName为空，无历史记录");
        return;
    }

    // 🔑 从迭代链加载历史记录
    if (self.currentChainId.length) {
        IterationChain *chain = [[IterationChainManager sharedManager] chainForId:self.currentChainId];
        if (chain) {
            self.tuningHistory = [chain.records copy];
            NSLog(@"📂 [迭代链] 链%@ 已加载 %lu 轮记录",
                  chain.chainId, (unsigned long)self.tuningHistory.count);
            return;
        }
    }

    // 🔑 无 chainId 时不聚合历史（右路独立分析回归干净 1对1，不再按 craftName 兜底聚合）
    self.tuningHistory = @[];
}

/// 更新顶部信息栏
- (void)updateIterationInfoBar {
    UILabel *infoLabel = objc_getAssociatedObject(_responseViewController, "iterationInfoLabel");
    if (!infoLabel) return;

    // 🔑 非迭代模式：隐藏迭代信息栏
    if (!self.isIterationMode) {
        infoLabel.hidden = YES;
        return;
    }
    infoLabel.hidden = NO;

    NSInteger iteration = self.tuningHistory.count + 1;  // 本轮 = 已有轮数 + 1
    NSString *craftName = self.currentCraftName ?: @"未知飞机";

    if (self.tuningHistory.count == 0) {
        infoLabel.text = [NSString stringWithFormat:@"🔄 第1轮调参 · %@", craftName];
    } else {
        // 计算准确度（基于上一轮的预测 vs 本轮的实际）
        PIDTuningRecord *lastRecord = self.tuningHistory.lastObject;
        double accuracy = lastRecord.accuracy * 100;
        infoLabel.text = [NSString stringWithFormat:@"🔄 第%ld轮调参 · %@ · 预测准确度 %.0f%%",
                          (long)iteration, craftName, accuracy];
    }
}

/// 🔧 收敛检测 — 更新CLI按钮状态
- (void)checkConvergenceAndUpdateCLIButton {
    UIButton *cliButton = objc_getAssociatedObject(_responseViewController, "cliCopyButton");
    if (!cliButton) return;

    // 需要至少2轮才能判断收敛（第1轮没有上轮预测对比）
    if (self.tuningHistory.count < 1) return;

    PIDTuningRecord *currentRecord = self.tuningHistory.lastObject;
    if (!currentRecord) return;

    // 收敛条件：准确度 > 85%（即平均误差 < 15%）
    BOOL converged = currentRecord.accuracy >= 0.85;

    if (converged) {
        [cliButton setTitle:@"✅ 已收敛 — 复制最终CLI" forState:UIControlStateNormal];
        cliButton.backgroundColor = [UIColor systemGreenColor];

        // 更新信息栏
        UILabel *infoLabel = objc_getAssociatedObject(_responseViewController, "iterationInfoLabel");
        if (infoLabel) {
            NSString *craftName = self.currentCraftName ?: @"未知飞机";
            infoLabel.text = [NSString stringWithFormat:@"✅ 调参已收敛 · %@ · 准确度 %.0f%% — 建议停止微调",
                              craftName, currentRecord.accuracy * 100];
            infoLabel.textColor = [UIColor systemGreenColor];
        }

        NSLog(@"🎯 [收敛] 调参已收敛！准确度 %.0f%%", currentRecord.accuracy * 100);
    }
}

/// 🔧 更新虚线显隐勾选控件（非迭代模式时隐藏）
- (void)updateToggleControls {
    UIStackView *container = objc_getAssociatedObject(_responseViewController, "toggleContainer");
    if (!container) return;

    // 🔑 非迭代模式：隐藏勾选控件
    if (!self.isIterationMode) {
        container.hidden = YES;
        return;
    }
    container.hidden = NO;

    // 清空现有子视图
    for (UIView *sub in container.arrangedSubviews) {
        [container removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    // 颜色池
    NSArray<NSString *> *colors = @[@"#AF52DE", @"#FF2D55", @"#00C7BE", @"#FFCC00", @"#A2845E"];
    BOOL hasAnyToggle = NO;

    // 本轮预测开关
    if (self.rollTuningResult || self.pitchTuningResult || self.yawTuningResult) {
        UIButton *currentToggle = [self createToggleButtonWithTitle:@"● 本轮预测"
                                                            tag:-1
                                                           isOn:!self.hideCurrentPrediction];
        [currentToggle setTitleColor:[self colorFromHex:@"#34C759"] forState:UIControlStateSelected]; // 绿色
        [container addArrangedSubview:currentToggle];
        hasAnyToggle = YES;
    }

    // 历史轮次开关
    for (NSInteger h = 0; h < (NSInteger)self.tuningHistory.count && h < 5; h++) {
        PIDTuningRecord *record = self.tuningHistory[h];
        NSString *colorHex = colors[h % 5];
        NSString *title = [NSString stringWithFormat:@"● 第%ld轮预测 (%.0f%%)",
                           (long)record.iteration, record.accuracy * 100];
        BOOL isOn = ![self.hiddenIterationIndexes containsObject:@(h)];

        UIButton *toggle = [self createToggleButtonWithTitle:title
                                                        tag:(int)h
                                                       isOn:isOn];
        // 设置颜色标记
        [toggle setTitleColor:[self colorFromHex:colorHex] forState:UIControlStateSelected];
        [container addArrangedSubview:toggle];
        hasAnyToggle = YES;
    }

    container.hidden = !hasAnyToggle;
}

/// 创建勾选按钮
- (UIButton *)createToggleButtonWithTitle:(NSString *)title tag:(int)tag isOn:(BOOL)isOn {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = tag;
    btn.titleLabel.font = [UIFont systemFontOfSize:13];
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);

    // selected=YES → 有颜色标记 → 曲线显示
    // selected=NO  → 灰色文字 → 曲线隐藏
    [btn setTitle:title forState:UIControlStateSelected];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    btn.selected = isOn;

    [btn addTarget:self action:@selector(toggleButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

/// 勾选按钮回调 — 只切换 Highcharts series 可见性，不重算不重绘
- (void)toggleButtonTapped:(UIButton *)sender {
    sender.selected = !sender.selected;

    // 计算 series 索引：低输入(0) + 高输入(1) + 历史轮次(2..N) + 本轮预测(最后)
    // 每个 toggle 对应的 seriesIndex:
    //   历史轮次 h → seriesIndex = 2 + h（但有隐藏的历史轮次会跳过，所以需要动态计算）
    //
    // 更可靠的方式：用 Highcharts series name 匹配

    NSString *seriesName = nil;
    if (sender.tag == -1) {
        // 本轮预测
        self.hideCurrentPrediction = !sender.selected;
        seriesName = @"预测曲线 (CLI生效后)";
    } else {
        // 历史轮次
        NSInteger h = sender.tag;
        if (sender.selected) {
            [self.hiddenIterationIndexes removeObject:@(h)];
        } else {
            [self.hiddenIterationIndexes addObject:@(h)];
        }
        if (h < (NSInteger)self.tuningHistory.count) {
            seriesName = [NSString stringWithFormat:@"第%ld轮预测", (long)self.tuningHistory[h].iteration];
        }
    }

    if (!seriesName) return;

    // 遍历三个图表，通过 JS 隐藏/显示对应的 series
    static char const *const kChartViewKeys[] = {"aaChartView0", "aaChartView1", "aaChartView2"};
    NSString *jsAction = sender.selected ? @"show()" : @"hide()";

    for (NSInteger i = 0; i < 3; i++) {
        AAChartView *chartView = objc_getAssociatedObject(_responseViewController, kChartViewKeys[i]);
        if (!chartView) continue;

        NSString *js = [NSString stringWithFormat:
            @"var chart = Highcharts.charts[0];"
            @"if (chart) {"
            @"  for (var i = 0; i < chart.series.length; i++) {"
            @"    if (chart.series[i].name === '%@') {"
            @"      chart.series[i].%@;"
            @"      break;"
            @"    }"
            @"  }"
            @"}",
            seriesName, jsAction];

        [(WKWebView *)chartView evaluateJavaScript:js completionHandler:nil];
    }
}

/// HEX颜色转UIColor
- (UIColor *)colorFromHex:(NSString *)hex {
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner setScanLocation:1];
    [scanner scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

/// 🔧 保存本轮调参记录到历史文件（含指纹去重）
/// 🔑 仅在迭代模式（从分析页内部导入新BBL）时才保存，独立分析不保存
/// 🔧 确保迭代链存在并保存记录（所有分析完成后调用，防止切app丢数据）
- (void)saveCurrentTuningRecord:(PIDValues *)currentPID {
    if (!self.isIterationMode) {
        NSLog(@"ℹ️ [迭代链] 非迭代模式，跳过保存（独立分析）");
        return;
    }

    if (!self.currentCraftName.length) {
        NSLog(@"⚠️ [迭代链] craftName为空，跳过保存");
        return;
    }

    if (!self.currentChainId.length) {
        NSLog(@"⚠️ [迭代链] chainId为空，跳过保存");
        return;
    }

    [self saveCurrentRecordToChain:self.currentChainId currentPID:currentPID];
}

/// 🔧 构建并保存调参记录到指定迭代链
- (void)saveCurrentRecordToChain:(NSString *)chainId currentPID:(PIDValues *)currentPID {
    IterationChainManager *chainMgr = [IterationChainManager sharedManager];

    // 计算修正系数（对比上一轮预测 vs 本轮实际）
    double gainCorrection = 1.0;
    double dampingCorrection = 1.0;
    double freqCorrection = 1.0;
    double accuracy = 0.0;

    if (self.tuningHistory.count > 0) {
        PIDTuningRecord *lastRecord = self.tuningHistory.lastObject;
        [self computeCorrectionFactorsFromLastRecord:lastRecord
                                       gainCorrection:&gainCorrection
                                    dampingCorrection:&dampingCorrection
                                       freqCorrection:&freqCorrection
                                             accuracy:&accuracy];
    }

    // 构建记录
    PIDTuningRecord *record = [[PIDTuningRecord alloc] init];
    record.craftName = self.currentCraftName;
    record.iteration = 0; // 由 IterationChainManager.appendRecord 自动设置
    record.createdAt = [NSDate date];
    record.csvFileName = [self.csvFilePath lastPathComponent];
    record.cliCommands = self.cliCommands;
    record.csvFingerprint = [self csvFingerprintForFile:self.csvFilePath];
    record.flightTime = self.parsedData.flightTime;
    record.gainCorrection = gainCorrection;
    record.dampingCorrection = dampingCorrection;
    record.freqCorrection = freqCorrection;
    record.accuracy = accuracy;

    // 三轴快照
    record.rollSnapshot = [self buildSnapshotForAxis:0 currentPID:currentPID];
    record.pitchSnapshot = [self buildSnapshotForAxis:1 currentPID:currentPID];
    record.yawSnapshot = [self buildSnapshotForAxis:2 currentPID:currentPID];

    // 🔑 飞行时间排序校验后追加到迭代链
    [self checkFlightTimeAndAppendToChain:chainId record:record chainMgr:chainMgr];
}

/// 🔧 计算修正系数和准确度
- (void)computeCorrectionFactorsFromLastRecord:(PIDTuningRecord *)lastRecord
                               gainCorrection:(double *)outGain
                            dampingCorrection:(double *)outDamping
                               freqCorrection:(double *)outFreq
                                     accuracy:(double *)outAccuracy {
    double totalError = 0;
    int errorCount = 0;

    // 按轴对比预测 vs 实际
    for (NSInteger axis = 0; axis < 3; axis++) {
        PIDAxisTuningSnapshot *lastSnapshot = [lastRecord snapshotForAxis:axis];
        if (!lastSnapshot || !lastSnapshot.predictedFeatures) continue;

        PIDResponseFeatures *predicted = lastSnapshot.predictedFeatures;
        PIDResponseFeatures *actual = nil;
        switch (axis) {
            case 0: actual = self.rollFeatures; break;
            case 1: actual = self.pitchFeatures; break;
            case 2: actual = self.yawFeatures; break;
        }
        if (!actual) continue;

        // 超调量误差
        if (predicted.overshoot > 0.001) {
            double error = fabs(actual.overshoot - predicted.overshoot) / predicted.overshoot;
            totalError += MIN(error, 1.0);
            errorCount++;
        }

        // 上升时间误差
        if (predicted.riseTime > 1.0) {
            double error = fabs(actual.riseTime - predicted.riseTime) / predicted.riseTime;
            totalError += MIN(error, 1.0);
            errorCount++;
        }

        // 建立时间误差
        if (predicted.settlingTime > 1.0) {
            double error = fabs(actual.settlingTime - predicted.settlingTime) / predicted.settlingTime;
            totalError += MIN(error, 1.0);
            errorCount++;
        }
    }

    // 准确度 = 1 - 平均误差
    *outAccuracy = errorCount > 0 ? (1.0 - totalError / errorCount) : 0.0;

    // 修正系数：基于上一轮的修正系数和本轮误差调整
    // 简化模型：如果预测偏高（误差>0），降低修正系数
    double errorRatio = errorCount > 0 ? totalError / errorCount : 0;
    *outGain = lastRecord.gainCorrection * (1.0 - errorRatio * 0.3);
    *outDamping = lastRecord.dampingCorrection * (1.0 - errorRatio * 0.3);
    *outFreq = lastRecord.freqCorrection * (1.0 - errorRatio * 0.3);

    // 限制在合理范围 [0.3, 2.0]
    *outGain = MAX(0.3, MIN(2.0, *outGain));
    *outDamping = MAX(0.3, MIN(2.0, *outDamping));
    *outFreq = MAX(0.3, MIN(2.0, *outFreq));
}

/// 🔧 构建单轴快照
- (PIDAxisTuningSnapshot *)buildSnapshotForAxis:(NSInteger)axisIndex currentPID:(PIDValues *)currentPID {
    PIDAxisTuningSnapshot *snapshot = [[PIDAxisTuningSnapshot alloc] init];
    snapshot.originalPID = [self pidValuesForAxis:axisIndex fromCurrent:currentPID];

    // 实际特征
    PIDResponseFeatures *actualFeatures = nil;
    PIDTuningResult *tuningResult = nil;
    switch (axisIndex) {
        case 0: actualFeatures = self.rollFeatures; tuningResult = self.rollTuningResult; break;
        case 1: actualFeatures = self.pitchFeatures; tuningResult = self.pitchTuningResult; break;
        case 2: actualFeatures = self.yawFeatures; tuningResult = self.yawTuningResult; break;
    }
    snapshot.actualFeatures = actualFeatures;

    if (tuningResult) {
        snapshot.recommendedPID = tuningResult.recommendedPID;
        snapshot.predictedCurve = tuningResult.predictedCurve;
        // 预测特征
        PIDResponseFeatures *predFeatures = [[PIDResponseFeatures alloc] init];
        predFeatures.overshoot = tuningResult.predictedOvershoot;
        predFeatures.riseTime = tuningResult.predictedRiseTime;
        snapshot.predictedFeatures = predFeatures;
    }

    return snapshot;
}

/// 从统一PID提取单轴PID值
- (PIDValues *)pidValuesForAxis:(NSInteger)axisIndex fromCurrent:(PIDValues *)current {
    // 优先从 BBL Header 每轴配置获取
    NSArray<NSString *> *axisNames = @[@"roll", @"pitch", @"yaw"];
    if (axisIndex >= 0 && axisIndex < axisNames.count) {
        NSString *axisName = axisNames[axisIndex];
        NSDictionary *axisPID = _parsedData.currentPIDFromHeader[axisName];
        if (axisPID) {
            PIDValues *v = [[PIDValues alloc] init];
            v.p = [axisPID[@"p"] doubleValue];
            v.i = [axisPID[@"i"] doubleValue];
            v.d = [axisPID[@"d"] doubleValue];
            v.ff = [axisPID[@"ff"] doubleValue];
            return v;
        }
    }
    // 降级使用传入的默认值
    return current;
}

/// 从 _parsedData.currentPIDFromHeader 构建 Roll 轴 PIDValues（用于推荐引擎默认输入）
- (PIDValues *)currentPIDFromParsedData {
    NSDictionary *pidConfig = _parsedData.currentPIDFromHeader;
    if (pidConfig && pidConfig.count > 0) {
        // 取 roll 轴作为默认（推荐引擎会按轴分别获取）
        NSDictionary *rollPID = pidConfig[@"roll"];
        if (rollPID) {
            PIDValues *v = [[PIDValues alloc] init];
            v.p = [rollPID[@"p"] doubleValue];
            v.i = [rollPID[@"i"] doubleValue];
            v.d = [rollPID[@"d"] doubleValue];
            v.ff = [rollPID[@"ff"] doubleValue];
            NSLog(@"🔧 [PID] 使用BBL Header实际PID: p=%.1f i=%.1f d=%.1f ff=%.1f", v.p, v.i, v.d, v.ff);
            return v;
        }
    }
    // 降级默认值
    PIDValues *v = [[PIDValues alloc] init];
    v.p = 42; v.i = 85; v.d = 35; v.ff = 65;
    NSLog(@"⚠️ [PID] 无BBL Header PID数据，使用降级默认值");
    return v;
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

#pragma mark - 导入新一轮 BBL

/// 点击"导入新一轮 BBL"按钮
- (void)importNextBBLTapped {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                              inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

/// UIDocumentPicker 回调 — 选中文件后自动转换并跳转
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSURL *selectedURL = urls.firstObject;
    NSString *extension = selectedURL.pathExtension.lowercaseString;

    // 只接受 .bbl 文件
    if (![extension isEqualToString:@"bbl"]) {
        [SVProgressHUD showErrorWithStatus:@"请选择 .bbl 文件"];
        return;
    }

    // 将文件拷贝到 Documents 目录（picker 给的是临时路径）
    NSString *docsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *fileName = selectedURL.lastPathComponent;
    NSString *destPath = [docsDir stringByAppendingPathComponent:fileName];

    // 如果已存在同名文件，加序号避免覆盖
    if ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
        NSString *baseName = [fileName stringByDeletingPathExtension];
        NSString *ext = [fileName pathExtension];
        NSInteger idx = 1;
        do {
            destPath = [docsDir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@_%ld.%@", baseName, (long)idx, ext]];
            idx++;
        } while ([[NSFileManager defaultManager] fileExistsAtPath:destPath]);
    }

    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:selectedURL.path toPath:destPath error:&copyError];
    if (copyError) {
        [SVProgressHUD showErrorWithStatus:@"文件导入失败"];
        NSLog(@"❌ [导入BBL] 复制失败: %@", copyError.localizedDescription);
        return;
    }

    NSLog(@"✅ [导入BBL] 文件已拷贝: %@", destPath);
    [SVProgressHUD showWithStatus:@"正在转换 BBL..."];

    // 后台线程：列出 Session → 转换第一个 Session → 注入 craftName
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
        decoder.outputDirectory = docsDir;

        NSArray<BBLSessionInfo *> *sessions = [decoder listLogs:destPath];
        if (sessions.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [SVProgressHUD showErrorWithStatus:@"BBL文件无有效Session"];
            });
            return;
        }

        // 转换第一个 Session
        BBLSessionInfo *firstSession = sessions.firstObject;
        int result = [decoder decodeFlightLog:destPath logIndex:firstSession.logIndex];

        if (result != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [SVProgressHUD showErrorWithStatus:@"BBL转换失败"];
            });
            return;
        }

        // 重命名输出文件（解码器生成的文件名 → 带时间戳的文件名）
        NSString *originalFileName = [NSString stringWithFormat:@"%@.%02d.csv",
            [[destPath lastPathComponent] stringByDeletingPathExtension], firstSession.logIndex + 1];
        NSString *originalPath = [docsDir stringByAppendingPathComponent:originalFileName];

        // 生成带时间戳的新文件名
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyyMMdd_HHmmss";
        NSString *timestamp = [fmt stringFromDate:[NSDate date]];
        NSString *baseName = [[destPath lastPathComponent] stringByDeletingPathExtension];
        NSString *csvFileName = [NSString stringWithFormat:@"%@_%@_session1.csv", baseName, timestamp];
        NSString *outputPath = [docsDir stringByAppendingPathComponent:csvFileName];

        // 如果目标已存在先删除
        if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        }

        NSString *finalPath = originalPath;
        if ([[NSFileManager defaultManager] fileExistsAtPath:originalPath]) {
            NSError *renameErr = nil;
            if ([[NSFileManager defaultManager] moveItemAtPath:originalPath toPath:outputPath error:&renameErr]) {
                finalPath = outputPath;
            } else {
                NSLog(@"⚠️ [导入BBL] 重命名失败，使用原路径: %@", renameErr.localizedDescription);
            }
        }

        // 注入 craftName + flight time
        NSString *craftName = decoder.logHeader.craftName;
        int64_t flightTimeUs = decoder.logHeader.startDatetimeUs;
        [self injectFlightDataToCSV:finalPath craftName:craftName flightTimeUs:flightTimeUs];

        // 计算新CSV指纹
        NSString *newFingerprint = [self csvFingerprintForFile:finalPath];

        // 检查是否与上一轮数据完全相同
        BOOL isDuplicateData = NO;
        NSString *duplicateRoundInfo = nil;
        // 🔑 指纹比对改用当前迭代链的最后一轮（不再按 craftName 跨飞机聚合）
        if (self.currentChainId.length) {
            IterationChain *chain = [[IterationChainManager sharedManager] chainForId:self.currentChainId];
            PIDTuningRecord *latestRecord = chain.records.lastObject;
            if (latestRecord && latestRecord.csvFingerprint.length && newFingerprint.length) {
                if ([latestRecord.csvFingerprint isEqualToString:newFingerprint]) {
                    isDuplicateData = YES;
                    duplicateRoundInfo = [NSString stringWithFormat:@"第%ld轮", (long)latestRecord.iteration];
                }
            }
        }

        // 清理导入的 BBL 临时文件
        [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];

        // 主线程：指纹校验 → 跳转
        dispatch_async(dispatch_get_main_queue(), ^{
            [SVProgressHUD dismiss];

            if (isDuplicateData) {
                // ⚠️ 弹窗警告
                NSString *msg = [NSString stringWithFormat:
                    @"检测到本轮数据与%@完全相同。\n您是否已按照上轮CLI命令修改PID并重新飞行？",
                    duplicateRoundInfo];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"⚠️ 数据重复"
                    message:msg
                    preferredStyle:UIAlertControllerStyleAlert];

                [alert addAction:[UIAlertAction actionWithTitle:@"重新选文件"
                    style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                        // 取消，重新弹出文件选择器
                        [self importNextBBLTapped];
                    }]];

                [alert addAction:[UIAlertAction actionWithTitle:@"继续分析"
                    style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                        // 用户确认继续
                        [self reloadWithNewCSVPath:finalPath];
                    }]];

                [self presentViewController:alert animated:YES completion:nil];
            } else {
                // 数据不同，直接跳转
                [self reloadWithNewCSVPath:finalPath];
            }
        });
    });
}

/// 🔧 在当前页面加载新一轮CSV数据（不创建新页面实例）
/// 🔑 为当前分析创建/关联迭代链，刷新界面显示新数据
- (void)reloadWithNewCSVPath:(NSString *)csvPath {
    // 🔑 确保迭代链存在
    if (!self.currentChainId.length) {
        // 当前页面没有链（首次分析），为当前CSV创建一条新链作为第1轮
        NSString *craftName = self.currentCraftName ?: self.parsedData.craftName;
        if (craftName.length) {
            IterationChain *newChain = [[IterationChainManager sharedManager]
                createChainWithCraftName:craftName
                                 csvPath:self.csvFilePath
                            sessionIndex:0];
            self.currentChainId = newChain.chainId;

            // 如果当前分析有结果，先保存为第1轮
            if (self.rollTuningResult) {
                PIDValues *currentPID = [self currentPIDFromParsedData];
                if (currentPID) {
                    [self saveCurrentRecordToChain:self.currentChainId currentPID:currentPID];
                }
            }

            NSLog(@"🔗 [迭代链] 首次迭代创建链: %@", self.currentChainId);
        }
    }

    // 🔑 补注链标记（首次迭代时 injectFlightDataToCSV 尚无 chainId，此处补救）
    [self injectChainMarkersToCSV:csvPath];

    // 🔑 切换到迭代模式
    self.isIterationMode = YES;

    // 🔑 更新CSV路径，重新解析和分析
    self.csvFilePath = csvPath;

    // 重新加载调参历史（链已更新）
    [self loadTuningHistory];

    // 重新解析CSV并分析
    [self parseAndAnalyze];

    NSLog(@"✅ [导入BBL] 当前页面加载新一轮数据（链%@）: %@", self.currentChainId, csvPath.lastPathComponent);
}

/// 文件选择取消
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 用户取消，不做任何事
}

/// 在CSV头部注入 craftName + flight time 注释行
- (void)injectFlightDataToCSV:(NSString *)csvPath craftName:(NSString *)craftName flightTimeUs:(int64_t)flightTimeUs {
    if (!csvPath) return;

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:csvPath encoding:NSUTF8StringEncoding error:&error];
    if (error || !content) return;

    // 避免重复注入
    if ([content containsString:@"# Craft name:"]) return;

    NSMutableString *header = [NSMutableString string];
    if (flightTimeUs > 0) {
        [header appendFormat:@"# Flight time:%lld\n", flightTimeUs];
    }
    if (craftName.length) {
        [header appendFormat:@"# Craft name:%@\n", craftName];
    }

    // 🔑 注入迭代链标记（如果当前有链ID）
    if (self.currentChainId.length) {
        IterationChain *chain = [[IterationChainManager sharedManager] chainForId:self.currentChainId];
        NSInteger iteration = chain ? chain.currentIteration : 1;
        [header appendFormat:@"# Chain ID:%@\n", self.currentChainId];
        [header appendFormat:@"# Chain Iteration:%ld\n", (long)iteration];
    }

    if (header.length == 0) return;
    NSString *newContent = [header stringByAppendingString:content];
    [newContent writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// 🔑 补注链标记到CSV（仅在链已创建但CSV缺少标记时使用）
- (void)injectChainMarkersToCSV:(NSString *)csvPath {
    if (!csvPath || !self.currentChainId.length) return;

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:csvPath encoding:NSUTF8StringEncoding error:&error];
    if (error || !content) return;

    // 已有链标记，跳过
    if ([content containsString:@"# Chain ID:"]) return;

    IterationChain *chain = [[IterationChainManager sharedManager] chainForId:self.currentChainId];
    NSInteger iteration = chain ? chain.currentIteration : 1;

    NSString *chainMarkers = [NSString stringWithFormat:@"# Chain ID:%@\n# Chain Iteration:%ld\n",
        self.currentChainId, (long)iteration];
    NSString *newContent = [chainMarkers stringByAppendingString:content];
    [newContent writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/// 计算CSV文件指纹（数据点数 + 前100行数据哈希）
- (NSString *)csvFingerprintForFile:(NSString *)csvPath {
    if (!csvPath) return nil;

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:csvPath encoding:NSUTF8StringEncoding error:&error];
    if (error || !content.length) return nil;

    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    // 统计有效数据行（跳过注释行和空行）
    NSInteger dataLineCount = 0;
    NSMutableString *sampleData = [NSMutableString string];
    NSInteger sampleLimit = 100;

    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;

        dataLineCount++;
        if (dataLineCount <= sampleLimit) {
            [sampleData appendString:trimmed];
            [sampleData appendString:@"\n"];
        }
    }

    // 指纹格式: "数据行数|sampleData的hash"
    NSString *hash = [self md5HashOfString:sampleData];
    return [NSString stringWithFormat:@"%ld|%@", (long)dataLineCount, hash];
}

/// MD5 哈希（用于指纹计算）
- (NSString *)md5HashOfString:(NSString *)string {
    if (!string) return @"";
    const char *cStr = [string UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}

#pragma mark - 改名 & 说明

/// "!" 按钮弹出改名说明
- (void)showRenameInfoAlert {
    NSString *message = @"飞机名称(craftName)用于匹配同一架飞机的调参历史。\n\n"
        @"如果两次飞行的 craftName 不同（在 Betaflight 中修改过名称），"
        @"系统会将其视为不同飞机，调参记录无法自动关联。\n\n"
        @"点击旁边的 ✏️ 按钮可以手动修改名称，将当前分析归入已有的调参档案。"
        @"改名后系统会重新加载历史记录并更新迭代轮次。";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"关于飞机名称"
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 改名按钮点击 — 弹出输入框修改 craftName
- (void)renameCraftNameTapped {
    NSString *currentName = self.currentCraftName ?: @"";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"修改飞机名称"
        message:@"改名后系统将重新匹配调参历史，迭代轮次会相应变化。"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentName;
        textField.placeholder = @"输入飞机名称";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSString *newName = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (newName.length == 0) {
            [SVProgressHUD showErrorWithStatus:@"名称不能为空"];
            return;
        }
        if ([newName isEqualToString:self.currentCraftName]) {
            return; // 没变化
        }

        NSLog(@"✏️ [改名] %@ → %@", self.currentCraftName, newName);
        self.currentCraftName = newName;

        // 重新加载历史
        [self loadTuningHistory];

        // 刷新 UI
        [self updateIterationInfoBar];
        [self updateToggleControls];

        // 重新渲染图表（历史虚线可能变了）
        if (self.parsedData) {
            [self configureResponseCharts];
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 飞行时间排序校验

/// 🔧 飞行时间排序校验后追加到迭代链
- (void)checkFlightTimeAndAppendToChain:(NSString *)chainId
                                  record:(PIDTuningRecord *)record
                               chainMgr:(IterationChainManager *)chainMgr {
    // 只在有历史记录时检查
    if (self.tuningHistory.count == 0 || !record.flightTime) {
        [chainMgr appendRecord:record toChain:chainId];
        [self reloadChainHistory:chainId];
        return;
    }

    PIDTuningRecord *lastRecord = self.tuningHistory.lastObject;
    if (!lastRecord.flightTime) {
        [chainMgr appendRecord:record toChain:chainId];
        [self reloadChainHistory:chainId];
        return;
    }

    // 新记录的飞行时间比上一轮更早 → 弹窗提醒（不阻止）
    if ([record.flightTime compare:lastRecord.flightTime] == NSOrderedAscending) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        NSString *lastTime = [fmt stringFromDate:lastRecord.flightTime];
        NSString *newTime = [fmt stringFromDate:record.flightTime];

        NSString *msg = [NSString stringWithFormat:
            @"本轮飞行时间 (%@) 早于上一轮 (%@)。\n\n"
            @"可能是时间戳未录入或错误。确定要加入迭代链吗？",
            newTime, lastTime];

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"⚠️ 飞行时间异常"
            message:msg
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消加入" style:UIAlertActionStyleCancel handler:nil]];

        [alert addAction:[UIAlertAction actionWithTitle:@"确定加入" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [chainMgr appendRecord:record toChain:chainId];
            [self reloadChainHistory:chainId];
        }]];

        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // 时间正常，直接追加
        [chainMgr appendRecord:record toChain:chainId];
        [self reloadChainHistory:chainId];
    }
}

/// 重新加载迭代链历史到 tuningHistory
- (void)reloadChainHistory:(NSString *)chainId {
    IterationChain *chain = [[IterationChainManager sharedManager] chainForId:chainId];
    if (chain) {
        self.tuningHistory = [chain.records copy];
    }
    [self updateIterationInfoBar];
    [self updateToggleControls];
}

@end
