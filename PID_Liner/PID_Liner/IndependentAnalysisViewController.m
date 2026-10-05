//
//  IndependentAnalysisViewController.m
//  PID_Liner
//
//  独立分析 · 单屏三态状态机实现 (任务#28 阶段0.4b)
//

#import "IndependentAnalysisViewController.h"
#import "BBLImportService.h"
#import "BlackboxDecoder.h"
#import "PIDAnalysisViewController.h"
#import "IterationWorkbenchViewController.h"
#import "IterationChainManager.h"
#import "PIDCSVParser.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SVProgressHUD/SVProgressHUD.h>

/// 三态(条件渲染,不平铺)
typedef NS_ENUM(NSInteger, IndepState) {
    IndepStateEmpty      = 0,  // 空态:导入 BBL + 继续上次
    IndepStateProcessing = 1,  // 处理中:BBL→CSV 不可逆
    IndepStateResult     = 2,  // 结果态:Session chip + 图表
};

@interface IndependentAnalysisViewController () <UIDocumentPickerDelegate>
@property (nonatomic, assign) IndepState state;

// 三态容器(铺满 self.view,根据 state 显隐)
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UIView *processingView;
@property (nonatomic, strong) UIView *resultView;

// 空态
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UIButton *demoButton;       // 加入示例(审核兜底/无数据体验)
@property (nonatomic, strong) NSArray<NSNumber *> *sessionDurationSecs;  // 与 sessionCSVPaths 平行的时长(秒),用于默认选最长+chip展示
@property (nonatomic, strong) UIView *lastCSVCard;        // 继续上次卡片(有缓存才显示)
@property (nonatomic, strong) UILabel *lastCSVLabel;
@property (nonatomic, copy, nullable) NSString *lastCSVPath;  // 缓存的 CSV 路径(已校验存在)

// 处理中
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressStatusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

// 结果态
@property (nonatomic, assign) BOOL pageLeft;              // 🔑 pop 置位:转换完成回调不再落地 UI
@property (nonatomic, assign) BOOL curvesReady;           // 🔑 嵌入VC曲线已就绪(「创建迭代方案」解禁条件,防分析中跳走双跑)
@property (nonatomic, strong) UIScrollView *sessionChipScroll;
@property (nonatomic, strong) UIView *chartContainer;     // 嵌入 PIDAnalysisViewController
@property (nonatomic, copy) NSArray<NSString *> *sessionCSVPaths;  // 各 Session 的 CSV 路径
@property (nonatomic, assign) NSInteger selectedSessionIndex;
@property (nonatomic, strong, nullable) PIDAnalysisViewController *currentAnalysisVC;
@end

@implementation IndependentAnalysisViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"独立分析";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupUI];
    [self loadLastCSV];          // 读「继续上次」缓存

    // 🔑 任务#28 0.4c-2 第3步(Q3):「创建迭代方案」桥接 — 把当前分析结果建链首飞轮,推入工作台
    // ⚠️ 仅新建链,不追加已有方案(追加轮次的职责在工作台「📥 导入下一轮返参」),名字与行为对齐
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"创建迭代方案"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(includeInIterationTapped)];
    self.state = IndepStateEmpty;
    [self applyState];

    // 🔖 外部预载(☰ CSV转换记录「📈 独立分析」):push 前设路径,进页直接结果态加载该 CSV
    if (self.preloadedCSVPath.length > 0) {
        NSString *p = self.preloadedCSVPath;
        self.preloadedCSVPath = nil;
        self.sessionDurationSecs = nil;  // 单文件无时长信息,清残留防碎片段守卫误伤
        self.sessionCSVPaths = @[p];
        self.state = IndepStateResult;
        [self applyState];
        [self buildSessionChips];
        [self showAnalysisForSessionIndex:0];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 🔖 从工作台返回恢复:图表 VC 已被「创建迭代方案」收养带走(parent 变成工作台),
    // 容器空了——按缓存原地领回,命中=秒恢复曲线(未命中走正常重分析兜底)
    BOOL chartTaken = (self.currentAnalysisVC == nil)
        || (self.currentAnalysisVC.parentViewController != self);
    if (self.state == IndepStateResult && chartTaken
        && self.sessionCSVPaths.count > 0
        && self.selectedSessionIndex >= 0
        && self.selectedSessionIndex < (NSInteger)self.sessionCSVPaths.count) {
        [self showAnalysisForSessionIndex:self.selectedSessionIndex];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 🔑 离场(pop)即取消:子分析 VC 的后台分析 + 本页 BBL 转换的落地回调
    // (否则解析跑完仍回死页面配图/切状态,卡主线程)
    if (self.isMovingFromParentViewController) {
        self.pageLeft = YES;
        [self.currentAnalysisVC cancelAnalysis];
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    [self setupEmptyView];
    [self setupProcessingView];
    [self setupResultView];

    // 三态容器铺满 safeArea
    NSArray<UIView *> *containers = @[self.emptyView, self.processingView, self.resultView];
    for (UIView *v in containers) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
            [v.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [v.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
        ]];
    }
}

#pragma mark 空态

- (void)setupEmptyView {
    _emptyView = [[UIView alloc] init];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"🛩️";
    iconLabel.font = [UIFont systemFontOfSize:56];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_emptyView addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"独立分析";
    titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_emptyView addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"导入 BBL 飞行记录\n选文件即出响应曲线 · 不保存、不入方案";
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_emptyView addSubview:subtitleLabel];

    _importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_importButton setTitle:@"📁 导入 BBL 文件" forState:UIControlStateNormal];
    [_importButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _importButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _importButton.backgroundColor = [UIColor systemBlueColor];
    _importButton.layer.cornerRadius = 14;
    _importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_importButton addTarget:self action:@selector(importButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_emptyView addSubview:_importButton];

    // 「加入示例」次级按钮(稳定版兜底逻辑:审核员无真机数据也能全流程跑通)
    _demoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_demoButton setTitle:@"✨ 没有文件?加入示例体验" forState:UIControlStateNormal];
    [_demoButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    _demoButton.titleLabel.font = [UIFont systemFontOfSize:15];
    _demoButton.layer.cornerRadius = 14;
    _demoButton.layer.borderWidth = 1.5;
    _demoButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    _demoButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_demoButton addTarget:self action:@selector(demoButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [_emptyView addSubview:_demoButton];

    // 「继续上次」卡片(初始隐藏,有缓存才显示)
    _lastCSVCard = [[UIView alloc] init];
    _lastCSVCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _lastCSVCard.layer.cornerRadius = 12;
    _lastCSVCard.translatesAutoresizingMaskIntoConstraints = NO;
    _lastCSVCard.hidden = YES;
    _lastCSVCard.userInteractionEnabled = YES;
    [_emptyView addSubview:_lastCSVCard];

    UILabel *cardTitle = [[UILabel alloc] init];
    cardTitle.text = @"⏮ 继续上次";
    cardTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    cardTitle.textColor = [UIColor secondaryLabelColor];
    cardTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [_lastCSVCard addSubview:cardTitle];

    _lastCSVLabel = [[UILabel alloc] init];
    _lastCSVLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _lastCSVLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_lastCSVCard addSubview:_lastCSVLabel];

    UITapGestureRecognizer *cardTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(lastCSVCardTapped)];
    [_lastCSVCard addGestureRecognizer:cardTap];

    [NSLayoutConstraint activateConstraints:@[
        [iconLabel.topAnchor constraintEqualToAnchor:_emptyView.topAnchor constant:60],
        [iconLabel.centerXAnchor constraintEqualToAnchor:_emptyView.centerXAnchor],

        [titleLabel.topAnchor constraintEqualToAnchor:iconLabel.bottomAnchor constant:12],
        [titleLabel.leadingAnchor constraintEqualToAnchor:_emptyView.leadingAnchor constant:24],
        [titleLabel.trailingAnchor constraintEqualToAnchor:_emptyView.trailingAnchor constant:-24],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:_emptyView.leadingAnchor constant:24],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:_emptyView.trailingAnchor constant:-24],

        [_importButton.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:28],
        [_importButton.centerXAnchor constraintEqualToAnchor:_emptyView.centerXAnchor],
        [_importButton.heightAnchor constraintEqualToConstant:52],
        [_importButton.widthAnchor constraintEqualToAnchor:_emptyView.widthAnchor multiplier:0.7],

        [_demoButton.topAnchor constraintEqualToAnchor:_importButton.bottomAnchor constant:14],
        [_demoButton.centerXAnchor constraintEqualToAnchor:_emptyView.centerXAnchor],
        [_demoButton.heightAnchor constraintEqualToConstant:44],
        [_demoButton.widthAnchor constraintEqualToAnchor:_emptyView.widthAnchor multiplier:0.7],

        [_lastCSVCard.topAnchor constraintEqualToAnchor:_demoButton.bottomAnchor constant:18],
        [_lastCSVCard.leadingAnchor constraintEqualToAnchor:_emptyView.leadingAnchor constant:24],
        [_lastCSVCard.trailingAnchor constraintEqualToAnchor:_emptyView.trailingAnchor constant:-24],
        [_lastCSVCard.heightAnchor constraintEqualToConstant:62],

        [cardTitle.topAnchor constraintEqualToAnchor:_lastCSVCard.topAnchor constant:8],
        [cardTitle.leadingAnchor constraintEqualToAnchor:_lastCSVCard.leadingAnchor constant:14],

        [_lastCSVLabel.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:2],
        [_lastCSVLabel.leadingAnchor constraintEqualToAnchor:_lastCSVCard.leadingAnchor constant:14],
        [_lastCSVLabel.trailingAnchor constraintEqualToAnchor:_lastCSVCard.trailingAnchor constant:-14]
    ]];
}

#pragma mark 处理中态

- (void)setupProcessingView {
    _processingView = [[UIView alloc] init];

    UILabel *warningLabel = [[UILabel alloc] init];
    warningLabel.text = @"⚠ 处理中 · 不可返回";
    warningLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    warningLabel.textColor = [UIColor systemOrangeColor];
    warningLabel.textAlignment = NSTextAlignmentCenter;
    warningLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_processingView addSubview:warningLabel];

    _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _activityIndicator.hidesWhenStopped = NO;
    [_activityIndicator startAnimating];
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [_processingView addSubview:_activityIndicator];

    _progressStatusLabel = [[UILabel alloc] init];
    _progressStatusLabel.text = @"解析 BBL...";
    _progressStatusLabel.font = [UIFont systemFontOfSize:15];
    _progressStatusLabel.textColor = [UIColor secondaryLabelColor];
    _progressStatusLabel.textAlignment = NSTextAlignmentCenter;
    _progressStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_processingView addSubview:_progressStatusLabel];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progress = 0;
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [_processingView addSubview:_progressView];

    [NSLayoutConstraint activateConstraints:@[
        [warningLabel.topAnchor constraintEqualToAnchor:_processingView.topAnchor constant:80],
        [warningLabel.centerXAnchor constraintEqualToAnchor:_processingView.centerXAnchor],

        [_activityIndicator.topAnchor constraintEqualToAnchor:warningLabel.bottomAnchor constant:30],
        [_activityIndicator.centerXAnchor constraintEqualToAnchor:_processingView.centerXAnchor],

        [_progressStatusLabel.topAnchor constraintEqualToAnchor:_activityIndicator.bottomAnchor constant:16],
        [_progressStatusLabel.leadingAnchor constraintEqualToAnchor:_processingView.leadingAnchor constant:40],
        [_progressStatusLabel.trailingAnchor constraintEqualToAnchor:_processingView.trailingAnchor constant:-40],

        [_progressView.topAnchor constraintEqualToAnchor:_progressStatusLabel.bottomAnchor constant:14],
        [_progressView.leadingAnchor constraintEqualToAnchor:_processingView.leadingAnchor constant:50],
        [_progressView.trailingAnchor constraintEqualToAnchor:_processingView.trailingAnchor constant:-50],
        [_progressView.heightAnchor constraintEqualToConstant:6]
    ]];
}

#pragma mark 结果态

- (void)setupResultView {
    _resultView = [[UIView alloc] init];

    // 顶部 Session chip 横滚区
    _sessionChipScroll = [[UIScrollView alloc] init];
    _sessionChipScroll.showsHorizontalScrollIndicator = YES;
    _sessionChipScroll.alwaysBounceHorizontal = YES;
    _sessionChipScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_resultView addSubview:_sessionChipScroll];

    // 图表容器(嵌入 PIDAnalysisViewController)
    _chartContainer = [[UIView alloc] init];
    _chartContainer.backgroundColor = [UIColor systemBackgroundColor];
    _chartContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [_resultView addSubview:_chartContainer];

    [NSLayoutConstraint activateConstraints:@[
        [_sessionChipScroll.topAnchor constraintEqualToAnchor:_resultView.topAnchor constant:6],
        [_sessionChipScroll.leadingAnchor constraintEqualToAnchor:_resultView.leadingAnchor],
        [_sessionChipScroll.trailingAnchor constraintEqualToAnchor:_resultView.trailingAnchor],
        [_sessionChipScroll.heightAnchor constraintEqualToConstant:44],

        [_chartContainer.topAnchor constraintEqualToAnchor:_sessionChipScroll.bottomAnchor constant:4],
        [_chartContainer.leadingAnchor constraintEqualToAnchor:_resultView.leadingAnchor],
        [_chartContainer.trailingAnchor constraintEqualToAnchor:_resultView.trailingAnchor],
        [_chartContainer.bottomAnchor constraintEqualToAnchor:_resultView.bottomAnchor]
    ]];
}

#pragma mark - 状态切换(条件渲染)

- (void)applyState {
    self.emptyView.hidden = (self.state != IndepStateEmpty);
    self.processingView.hidden = (self.state != IndepStateProcessing);
    self.resultView.hidden = (self.state != IndepStateResult);
    // 「纳入迭代」仅结果态可用(空态/处理中无可建链的数据)
    // 🔑 「创建迭代方案」=曲线就绪才可点:进结果态≠分析完(转换完即结果态,曲线还要~40s),
    // 分析中跳走会让工作台缓存MISS再起一个分析=同文件双跑(真机已推演)
    self.navigationItem.rightBarButtonItem.enabled = (self.state == IndepStateResult) && self.curvesReady;
}

#pragma mark - 空态:导入

- (void)importButtonTapped {
    // iOS 14+ 新 API(免 deprecated warning),asCopy=YES 让系统把文件复制进沙盒
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.data"]]
                                                                     asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

/// ✨ 加入示例(审核兜底):copy bundle 001.bbl → 转 CSV → 直接进结果态,与稳定版兜底逻辑对齐
- (void)demoButtonTapped {
    [SVProgressHUD showWithStatus:@"生成示例数据…"];
    __weak typeof(self) weakSelf = self;
    [BBLImportService loadDemoBBLWithCompletion:^(NSString *csvPath, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [SVProgressHUD dismiss];
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.pageLeft) return;  // 🔑 页面已 pop,不落地 UI
            if (!csvPath) {
                [s showAlertWithTitle:@"加入失败" message:error.localizedDescription ?: @"示例数据生成失败"];
                return;
            }
            // 单 Session 直接进结果态(同「继续上次」路径,不重复转换)
            s.sessionDurationSecs = nil;  // 清残留时长:示例/单文件无时长信息,防旧值误触发碎片段守卫
            s.sessionCSVPaths = @[csvPath];
            s.state = IndepStateResult;
            [s applyState];
            [s buildSessionChips];
            [s showAnalysisForSessionIndex:0];
        });
    }];
}

#pragma mark - 空态:继续上次

- (void)lastCSVCardTapped {
    if (self.lastCSVPath.length == 0) return;
    // 直接用已缓存的 CSV 进结果态(单 Session,无横滚切换)
    self.sessionDurationSecs = nil;  // 清残留时长(同上)
    self.sessionCSVPaths = @[self.lastCSVPath];
    self.state = IndepStateResult;
    [self applyState];
    [self buildSessionChips];
    [self showAnalysisForSessionIndex:0];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;

    NSString *ext = [sourceURL.pathExtension lowercaseString];
    // 独立分析只接受 BBL(CSV 不走此入口,可在 ☰ 历史里查看)
    if (![ext isEqualToString:@"bbl"]) {
        [self showAlertWithTitle:@"文件类型不支持"
                         message:@"独立分析只支持导入 .bbl 飞行记录"];
        return;
    }

    // security-scoped 复制到沙盒 Documents(与 ViewController 导入流程一致)
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

    [self startProcessingBBL:destPath];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 取消:保持空态,无操作
}

#pragma mark - 处理中:BBL → CSV

/// 进处理中态,后台批量转换所有 Session(带进度回调)
- (void)startProcessingBBL:(NSString *)bblPath {
    self.state = IndepStateProcessing;
    [self applyState];
    self.progressStatusLabel.text = @"解析 BBL...";
    self.progressView.progress = 0;

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
                    s.progressStatusLabel.text = [NSString stringWithFormat:@"转换 Session %ld / %ld",
                                                  (long)completed, (long)total];
                    s.progressView.progress = total > 0 ? (float)completed / (float)total : 0;
                });
            } error:&err];

        // 收集成功的 CSV(带 logIndex,供时长对齐)
        NSMutableArray<NSString *> *csvs = [NSMutableArray array];
        NSMutableArray<NSNumber *> *logIndexes = [NSMutableArray array];
        for (BBLImportCSVResult *r in results) {
            if (r.csvPath) {
                [csvs addObject:r.csvPath];
                [logIndexes addObject:@(r.logIndex)];
            }
        }

        // 时长表(listLogs 轻量读取;时长用于"默认选最长"+chip 展示)
        NSArray<BBLSessionInfo *> *infos = [[BBLImportService shared] listSessionsForBBL:bblPath error:nil];
        NSMutableDictionary<NSNumber *, NSNumber *> *durByLogIndex = [NSMutableDictionary dictionary];
        for (BBLSessionInfo *info in infos) {
            durByLogIndex[@(info.logIndex)] = @((double)info.durationUs / 1000000.0);
        }
        NSMutableArray<NSNumber *> *durs = [NSMutableArray array];
        for (NSNumber *li in logIndexes) {
            [durs addObject:durByLogIndex[li] ?: @0];
        }

        // 🔑 默认打开时长最长的 Session——第一个常是解锁测试碎片段(<2s),默认打开必然"分析了个寂寞"
        NSUInteger defaultIdx = 0;
        double maxDur = -1;
        for (NSUInteger i = 0; i < durs.count; i++) {
            double d = durs[i].doubleValue;
            if (d > maxDur) { maxDur = d; defaultIdx = i; }
        }

        // 🔑 空Session防御第1层:时长已知且 <2 秒的碎片段(解锁测试)不进 chip 列表
        // (时长未知=listSessions失败时不过滤,宁滥勿缺)
        NSMutableArray<NSString *> *validCsvs = [NSMutableArray array];
        NSMutableArray<NSNumber *> *validDurs = [NSMutableArray array];
        NSInteger skippedStubs = 0;
        for (NSUInteger i = 0; i < csvs.count; i++) {
            double d = durs[i].doubleValue;
            if (d > 0 && d < 2.0) { skippedStubs++; continue; }
            [validCsvs addObject:csvs[i]];
            [validDurs addObject:durs[i]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.pageLeft) return;  // 🔑 页面已 pop,不落地 UI
            if (validCsvs.count == 0) {
                [s handleProcessingFailure:skippedStubs > 0
                    ? @"所有 Session 都不足 2 秒,无法出响应曲线。\n数据已保留:短片段可能含炸机现场,可在「☰ 总列表」选它进炸机诊断。"
                    : (err.localizedDescription ?: @"无可生成的 CSV")];
                return;
            }
            if (skippedStubs > 0) {
                [SVProgressHUD showInfoWithStatus:[NSString
                    stringWithFormat:@"已隐藏 %ld 个 <2秒片段(出不了曲线;如需炸机诊断去 ☰ 总列表)", (long)skippedStubs]];
            }
            // 重算 defaultIdx(过滤后索引位移)
            NSUInteger validDefault = 0;
            double validMax = -1;
            for (NSUInteger i = 0; i < validDurs.count; i++) {
                double d = validDurs[i].doubleValue;
                if (d > validMax) { validMax = d; validDefault = i; }
            }
            s.sessionCSVPaths = [validCsvs copy];
            s.sessionDurationSecs = [validDurs copy];
            s.lastCSVPath = validCsvs[validDefault];  // "继续上次"也指向真实飞行
            s.selectedSessionIndex = (NSInteger)validDefault;
            s.state = IndepStateResult;
            [s applyState];
            [s buildSessionChips];
            [s showAnalysisForSessionIndex:(NSInteger)validDefault];
        });
    });
}

/// 处理失败:回空态 + 提示
- (void)handleProcessingFailure:(NSString *)message {
    self.state = IndepStateEmpty;
    [self applyState];
    [self showAlertWithTitle:@"转换失败" message:message ?: @"未知错误"];
}

#pragma mark - 结果态:Session chip + 嵌入分析

/// 构建 Session chip 横滚(单 Session 时只显示一个标识 chip)
- (void)buildSessionChips {
    for (UIView *v in [_sessionChipScroll subviews]) {
        [v removeFromSuperview];
    }
    NSUInteger count = self.sessionCSVPaths.count;
    if (count == 0) return;

    // 🔑 滚动修复:内容钉在 contentLayoutGuide 四边,contentSize 才会被 chip 链撑开
    // (旧写法只钉 leading、trailing 事后补加,滚动区计算不可靠导致"滚不动只看得见 S1/S2")
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_sessionChipScroll addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:_sessionChipScroll.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_sessionChipScroll.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:_sessionChipScroll.contentLayoutGuide.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:_sessionChipScroll.contentLayoutGuide.trailingAnchor constant:-16]
        // 🔑 不钉 row.height == frameLayoutGuide.height:首帧 scroll frame 为 0 时该约束与
        // chip 内容高度互斥,activateConstraints 会直接抛异常崩溃(真机已踩)。高度交给 chip 撑
    ]];

    for (NSUInteger i = 0; i < count; i++) {
        // chip = UIView 容器 + UILabel(避开 UIButton iOS15 contentEdgeInsets deprecated)
        UIView *chip = [[UIView alloc] init];
        chip.tag = (NSInteger)i;
        chip.layer.cornerRadius = 14;
        chip.layer.masksToBounds = YES;
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        chip.userInteractionEnabled = YES;

        // 标题:S序号 + 时长(有的话) + 文件名——时长让"没飞的碎片段"一眼可辨
        NSMutableString *title = [NSMutableString stringWithFormat:@"S%lu", (unsigned long)(i + 1)];
        if (i < self.sessionDurationSecs.count) {
            long sec = lround(self.sessionDurationSecs[i].doubleValue);
            if (sec > 0) [title appendFormat:@" · %ld:%02ld", sec / 60, sec % 60];
        }
        NSString *name = [self.sessionCSVPaths[i] lastPathComponent];
        [title appendFormat:@" · %@", [name stringByDeletingPathExtension]];

        UILabel *chipLabel = [[UILabel alloc] init];
        chipLabel.text = title;
        chipLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        chipLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [chip addSubview:chipLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(sessionChipTapped:)];
        [chip addGestureRecognizer:tap];

        // 🔑 必须先入层级再激活约束——chip 与 row 无公共祖先时激活约束直接抛异常崩溃(真机已踩)
        [row addArrangedSubview:chip];

        [NSLayoutConstraint activateConstraints:@[
            [chip.topAnchor constraintEqualToAnchor:row.topAnchor constant:5],
            [chip.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-5],
            // chip 宽度由 label 撑开(label 内边距 12/12)
            [chipLabel.topAnchor constraintEqualToAnchor:chip.topAnchor],
            [chipLabel.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor],
            [chipLabel.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:12],
            [chipLabel.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-12]
        ]];
    }
    [self highlightSessionChipAtIndex:self.selectedSessionIndex];
}

- (void)sessionChipTapped:(UITapGestureRecognizer *)sender {
    [self showAnalysisForSessionIndex:(NSInteger)sender.view.tag];
}

/// 切换 Session:重建嵌入的 PIDAnalysisViewController(避免动其内部状态机)
- (void)showAnalysisForSessionIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.sessionCSVPaths.count) return;

    // 🔑 空Session防御第2层:漏网的碎片段(时长已知但<2秒)点了不给分析,给可读提示
    if (idx < (NSInteger)self.sessionDurationSecs.count) {
        double d = self.sessionDurationSecs[idx].doubleValue;
        if (d > 0 && d < 2.0) {
            [self showAlertWithTitle:@"该片段没有有效飞行数据"
                              message:@"这段不足 2 秒,多为上电解锁测试。请选择时长更长的 Session。"];
            return;
        }
    }

    // 🔑 换 Session = 曲线未就绪,先收掉「创建迭代方案」(防分析中跳走双跑)
    self.curvesReady = NO;
    [self applyState];

    // 移除旧子 VC(仅当还是自己的 child——已被工作台收养走的实例不归本页管,不能在此撕)
    if (self.currentAnalysisVC && self.currentAnalysisVC.parentViewController == self) {
        [self.currentAnalysisVC willMoveToParentViewController:nil];
        [self.currentAnalysisVC.view removeFromSuperview];
        [self.currentAnalysisVC removeFromParentViewController];
    }
    self.currentAnalysisVC = nil;

    // 🔖 结果缓存命中 → 收养现成分析(传递曲线model):免 40s 重解析+重分析
    PIDAnalysisViewController *cached = [PIDAnalysisViewController cachedAnalysisForCSVPath:self.sessionCSVPaths[idx]];
    if (cached) {
        [cached moveToParent:self containerView:self.chartContainer];
        [cached adoptForIndependent];  // 复位迭代标记;曾画过迭代虚线才重画
        self.currentAnalysisVC = cached;
        self.selectedSessionIndex = idx;
        [self highlightSessionChipAtIndex:idx];
        self.curvesReady = YES;  // 收养=曲线现成,立即可建方案
        [self applyState];
        NSLog(@"🔖 [独立分析] 收养缓存分析,免重分析: %@", self.sessionCSVPaths[idx].lastPathComponent);
        return;
    }

    PIDAnalysisViewController *vc =
        [[PIDAnalysisViewController alloc] initWithCSVFilePath:self.sessionCSVPaths[idx]];
    // 🔑 isIter=NO:独立分析不复用迭代链,不保存(右路 1.1 前 1对1 干净版)
    // PIDAnalysisViewController 默认 isIterationMode=NO,此处不显式置位以保持默认
    // 🔑 0.4c-2:隐藏内置「导入下一轮」按钮,独立分析保持纯分析入口(不入方案),避免误触发建链
    vc.hidesBuiltinImportButton = YES;
    // 🔑 曲线就绪回调:此刻才解禁「创建迭代方案」(分析完成VC才会进缓存,跳工作台才能命中收养)
    __weak typeof(self) weakSelf = self;
    vc.onAnalysisComplete = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || s.currentAnalysisVC != vc) return;  // 已切走/换Session,不属本回调管
            s.curvesReady = YES;
            if (s.state == IndepStateResult) [s applyState];
        });
    };

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
    self.selectedSessionIndex = idx;
    [self highlightSessionChipAtIndex:idx];
    [vc startAnalysis];
}

/// chip 选中态高亮(当前=蓝底白字,其余=灰底)
- (void)highlightSessionChipAtIndex:(NSInteger)idx {
    UIView *row = self.sessionChipScroll.subviews.firstObject;
    for (UIView *chip in row.subviews) {
        BOOL selected = (chip.tag == idx);
        chip.backgroundColor = selected ? [UIColor systemBlueColor] : [UIColor secondarySystemBackgroundColor];
        for (UIView *sub in chip.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                ((UILabel *)sub).textColor = selected ? [UIColor whiteColor] : [UIColor labelColor];
            }
        }
    }
}

#pragma mark - 「继续上次」缓存

- (void)loadLastCSV {
    // 继续上次 = Documents 最近一条 CSV(兼容 demo 加入与独立分析自转的 CSV)
    NSString *latest = [BBLImportService latestCSVInDocuments];
    if (latest) {
        self.lastCSVPath = latest;
        self.lastCSVLabel.text = [latest lastPathComponent];
        self.lastCSVCard.hidden = NO;
    } else {
        self.lastCSVPath = nil;
        self.lastCSVCard.hidden = YES;
    }
}

#pragma mark - 桥接:纳入迭代(任务#28 0.4c-2 第3步 Q3)

/// 把当前独立分析(选中 Session)建成迭代链首飞轮,推入工作台继续多轮迭代
- (void)includeInIterationTapped {
    if (self.state != IndepStateResult) return;
    // 🔑 双保险:曲线没出来不允许建方案(此刻跳工作台=缓存MISS→同文件双跑浪费40s)
    if (!self.curvesReady) {
        [self showAlertWithTitle:@"分析进行中" message:@"请等曲线显示完成后再创建迭代方案"];
        return;
    }
    if (self.selectedSessionIndex < 0
        || self.selectedSessionIndex >= (NSInteger)self.sessionCSVPaths.count) {
        [self showAlertWithTitle:@"无法纳入" message:@"请先选择一个 Session"];
        return;
    }

    NSString *csvPath = self.sessionCSVPaths[self.selectedSessionIndex];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (csvPath.length == 0 || ![fm fileExistsAtPath:csvPath]) {
        [self showAlertWithTitle:@"无法纳入" message:@"CSV 文件不存在"];
        return;
    }

    // craftName 从 CSV 头解析;空则用文件名(BBL 没起名的飞机不再产生无名单,如 MAMBAF722)
    NSString *craftName = [[PIDCSVParser parser] extractCraftNameFromCSV:csvPath];
    if (craftName.length == 0) {
        craftName = [csvPath.lastPathComponent stringByDeletingPathExtension];
    }

    // 建链(只建壳,首轮 record 由工作台嵌入 VC 分析完自动 appendRecord)
    IterationChain *chain = [[IterationChainManager sharedManager]
        createChainWithCraftName:craftName
                         csvPath:csvPath
                     sessionIndex:self.selectedSessionIndex];

    IterationWorkbenchViewController *wb = [[IterationWorkbenchViewController alloc] initWithChainId:chain.chainId];
    wb.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:wb animated:YES];
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
