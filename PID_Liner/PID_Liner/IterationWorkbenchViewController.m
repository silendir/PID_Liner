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

@interface IterationWorkbenchViewController ()
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

// 推荐区 / CLI 区占位(0.4c-2 接)
@property (nonatomic, strong) UILabel *placeholderLabel;
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

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupNav];
    [self setupUI];
    [self reloadAll];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从子流程(导入下一轮)返回时刷新(0.4c-2 接 sheet 后由回调触发,此处兜底)
    [self reloadChainData];
    [self renderHeaderAndChain];
}

#pragma mark - Setup

- (void)setupNav {
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)setupUI {
    // 顶部链头
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];

    _schemeNameLabel = [[UILabel alloc] init];
    _schemeNameLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
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
    [self.view addSubview:chainTitle];

    _iterationChainScroll = [[UIScrollView alloc] init];
    _iterationChainScroll.showsHorizontalScrollIndicator = NO;
    _iterationChainScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_iterationChainScroll];

    // 响应图容器
    UILabel *chartTitle = [[UILabel alloc] init];
    chartTitle.text = @"响应曲线(当前轮)";
    chartTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    chartTitle.textColor = [UIColor secondaryLabelColor];
    chartTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:chartTitle];

    _chartContainer = [[UIView alloc] init];
    _chartContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _chartContainer.layer.cornerRadius = 10;
    _chartContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_chartContainer];

    // 导入下一轮按钮
    _importNextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_importNextButton setTitle:@"📥 导入下一轮返参" forState:UIControlStateNormal];
    [_importNextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _importNextButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _importNextButton.backgroundColor = [UIColor systemBlueColor];
    _importNextButton.layer.cornerRadius = 12;
    _importNextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_importNextButton addTarget:self action:@selector(importNextTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_importNextButton];

    // 推荐区 / CLI 区占位
    _placeholderLabel = [[UILabel alloc] init];
    _placeholderLabel.text = @"🔬 推荐区 + 📋 CLI 区\n(0.4c-2 接:PIDRecommendationEngine + BFSliderMapper 滑块/真值 toggle)";
    _placeholderLabel.font = [UIFont systemFontOfSize:12];
    _placeholderLabel.textColor = [UIColor tertiaryLabelColor];
    _placeholderLabel.numberOfLines = 0;
    _placeholderLabel.textAlignment = NSTextAlignmentCenter;
    _placeholderLabel.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    _placeholderLabel.layer.cornerRadius = 8;
    _placeholderLabel.clipsToBounds = YES;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_placeholderLabel];

    [NSLayoutConstraint activateConstraints:@[
        // 链头
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [header.heightAnchor constraintEqualToConstant:34],

        [_schemeNameLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_schemeNameLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [_iterationChipLabel.leadingAnchor constraintEqualToAnchor:_schemeNameLabel.trailingAnchor constant:10],
        [_iterationChipLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_iterationChipLabel.heightAnchor constraintEqualToConstant:22],

        [_undoButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_undoButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        // 轮次链
        [chainTitle.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:16],
        [chainTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],

        [_iterationChainScroll.topAnchor constraintEqualToAnchor:chainTitle.bottomAnchor constant:6],
        [_iterationChainScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_iterationChainScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_iterationChainScroll.heightAnchor constraintEqualToConstant:56],

        // 响应图
        [chartTitle.topAnchor constraintEqualToAnchor:_iterationChainScroll.bottomAnchor constant:14],
        [chartTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],

        [_chartContainer.topAnchor constraintEqualToAnchor:chartTitle.bottomAnchor constant:6],
        [_chartContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_chartContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_chartContainer.heightAnchor constraintEqualToConstant:240],

        // 推荐区占位
        [_placeholderLabel.topAnchor constraintEqualToAnchor:_chartContainer.bottomAnchor constant:12],
        [_placeholderLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_placeholderLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_placeholderLabel.heightAnchor constraintEqualToConstant:60],

        // 导入按钮
        [_importNextButton.topAnchor constraintEqualToAnchor:_placeholderLabel.bottomAnchor constant:14],
        [_importNextButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_importNextButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
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
    self.iterationChipLabel.text = [NSString stringWithFormat:@"  第 %ld 轮  ", (long)self.chain.currentIteration];
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
    // 移除旧子 VC
    if (self.currentAnalysisVC) {
        [self.currentAnalysisVC willMoveToParentViewController:nil];
        [self.currentAnalysisVC.view removeFromSuperview];
        [self.currentAnalysisVC removeFromParentViewController];
        self.currentAnalysisVC = nil;
    }

    NSString *csvPath = [self latestCSVPath];
    if (csvPath.length == 0) {
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

    // 🔑 0.4c-1 嵌入单 CSV(isIter=NO 简化);0.4c-2 改 isIter=YES + chainId 画历史虚线
    PIDAnalysisViewController *vc = [[PIDAnalysisViewController alloc] initWithCSVFilePath:csvPath];
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
    self.currentAnalysisVC = vc;
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

/// 📥 导入下一轮返参(0.4c-2:inline loading → Session sheet 三选一 → 合并原地刷新)
- (void)importNextTapped {
    [self showAlertWithTitle:@"导入下一轮返参"
                     message:@"(0.4c-2 接:inline loading 不跳页 → Session sheet 丢弃/另立/合并 → 合并后原地刷新到下一轮)"];
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
