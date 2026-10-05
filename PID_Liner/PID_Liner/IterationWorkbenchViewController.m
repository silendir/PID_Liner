//
//  IterationWorkbenchViewController.m
//  PID_Liner
//
//  方案迭代工作台实现 (任务#28 阶段0.4c-1)
//

#import "IterationWorkbenchViewController.h"
#import "IterationChainManager.h"
#import "IterationChain.h"
#import "PIDTuningRecord.h"
#import "PIDAnalysisViewController.h"
#import "BBLImportService.h"
#import "PIDCSVParser.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SVProgressHUD/SVProgressHUD.h>

@interface IterationWorkbenchViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *chainId;
@property (nonatomic, strong, nullable) IterationChain *chain;

// 顶部链头
@property (nonatomic, strong) UILabel *schemeNameLabel;     // 方案名(Q2)
@property (nonatomic, strong) UILabel *iterationChipLabel;  // 第 N 轮 chip
@property (nonatomic, strong) UIButton *undoButton;         // ↩ 撤销本轮(Q7)

// 轮次链横滚
@property (nonatomic, strong) UIScrollView *iterationChainScroll;

// 响应图区(嵌入 PIDAnalysisViewController)
@property (nonatomic, strong) UIView *chartContainer;
@property (nonatomic, strong, nullable) PIDAnalysisViewController *currentAnalysisVC;

// 导入下一轮按钮
@property (nonatomic, strong) UIButton *importNextButton;

/// 导入下一轮暂存:用户选中的本轮 CSV(嵌入 VC 分析完自动 appendRecord 进链后,由回调清空)
@property (nonatomic, copy, nullable) NSString *pendingNextRoundCSVPath;

@end

@implementation IterationWorkbenchViewController

#pragma mark - Init

- (instancetype)initWithChainId:(NSString *)chainId {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _chainId = [chainId copy];
    }
    return self;
}

/// 🔖 外部桥接:以 CSV 为首飞轮建链 → 推工作台(craftName 从 CSV 头解析,空则工作台兜底"方案 xxx")
+ (void)presentNewChainForCSVPath:(NSString *)csvPath fromViewController:(UIViewController *)host {
    if (csvPath.length == 0 || host.navigationController == nil) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:csvPath]) return;

    NSString *craftName = [[PIDCSVParser parser] extractCraftNameFromCSV:csvPath] ?: @"";
    IterationChain *chain = [[IterationChainManager sharedManager]
        createChainWithCraftName:craftName
                         csvPath:csvPath
                    sessionIndex:0];
    IterationWorkbenchViewController *wb = [[self alloc] initWithChainId:chain.chainId];
    wb.hidesBottomBarWhenPushed = YES;
    [host.navigationController pushViewController:wb animated:YES];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupNav];
    [self setupUI];
    [self reloadAll];

    // 🔑 链变更即时刷新:入链/撤销/改名落盘后广播,chip/轮次链当场更新
    //(否则异步入链后页面停在旧状态,须退出重进——真机已踩"创建后1~3秒未开始")
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(chainDidUpdate:)
                                                 name:IterationChainDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:IterationChainDidUpdateNotification
                                                  object:nil];
}

/// 本链有记录变更 → 重读数据刷新链头/轮次链(不动嵌入的分析VC,零重分析)
- (void)chainDidUpdate:(NSNotification *)note {
    if (![note.userInfo[@"chainId"] isEqualToString:self.chainId]) return;
    [self reloadChainData];
    [self renderHeaderAndChain];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从子流程(导入下一轮)返回时刷新(0.4c-2 接 sheet 后由回调触发,此处兜底)
    [self reloadChainData];
    [self renderHeaderAndChain];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 🔑 离开本页(pop)即取消嵌入 VC 的后台分析——否则解析继续跑完、
    // 主线程配图卡 UI、存档/弹窗在死页面上照样触发(真机已踩)
    if (self.isMovingFromParentViewController) {
        [self.currentAnalysisVC cancelAnalysis];
    }
}

#pragma mark - Setup

- (void)setupNav {
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)setupUI {
    // 🔑 整体可滚动:让响应图容器有充足高度(屏幕宽×1.5),内容超出屏幕时垂直滚动
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scrollView];

    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];

    // 顶部链头
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:header];

    _schemeNameLabel = [[UILabel alloc] init];
    _schemeNameLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _schemeNameLabel.numberOfLines = 0;  // 🔑 长文件名折行,不和右侧按钮重叠(真机已踩)
    _schemeNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_schemeNameLabel];

    _iterationChipLabel = [[UILabel alloc] init];
    _iterationChipLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _iterationChipLabel.textAlignment = NSTextAlignmentCenter;
    _iterationChipLabel.textColor = [UIColor whiteColor];
    _iterationChipLabel.backgroundColor = [UIColor systemBlueColor];
    _iterationChipLabel.layer.cornerRadius = 10;
    _iterationChipLabel.layer.masksToBounds = YES;
    _iterationChipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_iterationChipLabel];

    _undoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_undoButton setTitle:@"↩ 撤销本轮" forState:UIControlStateNormal];
    _undoButton.titleLabel.font = [UIFont systemFontOfSize:13];
    _undoButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_undoButton addTarget:self action:@selector(undoLastRoundTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_undoButton];

    // 轮次链横滚
    UILabel *chainTitle = [[UILabel alloc] init];
    chainTitle.text = @"迭代轮次";
    chainTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    chainTitle.textColor = [UIColor secondaryLabelColor];
    chainTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:chainTitle];

    _iterationChainScroll = [[UIScrollView alloc] init];
    _iterationChainScroll.showsHorizontalScrollIndicator = NO;
    _iterationChainScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:_iterationChainScroll];

    // 响应图容器
    UILabel *chartTitle = [[UILabel alloc] init];
    chartTitle.text = @"响应曲线(当前轮)";
    chartTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    chartTitle.textColor = [UIColor secondaryLabelColor];
    chartTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:chartTitle];

    _chartContainer = [[UIView alloc] init];
    _chartContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _chartContainer.layer.cornerRadius = 10;
    _chartContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:_chartContainer];

    // 📋 推荐值出口按钮(分析完成才解禁;弹窗内含"导入下一轮返参"——顺序:先拿CLI飞,飞完再导入)
    _importNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_importNextButton setTitle:@"📋 导出推荐值" forState:UIControlStateNormal];
    [_importNextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _importNextButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _importNextButton.backgroundColor = [UIColor systemBlueColor];
    _importNextButton.layer.cornerRadius = 12;
    _importNextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_importNextButton addTarget:self action:@selector(importNextTapped) forControlEvents:UIControlEventTouchUpInside];
    [contentView addSubview:_importNextButton];

    [NSLayoutConstraint activateConstraints:@[
        // scrollView 铺满
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        // contentView 撑开 contentSize(宽度=scrollView 宽,高度由内容钉底)
        [contentView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],

        // 链头(两行:方案名折行独占首行;chip+撤销在第二行——名字长不再压撤销按钮)
        [header.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],

        [_schemeNameLabel.topAnchor constraintEqualToAnchor:header.topAnchor],
        [_schemeNameLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_schemeNameLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],

        [_iterationChipLabel.topAnchor constraintEqualToAnchor:_schemeNameLabel.bottomAnchor constant:6],
        [_iterationChipLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_iterationChipLabel.heightAnchor constraintEqualToConstant:22],

        [_undoButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_undoButton.centerYAnchor constraintEqualToAnchor:_iterationChipLabel.centerYAnchor],
        [header.bottomAnchor constraintEqualToAnchor:_iterationChipLabel.bottomAnchor],

        // 轮次链
        [chainTitle.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:16],
        [chainTitle.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [_iterationChainScroll.topAnchor constraintEqualToAnchor:chainTitle.bottomAnchor constant:6],
        [_iterationChainScroll.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [_iterationChainScroll.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
        [_iterationChainScroll.heightAnchor constraintEqualToConstant:56],

        // 响应图(标题随导入按钮下移重锚)
        [chartTitle.topAnchor constraintEqualToAnchor:_importNextButton.bottomAnchor constant:12],
        [chartTitle.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [_chartContainer.topAnchor constraintEqualToAnchor:chartTitle.bottomAnchor constant:6],
        [_chartContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [_chartContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        // 🔑 图表容器钉底撑 contentSize(导入按钮上移后由它承担)
        [_chartContainer.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-16],
        // 🔑 图表容器高度 = PIDAnalysisVC 完全摊开所需高度(3轴图+控件+tabBar≈1985pt)
        //   给足高度让内部 scrollView 不滚动,只剩外层工作台一套 scroll(消除双 scroll 嵌套)
        [_chartContainer.heightAnchor constraintEqualToConstant:[PIDAnalysisViewController fullyExpandedRequiredHeight]],

        // 🔑 导入按钮上移到轮次链与图表之间——原钉 1985pt 容器底部,进场看不见还得滚过
        //   整个 webview 才能点到(且中途与 webview 手势打架滚不动)
        [_importNextButton.topAnchor constraintEqualToAnchor:_iterationChainScroll.bottomAnchor constant:12],
        [_importNextButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [_importNextButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [_importNextButton.heightAnchor constraintEqualToConstant:46]
    ]];
}

#pragma mark - 数据加载与渲染

/// 重新拉链数据(持久层 → 内存)
- (void)reloadChainData {
    self.chain = [[IterationChainManager sharedManager] chainForId:self.chainId];
}

/// 全量刷新(数据 + 所有 UI;Q7 删除后调用)
- (void)reloadAll {
    [self reloadChainData];
    [self renderHeaderAndChain];
    [self renderLatestAnalysis];
}

/// 渲染链头 + 轮次链(基于当前 self.chain)
- (void)renderHeaderAndChain {
    if (!self.chain) {
        self.schemeNameLabel.text = @"(链不存在)";
        self.iterationChipLabel.text = @"";
        self.undoButton.enabled = NO;
        return;
    }
    // Q2 方案名:craftName 优先,空则 chainId 前 8 位占位(手动命名 UI 留后续)
    NSString *name = self.chain.craftName.length > 0
        ? self.chain.craftName
        : [NSString stringWithFormat:@"方案 %@", [self.chain.chainId substringToIndex:MIN(8, self.chain.chainId.length)]];
    self.schemeNameLabel.text = name;
    // 🔑 chip 显示"最新已存在轮"的轮号;旧用 currentIteration(=count+1,"下一轮"语义)
    // → 1 轮的链 chip 也显示"第 2 轮",与信息栏同族错位(真机已踩)
    NSInteger latestRound = self.chain.records.count > 0 ? self.chain.records.lastObject.iteration : 0;
    self.iterationChipLabel.text = latestRound > 0
        ? [NSString stringWithFormat:@"  第 %ld 轮  ", (long)latestRound]
        : @"  未开始  ";
    self.undoButton.enabled = self.chain.records.count > 0;

    [self buildIterationNodes];
}

/// 构建轮次链横滚节点(每轮一个:第N轮;当前轮高亮)
- (void)buildIterationNodes {
    for (UIView *v in [_iterationChainScroll subviews]) {
        [v removeFromSuperview];
    }
    NSUInteger count = self.chain.records.count;
    if (count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"还没有迭代轮次 · 点「导入下一轮返参」开始";
        empty.font = [UIFont systemFontOfSize:13];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [_iterationChainScroll addSubview:empty];
        [NSLayoutConstraint activateConstraints:@[
            [empty.leadingAnchor constraintEqualToAnchor:_iterationChainScroll.leadingAnchor constant:16],
            [empty.centerYAnchor constraintEqualToAnchor:_iterationChainScroll.centerYAnchor]
        ]];
        return;
    }

    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_iterationChainScroll addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:_iterationChainScroll.topAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_iterationChainScroll.leadingAnchor],
        [row.heightAnchor constraintEqualToAnchor:_iterationChainScroll.heightAnchor]
    ]];

    UIView *prev = nil;
    for (NSUInteger i = 0; i < count; i++) {
        PIDTuningRecord *record = self.chain.records[i];
        BOOL isLatest = (i == count - 1);

        UIView *node = [[UIView alloc] init];
        node.backgroundColor = isLatest ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
        node.layer.cornerRadius = 10;
        node.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:node];

        UILabel *nodeLabel = [[UILabel alloc] init];
        nodeLabel.text = [NSString stringWithFormat:@"第 %ld 轮", (long)record.iteration];
        nodeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        nodeLabel.textColor = isLatest ? [UIColor whiteColor] : [UIColor labelColor];
        nodeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [node addSubview:nodeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [node.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
            [node.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
            [node.leadingAnchor constraintEqualToAnchor:(prev ? prev.trailingAnchor : row.leadingAnchor)
                                              constant:prev ? 8 : 16],
            [nodeLabel.topAnchor constraintEqualToAnchor:node.topAnchor],
            [nodeLabel.bottomAnchor constraintEqualToAnchor:node.bottomAnchor],
            [nodeLabel.leadingAnchor constraintEqualToAnchor:node.leadingAnchor constant:12],
            [nodeLabel.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:-12]
        ]];
        if (i == count - 1) {
            [row.trailingAnchor constraintEqualToAnchor:node.trailingAnchor constant:16].active = YES;
        }
        prev = node;
    }
}

/// 渲染最新轮的响应图(嵌入 PIDAnalysisViewController 子VC)
- (void)renderLatestAnalysis {
    // 移除旧子 VC(先取消其后台分析,防换轮后旧分析仍在跑)
    if (self.currentAnalysisVC) {
        [self.currentAnalysisVC cancelAnalysis];
        [self.currentAnalysisVC willMoveToParentViewController:nil];
        [self.currentAnalysisVC.view removeFromSuperview];
        [self.currentAnalysisVC removeFromParentViewController];
        self.currentAnalysisVC = nil;
    }

    // 🔑 任务#28 0.4c-2 第3步:优先用「导入下一轮」暂存的 CSV;其次取链最新轮 CSV
    NSString *csvPath = self.pendingNextRoundCSVPath.length > 0
        ? self.pendingNextRoundCSVPath
        : [self latestCSVPath];
    if (csvPath.length == 0) {
        _importNextButton.enabled = YES;  // 无图可等,导入先行
        UILabel *hint = [[UILabel alloc] init];
        hint.text = @"暂无可分析的 CSV";
        hint.textColor = [UIColor secondaryLabelColor];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.translatesAutoresizingMaskIntoConstraints = NO;
        hint.tag = 9999;
        [self.chartContainer addSubview:hint];
        [NSLayoutConstraint activateConstraints:@[
            [hint.centerXAnchor constraintEqualToAnchor:self.chartContainer.centerXAnchor],
            [hint.centerYAnchor constraintEqualToAnchor:self.chartContainer.centerYAnchor]
        ]];
        return;
    }
    // 清空占位 hint
    for (UIView *v in self.chartContainer.subviews) {
        if (v.tag == 9999) [v removeFromSuperview];
    }

    // 🔖 结果缓存命中 → 收养现成分析(传递曲线model):免 40s 重解析+重分析,
    // 曲线/特征/推荐/CLI 原样可用;首轮无历史虚线=零重画,瞬间显示
    PIDAnalysisViewController *cached = [PIDAnalysisViewController cachedAnalysisForCSVPath:csvPath];
    if (cached) {
        [cached moveToParent:self containerView:self.chartContainer];
        [cached adoptForChainId:self.chainId];   // 绑链+入链(指纹幂等)+刷新迭代UI
        self.currentAnalysisVC = cached;
        _importNextButton.enabled = YES;
        [self reloadChainData];
        [self renderHeaderAndChain];
        NSLog(@"🔖 [工作台] 收养缓存分析,免重分析: %@", csvPath.lastPathComponent);
        return;
    }

    // 🔑 0.4c-1 嵌入单 CSV(isIter=NO 简化);0.4c-2 改 isIter=YES + chainId 画历史虚线
    PIDAnalysisViewController *vc = [[PIDAnalysisViewController alloc] initWithCSVFilePath:csvPath];
    // 🔑 0.4c-2 第1步:迭代模式绑定(画历史预测虚线)+ 隐藏内置导入按钮(用工作台自己的Session流程)
    [vc configureForIterationWithChainId:self.chainId];
    vc.hidesBuiltinImportButton = YES;
    [self addChildViewController:vc];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chartContainer addSubview:vc.view];
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.topAnchor constraintEqualToAnchor:self.chartContainer.topAnchor],
        [vc.view.leadingAnchor constraintEqualToAnchor:self.chartContainer.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:self.chartContainer.trailingAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:self.chartContainer.bottomAnchor]
    ]];
    [vc didMoveToParentViewController:self];

    // 🔑 任务#28 0.4c-2 第3步:VC 分析完(含 appendRecord 到链)回调,即时刷新链头/轮次链
    __weak typeof(self) weakSelf = self;
    vc.onAnalysisComplete = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // 链 records 已更新:刷链头(轮次号)+ 轮次链横滚(+1 节点)+ 清暂存 CSV
            // 🔑 不调 renderLatestAnalysis(会重建 VC + 重跑分析 = 死循环),只刷链头/轮次链
            [s reloadChainData];
            [s renderHeaderAndChain];
            s.pendingNextRoundCSVPath = nil;
            s.importNextButton.enabled = YES;  // 图表就绪,恢复导入入口
        });
    };
    self.currentAnalysisVC = vc;
    _importNextButton.enabled = NO;  // 🔑 分析期间禁用(图表未就绪时导入会打断/混淆状态)
    [vc startAnalysis];
}

/// 最新轮 CSV 路径(优先 latestRecord.csvFileName,回退 initialCSVPath;均在沙盒 Documents)
- (nullable NSString *)latestCSVPath {
    NSString *fileName = self.chain.records.lastObject.csvFileName;
    if (fileName.length == 0) {
        fileName = self.chain.initialCSVPath.lastPathComponent;
    }
    if (fileName.length == 0) return nil;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [docs stringByAppendingPathComponent:fileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

#pragma mark - Actions

/// ↩ 撤销最新轮(Q7:只删最新 + 硬删 + 传统确认框)
- (void)undoLastRoundTapped {
    PIDTuningRecord *latest = self.chain.records.lastObject;
    if (!latest) {
        [self showAlertWithTitle:@"无可撤销" message:@"当前链还没有迭代轮次"];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"撤销第 %ld 轮?", (long)latest.iteration]
                         message:@"将硬删除最新一轮记录,无法恢复。删错了可重新导入加回来。"
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认撤销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[IterationChainManager sharedManager] removeLastRecordFromChain:weakSelf.chain.chainId];
        // Q7:删除后全工作台原地重绘(链头/轮次链/响应图全部基于新 records 重算)
        [weakSelf reloadAll];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 📋 导出推荐值(迭代节奏:分析→拿CLI→换参飞→飞完才"导入下一轮返参")
/// 弹窗 = CLI 预览 + 复制 + 延后的导入入口(导入按钮藏在此弹窗里而非裸露在页面)
- (void)importNextTapped {
    NSString *cli = [self.currentAnalysisVC currentRecommendationCLI];
    NSString *message = cli.length > 0
        ? [NSString stringWithFormat:@"把下面的 CLI 粘贴到 Betaflight Configurator 执行并 save,\n用新参数飞行后再回来导入下一轮。\n\n%@", cli]
        : @"本轮未生成推荐值。\n常见原因:飞行片段太短没有有效机动数据(如解锁测试段),\n或老固件 CSV 缺少 PID 元数据。\n可删除本方案后用 ➕ 选时长足够的 Session 重建。";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"推荐值 · 下一轮"
                          message:message
                   preferredStyle:UIAlertControllerStyleAlert];
    if (cli.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"📋 复制推荐 CLI" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = cli;
            [SVProgressHUD showSuccessWithStatus:@"已复制,去 BF Configurator 粘贴"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 导入下一轮返参(飞完后)" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { [self presentImportSourceSheet]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 📥 导入下一轮返参 · 数据来源双选(在"导出推荐值"弹窗之后才到达此处)
/// 🔑 双来源:①外部 BBL 文件 ②App 内已有 CSV(蓝牙取数/示例已落沙盒,沙盒未暴露给"文件"App,
/// 文件选择器够不到——不接此入口蓝牙迭代闭环断链)
- (void)presentImportSourceSheet {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"导入下一轮返参"
                          message:nil
                   preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📁 导入 BBL 文件" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { [self presentBBLPickerForNextRound]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📡 选择 App 内已有记录(蓝牙下载等)" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { [self presentInternalCSVSelectionSheet]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.importNextButton;
        sheet.popoverPresentationController.sourceRect = self.importNextButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentBBLPickerForNextRound {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.data"]]
                                                                     asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

/// App 内已有 CSV 单选(按修改时间倒序,蓝牙最新下载排最前;同文件指纹守卫会拦重复入链)
- (void)presentInternalCSVSelectionSheet {
    NSString *docs = [BBLImportService documentsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSString *file in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (![[file.pathExtension lowercaseString] isEqualToString:@"csv"]) continue;
        NSString *path = [docs stringByAppendingPathComponent:file];
        NSDate *mtime = ((NSDictionary *)[fm attributesOfItemAtPath:path error:nil]).fileModificationDate ?: [NSDate distantPast];
        [items addObject:@{@"path": path, @"name": file, @"time": mtime}];
    }
    if (items.count == 0) {
        [self showAlertWithTitle:@"没有可选记录" message:@"App 内暂无 CSV(可先去「蓝牙取数」下载)"];
        return;
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"time"] compare:a[@"time"]];  // 新→旧
    }];

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"选择本轮飞行的记录"
                          message:@"蓝牙下载的飞行数据按时间排在最前"
                   preferredStyle:UIAlertControllerStyleActionSheet];
    static const NSInteger kMaxShown = 15;  // sheet 过长不可用,截断提示
    NSArray<NSDictionary *> *shown = [items subarrayWithRange:NSMakeRange(0, MIN(items.count, kMaxShown))];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    for (NSDictionary *item in shown) {
        // 🔑 短片段标注:CSV<300KB ≈ <3秒飞行(解锁测试),出不了曲线——选择器无法拦死(数据要保留),
        // 标注让用户自己跳过;误选也有"空分析不入链"守卫兜底
        NSString *path = item[@"path"];
        long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
        NSString *stubTag = (size > 0 && size < 300 * 1024) ? @" ⚠️疑似短片段" : @"";
        NSString *title = [NSString stringWithFormat:@"%@ (%@)%@", item[@"name"], [fmt stringFromDate:item[@"time"]], stubTag];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) { [self reloadAnalysisWithCSV:path]; }]];
    }
    if (items.count > kMaxShown) {
        // 无 Disabled 栚,用 Default 样式但点击无动作,仅作截断提示
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"还有 %ld 条更早的未列出…", (long)(items.count - kMaxShown)]
                                                  style:UIAlertActionStyleDefault handler:nil]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.importNextButton;
        sheet.popoverPresentationController.sourceRect = self.importNextButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 导入下一轮:UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    // 只接受 .bbl(CSV 不走此入口)
    NSString *ext = [sourceURL.pathExtension lowercaseString];
    if (![ext isEqualToString:@"bbl"]) {
        [self showAlertWithTitle:@"文件类型不支持" message:@"只支持导入 .bbl 飞行记录"];
        return;
    }

    // security-scoped 复制到沙盒 Documents(与独立分析导入流程一致)
    [sourceURL startAccessingSecurityScopedResource];
    NSString *destPath = [[BBLImportService documentsDirectory]
        stringByAppendingPathComponent:sourceURL.lastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtPath:sourceURL.path toPath:destPath error:&copyErr];
    [sourceURL stopAccessingSecurityScopedResource];

    if (!ok) {
        [self showAlertWithTitle:@"导入失败" message:copyErr.localizedDescription];
        return;
    }
    [self startConvertBBL:destPath];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 取消:留在当前轮,无操作
}

#pragma mark - 导入下一轮:BBL → CSV 转换

/// 后台批量转换所有 Session(带进度);单 Session 直进,多 Session 弹 sheet 单选
- (void)startConvertBBL:(NSString *)bblPath {
    [SVProgressHUD showWithStatus:@"转换 Session..."];
    self.importNextButton.enabled = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        NSArray<BBLImportCSVResult *> *results =
            [[BBLImportService shared] convertAllSessionsForBBL:bblPath
                                                         motorKV:nil
                                                        progress:^(NSInteger completed, NSInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) s = weakSelf;
                    if (!s) return;
                    [SVProgressHUD showWithStatus:[NSString stringWithFormat:@"转换 Session %ld / %ld",
                                                  (long)completed, (long)total]];
                });
            } error:&err];

        // 只保留成功转出 CSV 的 Session
        NSMutableArray<NSString *> *csvs = [NSMutableArray array];
        NSMutableArray<NSString *> *descs = [NSMutableArray array];
        for (BBLImportCSVResult *r in results) {
            if (r.csvPath) {
                [csvs addObject:r.csvPath];
                [descs addObject:r.sessionDescription.length > 0
                                  ? r.sessionDescription
                                  : [NSString stringWithFormat:@"Session %ld", (long)r.logIndex + 1]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [SVProgressHUD dismiss];
            s.importNextButton.enabled = YES;

            if (csvs.count == 0) {
                [s showAlertWithTitle:@"转换失败" message:err.localizedDescription ?: @"无可生成的 CSV"];
                return;
            }
            if (csvs.count == 1) {
                [s reloadAnalysisWithCSV:csvs.firstObject];
                return;
            }
            [s presentSessionSelectionSheetWithCSVs:csvs descriptions:descs];
        });
    });
}

#pragma mark - 导入下一轮:多 Session 单选 sheet

/// 多 Session:弹 actionSheet 单选一段飞行(只选一个;一条链只追加一段飞行作下一轮)
- (void)presentSessionSelectionSheetWithCSVs:(NSArray<NSString *> *)csvs
                                descriptions:(NSArray<NSString *> *)descs {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"选择本轮飞行的 Session"
                         message:@"一条链只追加一段飞行作为下一轮"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSUInteger i = 0; i < csvs.count; i++) {
        NSString *title = (i < descs.count) ? descs[i]
                                            : [NSString stringWithFormat:@"Session %lu", (unsigned long)(i + 1)];
        NSString *csvPath = csvs[i];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self reloadAnalysisWithCSV:csvPath];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad popover 锚定到导入按钮
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.importNextButton;
        sheet.popoverPresentationController.sourceRect = self.importNextButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 导入下一轮:嵌入新 CSV 分析

/// 把选中 CSV 作为下一轮嵌入 PIDAnalysisVC 分析
/// 🔑 不手动构造 record:嵌入的 VC(isIter=YES+chainId+craftName)分析完会自动 appendRecord 到当前链
/// (snapshot.predictedCurve 自动填 → 历史虚线有数据);VC 完成回调里刷新链头/轮次链
- (void)reloadAnalysisWithCSV:(NSString *)csvPath {
    if (csvPath.length == 0) return;
    self.pendingNextRoundCSVPath = csvPath;
    [self renderLatestAnalysis];
}

#pragma mark - 辅助

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
