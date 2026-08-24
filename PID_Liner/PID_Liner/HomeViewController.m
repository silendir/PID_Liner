//
//  HomeViewController.m
//  PID_Liner
//
//  首页 · Y 型三入口 (任务#28 阶段0.3)
//

#import "HomeViewController.h"
#import "CSVHistoryViewController.h"
#import "CimbarScanViewController.h"
#import "IndependentAnalysisViewController.h"
#import "IterationWorkbenchViewController.h"
#import "BBLImportService.h"
#import "IterationChainManager.h"
#import "IterationChain.h"

@interface HomeViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;          // 「选一条路」+ Y 型三入口
@property (nonatomic, strong) UILabel *emptySchemeLabel;   // 方案列表空态提示
@property (nonatomic, strong) NSMutableArray<IterationChain *> *schemes;
@end

@implementation HomeViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@", [NSString stringWithUTF8String:object_getClassName(self)]);
    self.title = @"PID_Liner";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.schemes = [NSMutableArray array];

    [self setupNav];
    [self setupTableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每次回到首页刷新方案列表(迭代链可能在子页面变化)
    [self loadSchemes];
}

#pragma mark - UI Setup

- (void)setupNav {
    // 左上角 ☰ → 总列表(CSVHistoryVC,原始记录仓库)
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"line.horizontal.3"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(totalListButtonTapped)];

    // 右上角扫码 → 光学传输接收 BBL(QRCodeTransfer R2)
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"qrcode.viewfinder"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(scanEntryTapped)];
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.rowHeight = 78;
    _tableView.estimatedRowHeight = 78;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"SchemeCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 顶部 header = 「选一条路」+ Y 型三入口
    // 🔑 tableHeaderView 用 auto layout 必须手动算高度设 frame,否则高度为 0
    UIView *header = [self buildHeaderView];
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize fitSize = [header systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGRect hFrame = header.frame;
    hFrame.size.width = CGRectGetWidth(self.view.bounds);
    hFrame.size.height = fitSize.height;
    header.frame = hFrame;
    self.headerView = header;
    _tableView.tableHeaderView = header;

    // 方案列表空态提示(放在 tableFooterView,无方案时显示)
    _emptySchemeLabel = [[UILabel alloc] init];
    _emptySchemeLabel.text = @"暂无方案\n\n点「🎯 方案迭代」开始一轮调参";
    _emptySchemeLabel.textAlignment = NSTextAlignmentCenter;
    _emptySchemeLabel.numberOfLines = 0;
    _emptySchemeLabel.textColor = [UIColor secondaryLabelColor];
    _emptySchemeLabel.font = [UIFont systemFontOfSize:15];
}

- (UIView *)buildHeaderView {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    // ===== 「选一条路」标题区 =====
    UILabel *title = [[UILabel alloc] init];
    title.text = @"选一条路";
    title.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"看一眼,还是调到底";
    subtitle.font = [UIFont systemFontOfSize:13];
    subtitle.textColor = [UIColor secondaryLabelColor];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:subtitle];

    // ===== Y 型上排两入口:独立分析 / 方案迭代 =====
    UIView *indepCard = [self buildEntryCardWithIcon:@"🛩️"
                                                title:@"独立分析"
                                              subtitle:@"导入 BBL\n选文件即出曲线"
                                            badgeText:@"NO-SAVE"
                                          badgeColor:[UIColor colorWithRed:0.96 green:0.76 blue:0.21 alpha:1.0]
                                        badgeBgColor:[UIColor colorWithRed:1.0 green:0.95 blue:0.78 alpha:1.0]
                                              action:@selector(independentEntryTapped)];

    UIView *iterCard = [self buildEntryCardWithIcon:@"🎯"
                                               title:@"方案迭代"
                                             subtitle:@"多轮闭环收敛\n换参飞 → 反馈"
                                           badgeText:[self iterationBadgeText]
                                         badgeColor:[UIColor colorWithRed:0.06 green:0.46 blue:0.43 alpha:1.0]
                                       badgeBgColor:[UIColor colorWithRed:0.80 green:0.96 blue:0.94 alpha:1.0]
                                             action:@selector(iterationEntryTapped)];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[indepCard, iterCard]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 10;
    topRow.distribution = UIStackViewDistributionFillEqually;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:topRow];

    // ===== 第三入口:炸机诊断(PRO 付费,横条) =====
    UIView *diagCard = [self buildDiagEntryCard];
    [container addSubview:diagCard];

    // ===== 「我的方案」小标题 =====
    UIView *schemeHeader = [[UIView alloc] init];
    schemeHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:schemeHeader];

    UILabel *schemeTitle = [[UILabel alloc] init];
    schemeTitle.text = @"我的方案";
    schemeTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    schemeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [schemeHeader addSubview:schemeTitle];

    UILabel *schemeCount = [[UILabel alloc] init];
    schemeCount.font = [UIFont systemFontOfSize:12];
    schemeCount.textColor = [UIColor secondaryLabelColor];
    schemeCount.translatesAutoresizingMaskIntoConstraints = NO;
    schemeCount.tag = 1001;  // 方案数刷新用
    [schemeHeader addSubview:schemeCount];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:container.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [subtitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [subtitle.bottomAnchor constraintEqualToAnchor:topRow.topAnchor constant:-14],

        [topRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [topRow.heightAnchor constraintEqualToConstant:118],

        [diagCard.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:10],
        [diagCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [diagCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [diagCard.heightAnchor constraintEqualToConstant:64],

        [schemeHeader.topAnchor constraintEqualToAnchor:diagCard.bottomAnchor constant:16],
        [schemeHeader.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [schemeHeader.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [schemeHeader.heightAnchor constraintEqualToConstant:22],
        [schemeHeader.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        [schemeTitle.leadingAnchor constraintEqualToAnchor:schemeHeader.leadingAnchor],
        [schemeTitle.centerYAnchor constraintEqualToAnchor:schemeHeader.centerYAnchor],

        [schemeCount.leadingAnchor constraintEqualToAnchor:schemeTitle.trailingAnchor constant:8],
        [schemeCount.centerYAnchor constraintEqualToAnchor:schemeHeader.centerYAnchor]
    ]];

    return container;
}

/// 构建一个 Y 型上排入口卡片(图标+标题+副标题+badge),整卡可点
- (UIView *)buildEntryCardWithIcon:(NSString *)icon
                             title:(NSString *)cardTitle
                          subtitle:(NSString *)subtitle
                        badgeText:(NSString *)badgeText
                        badgeColor:(UIColor *)badgeColor
                      badgeBgColor:(UIColor *)badgeBgColor
                            action:(SEL)action {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = icon;
    iconLabel.font = [UIFont systemFontOfSize:22];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = cardTitle;
    titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = subtitle;
    subLabel.font = [UIFont systemFontOfSize:11.5];
    subLabel.numberOfLines = 0;
    subLabel.textColor = [UIColor secondaryLabelColor];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subLabel];

    UILabel *badge = [self buildBadgeWithText:badgeText color:badgeColor bgColor:badgeBgColor];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:badge];

    [NSLayoutConstraint activateConstraints:@[
        [iconLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [iconLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:8],

        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],
        [subLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [subLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],

        [badge.topAnchor constraintEqualToAnchor:subLabel.bottomAnchor constant:8],
        [badge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12]
    ]];

    // 整卡可点
    [self attachTapAction:action toView:card];
    return card;
}

/// 构建炸机诊断横条入口(PRO 付费)
- (UIView *)buildDiagEntryCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"🩺";
    iconLabel.font = [UIFont systemFontOfSize:24];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"炸机诊断";
    titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *proBadge = [self buildBadgeWithText:@"PRO"
                                           color:[UIColor whiteColor]
                                          bgColor:[UIColor systemPurpleColor]];
    proBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:proBadge];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = @"AI 找炸机根因 · 失步 / 烧电机 / 缺相";
    subLabel.font = [UIFont systemFontOfSize:11.5];
    subLabel.textColor = [UIColor secondaryLabelColor];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [iconLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [iconLabel.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:12],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],

        [proBadge.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:6],
        [proBadge.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],

        [subLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2]
    ]];

    [self attachTapAction:@selector(crashDiagEntryTapped) toView:card];
    return card;
}

/// 构建 chip 样式的小徽标(auto layout 友好:空格做水平内边距 + 固定高度约束)
- (UILabel *)buildBadgeWithText:(NSString *)text color:(UIColor *)color bgColor:(UIColor *)bgColor {
    UILabel *badge = [[UILabel alloc] init];
    badge.text = [NSString stringWithFormat:@" %@ ", text];  // 前后空格做水平内边距
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    badge.textColor = color;
    badge.backgroundColor = bgColor;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 6;
    badge.layer.masksToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    // 固定高度,宽度由 intrinsicContentSize 决定
    [badge.heightAnchor constraintEqualToConstant:18].active = YES;
    return badge;
}

/// 给一个 view 挂上点击手势(整卡可点)
- (void)attachTapAction:(SEL)action toView:(UIView *)view {
    view.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    [view addGestureRecognizer:tap];
}

#pragma mark - Data

/// 加载迭代链方案,按创建时间倒序
- (void)loadSchemes {
    NSArray<IterationChain *> *all = [[IterationChainManager sharedManager] allChains];
    self.schemes = [all mutableCopy];
    [self.schemes sortUsingComparator:^NSComparisonResult(IterationChain *a, IterationChain *b) {
        return [b.createdAt compare:a.createdAt];
    }];

    // 刷新 header 里方案数文案
    UILabel *countLabel = [_headerView viewWithTag:1001];
    if (!countLabel) {
        // headerView 已被 tableView 持有,从 tableView 取
        countLabel = [_tableView.tableHeaderView viewWithTag:1001];
    }
    countLabel.text = [NSString stringWithFormat:@"%lu 个 · 按 chainId", (unsigned long)self.schemes.count];

    // 空态:用 tableFooterView 显示提示;非空:清空 footer
    if (self.schemes.count == 0) {
        [self installEmptyFooter];
    } else {
        _tableView.tableFooterView = [UIView new];
    }
    [_tableView reloadData];
}

/// 空态提示作为 tableFooterView(无方案时显示一行空提示)
- (void)installEmptyFooter {
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 140)];
    _emptySchemeLabel.frame = footer.bounds;
    _emptySchemeLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [footer addSubview:_emptySchemeLabel];
    _tableView.tableFooterView = footer;
}

/// 方案迭代 badge 文案(进行中数量,0.3 静态展示;0.4 接真实进度)
- (NSString *)iterationBadgeText {
    NSUInteger inProgress = 0;
    for (IterationChain *chain in self.schemes) {
        if (!chain.isConverged) inProgress++;
    }
    return inProgress > 0 ? [NSString stringWithFormat:@"%lu 个进行中", (unsigned long)inProgress] : @"多轮闭环";
}

#pragma mark - 三入口 Actions

/// 🛩️ 独立分析 → CSV 记录空则弹推荐导入例子,否则进独立分析三态
- (void)independentEntryTapped {
    NSLog(@"[Home] 独立分析入口");
    if (![BBLImportService hasAnyCSVRecord]) {
        [self promptDemoWithTitle:@"还没有飞行记录"
                          message:@"加入一条示例飞行数据(BF 4.5),体验独立分析?"
                         onJoined:^{ [self enterIndependentAnalysis]; }];
    } else {
        [self enterIndependentAnalysis];
    }
}

- (void)enterIndependentAnalysis {
    IndependentAnalysisViewController *vc = [[IndependentAnalysisViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

/// 🎯 方案迭代 → 有链进最近工作台;无链弹推荐导入例子(加入=建示例链→进工作台)
- (void)iterationEntryTapped {
    NSLog(@"[Home] 方案迭代入口");
    [self loadSchemes];  // 刷新(按 createdAt 倒序)
    if (self.schemes.count > 0) {
        [self pushWorkbenchForChain:self.schemes.firstObject];
    } else {
        [self promptDemoWithTitle:@"还没有方案"
                          message:@"加入一条示例飞行数据作为第一个方案,体验多轮迭代?"
                         onJoined:^{ [self ensureDemoChainAndEnterWorkbench]; }];
    }
}

/// 加入示例 → 用最近 demo CSV 建/复用一条迭代链 → 进工作台
- (void)ensureDemoChainAndEnterWorkbench {
    NSString *latestCSV = [BBLImportService latestCSVInDocuments];
    if (!latestCSV) {
        [self showSimpleAlertWithTitle:@"加入失败" message:@"未能生成示例数据"];
        return;
    }
    IterationChainManager *mgr = [IterationChainManager sharedManager];
    // 复用同源 demo 链(避免重复加入时建多条)
    IterationChain *existing = nil;
    for (IterationChain *c in [mgr allChains]) {
        if ([c.initialCSVPath.lastPathComponent isEqualToString:latestCSV.lastPathComponent]) {
            existing = c; break;
        }
    }
    IterationChain *chain = existing ?: [mgr createChainWithCraftName:@"示例飞行"
                                                                csvPath:latestCSV
                                                            sessionIndex:0];
    [self pushWorkbenchForChain:chain];
}

- (void)pushWorkbenchForChain:(IterationChain *)chain {
    IterationWorkbenchViewController *vc = [[IterationWorkbenchViewController alloc] initWithChainId:chain.chainId];
    [self.navigationController pushViewController:vc animated:YES];
}

/// 🩺 炸机诊断 → 0.3 指向现有 CSVHistory(选记录诊断);0.4 独立诊断屏
- (void)crashDiagEntryTapped {
    NSLog(@"[Home] 炸机诊断入口");
    [self pushCSVHistory];
}

/// ☰ 总列表(原始记录仓库)
- (void)totalListButtonTapped {
    NSLog(@"[Home] ☰ 总列表");
    [self pushCSVHistory];
}

/// 📷 扫码接收 → 光学传输 BBL
- (void)scanEntryTapped {
    NSLog(@"[Home] 扫码接收入口");
    CimbarScanViewController *vc = [[CimbarScanViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)pushCSVHistory {
    CSVHistoryViewController *vc = [[CSVHistoryViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 空态兜底(三入口统一:空 → 弹推荐导入例子 → 加入 → 各走流程)

/// 统一空态弹窗:推荐导入例子 →「加入示例」= loadDemoBBL → onJoined(主线程)
- (void)promptDemoWithTitle:(NSString *)title message:(NSString *)message onJoined:(void(^)(void))onJoined {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"加入示例" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [BBLImportService loadDemoBBLWithCompletion:^(NSString *csvPath, NSError *error) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            if (!csvPath) {
                [s showSimpleAlertWithTitle:@"加入失败" message:error.localizedDescription ?: @"未知错误"];
                return;
            }
            if (onJoined) onJoined();
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"不用了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource / UITableViewDelegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.schemes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SchemeCell" forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    IterationChain *chain = self.schemes[indexPath.row];

    // 主标题:craftName(空则用 chainId 前8位)
    NSString *name = chain.craftName.length > 0 ? chain.craftName
                                                : [NSString stringWithFormat:@"方案 %@", [chain.chainId substringToIndex:MIN(8, chain.chainId.length)]];
    // 副标题:轮次 + 状态
    NSString *status = chain.isConverged ? @"已收敛 ✓"
                                         : [NSString stringWithFormat:@"进行中 · 第 %ld 轮", (long)chain.currentIteration];
    NSString *detail = [NSString stringWithFormat:@"%ld 轮 · %@", (long)chain.records.count, status];

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:name
                                                                attributes:@{
                                                                    NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
                                                                }]];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:detail
                                                                attributes:@{
                                                                    NSFontAttributeName: [UIFont systemFontOfSize:12],
                                                                    NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
                                                                }]];

    cell.textLabel.attributedText = attr;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.translatesAutoresizingMaskIntoConstraints = NO;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 0.4c:点方案 → 进该链的工作台
    IterationChain *chain = self.schemes[indexPath.row];
    IterationWorkbenchViewController *vc = [[IterationWorkbenchViewController alloc] initWithChainId:chain.chainId];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
