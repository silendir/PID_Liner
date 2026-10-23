//
//  HomeViewController.m
//  PID_Liner
//
//  首页 · Y 型三入口 (任务#28 阶段0.3)
//  V3 明亮改版:色晕卡面 + 栏目矢量示意图(NBHomeIllustrationView) + 令牌(NBTheme)
//  视觉基准: design-demos/首页改版-明亮示意图版.html (V3)
//

#import "HomeViewController.h"
#import "CSVHistoryViewController.h"
#import "MassStorageImportViewController.h"
#import "IndependentAnalysisViewController.h"
#import "IterationWorkbenchViewController.h"
#import "BBLImportService.h"
#import "BlackboxDecoder.h"   // BBLSessionInfo(➕建方案的碎片段时长防御)
#import "IterationChainManager.h"
#import "IterationChain.h"
#import "FCBluetoothService.h"
#import "MSPClient.h"
#import "NBTheme.h"
#import "NBHomeIllustrationView.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SVProgressHUD/SVProgressHUD.h>

@interface HomeViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;          // 「选一条路」+ Y 型三入口
@property (nonatomic, strong) UILabel *emptySchemeLabel;   // 方案列表空态提示
@property (nonatomic, strong) NSMutableArray<IterationChain *> *schemes;
@property (nonatomic, strong) NSArray<BBLImportCSVResult *> *pendingSchemeSessions;  // 新建方案:转换成功的 Session 候选
// 🔑 一键清黑匣子流水线状态(全程 HUD,不进页面)
@property (nonatomic, assign) BOOL bbEraseRunning;         // 防重入:流水线跑完/失败前不允许再触发
@property (nonatomic, assign) NSInteger bbPollCount;       // SUMMARY 轮询次数(判定总超时)
// 🔑 V3 明亮改版:header 测高/入场动画/PRO 渐变同步
@property (nonatomic, strong) UIView *proBadge;            // 方案迭代卡的 PRO(渐变 frame 需测高后同步)
@property (nonatomic, strong) CAGradientLayer *proGradient;
@property (nonatomic, strong) NSMutableArray<NBHomeIllustrationView *> *headerIllustrations;
@property (nonatomic, assign) CGFloat headerSizedWidth;    // 已测高时的宽度(宽度变了才重测)
@property (nonatomic, assign) BOOL introPlayed;            // 描线动画只播一次
@end

@implementation HomeViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@", [NSString stringWithUTF8String:object_getClassName(self)]);
    self.view.backgroundColor = NBTheme.bg;  // V3:云白固定明亮(nav 标题由 header 大标题承载,不设 self.title)
    self.schemes = [NSMutableArray array];
    self.headerIllustrations = [NSMutableArray array];

    [self setupNav];
    [self setupTableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每次回到首页刷新方案列表(迭代链可能在子页面变化)
    [self loadSchemes];
    // 🔑 onStateChanged 是单槽回调(被子页/清匣流水线争用),回首页重挂、离页置 nil
    [self installBLEBadgeObserver];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [FCBluetoothService shared].onStateChanged = nil;
}

// 首页固定明亮:深色系统下状态栏保持深色字(子页照旧跟随系统)
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDarkContent;
}

// 🔑 tableHeaderView 测高:宽度烙进 frame → 强制布一遍 → fitting(宽度同时走参数) → 重赋值刷新 contentSize
// (老做法在 viewDidLoad 里用 self.view.bounds 测,宽度未定时测高必错;以宽度变化为 key,首帧+旋转都会走到)
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (w <= 0) return;
    if (w != _headerSizedWidth) {
        _headerSizedWidth = w;
        UIView *h = _headerView ?: _tableView.tableHeaderView;
        if (h) {
            h.frame = CGRectMake(0, 0, w, 1);
            [h setNeedsLayout];
            [h layoutIfNeeded];
            CGFloat fit = [h systemLayoutSizeFittingSize:CGSizeMake(w, 0)
                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
            h.frame = CGRectMake(0, 0, w, ceil(fit));
            _tableView.tableHeaderView = h;
        }
    }
    // PRO 渐变 frame:首帧子树可能还是零帧,每次布局都补同步(有真实 bounds 才写)
    if (_proGradient && _proBadge.bounds.size.width > 0 &&
        !CGRectEqualToRect(_proGradient.frame, _proBadge.bounds)) {
        _proGradient.frame = _proBadge.bounds;
    }
    // 描线入场动画只播一次(等插图拿到真实宽度)
    if (!_introPlayed && _headerIllustrations.firstObject.bounds.size.width > 0) {
        _introPlayed = YES;
        for (NBHomeIllustrationView *v in _headerIllustrations) [v playIntroAnimationOnce];
    }
}

#pragma mark - UI Setup

/// 🔑 防连点:仅当自己仍是栈顶才允许 push(双击/转场期间重复点击会压入重复页面);
/// 守卫持续到 pop 回首页,即"跳转完成才恢复交互"
- (BOOL)canPush {
    return self.navigationController && self.navigationController.topViewController == self;
}

/// 统一 push 入口(带防连点守卫)
- (void)pushVC:(UIViewController *)vc {
    if (![self canPush]) return;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)setupNav {
    // 左上角「CSV 记录」白底胶囊按钮 → 总列表(CSVHistoryVC,原始记录仓库)——款式照 V3 原型
    UIButton *csvButton = [UIButton buttonWithType:UIButtonTypeSystem];
    csvButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    [csvButton setTitle:@"📄 CSV 记录" forState:UIControlStateNormal];
    [csvButton setTitleColor:NBTheme.dim forState:UIControlStateNormal];
    csvButton.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    csvButton.backgroundColor = NBTheme.card;
    csvButton.layer.cornerRadius = 15;
    csvButton.layer.borderWidth = 1;
    csvButton.layer.borderColor = NBTheme.hairline.CGColor;
    csvButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [csvButton addTarget:self action:@selector(totalListButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [csvButton.heightAnchor constraintEqualToConstant:30].active = YES;
    [csvButton.widthAnchor constraintGreaterThanOrEqualToConstant:104].active = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:csvButton];

    // 右上角双按钮(自绘图标):蓝牙取数(标准蓝牙符号) + 一键清黑匣子(黑匣子+红✕,清空语义)
    // (扫码已摘——cimbar 光学传输实用度低;➕新建方案已删——意义不明且职责重叠)
    UIBarButtonItem *bleButton = [[UIBarButtonItem alloc]
        initWithImage:[NBHomeIllustrationView navBluetoothImage]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(bleImportEntryTapped)];
    UIBarButtonItem *eraseButton = [[UIBarButtonItem alloc]
        initWithImage:[NBHomeIllustrationView navEraseBlackboxImage]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(eraseBlackboxEntryTapped)];
    self.navigationItem.rightBarButtonItems = @[eraseButton, bleButton];

    // 🔑 V3:首页固定明亮,appearance 只挂本页 navigationItem(子页照旧跟随系统)
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = NBTheme.bg;
    appearance.shadowColor = NBTheme.hairline;
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.rowHeight = UITableViewAutomaticDimension;  // 长文件名折行,行高自适应
    _tableView.estimatedRowHeight = 78;
    _tableView.backgroundColor = NBTheme.bg;
    _tableView.separatorColor = NBTheme.hairline;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"SchemeCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 顶部 header = 大标题 + V3 色晕三入口 + 「我的方案」节标题
    // 🔑 构建与测高分离:这里只占位赋值,真实测高在 viewDidLayoutSubviews(宽度定了才准)
    UIView *header = [self buildHeaderView];
    self.headerView = header;
    header.frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 1);
    _tableView.tableHeaderView = header;

    // 方案列表空态提示(放在 tableFooterView,无方案时显示)
    _emptySchemeLabel = [[UILabel alloc] init];
    _emptySchemeLabel.text = @"暂无迭代方案\n\n点「方案迭代」开始一轮调参";
    _emptySchemeLabel.textAlignment = NSTextAlignmentCenter;
    _emptySchemeLabel.numberOfLines = 0;
    _emptySchemeLabel.textColor = NBTheme.faint;
    _emptySchemeLabel.font = [UIFont systemFontOfSize:15];
}

- (UIView *)buildHeaderView {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    // ===== 衬线大标题:「选一条嗨路」(嗨路 蓝色+斜体) =====
    NSMutableAttributedString *ts = [[NSMutableAttributedString alloc]
        initWithString:@"选一条嗨路"
            attributes:@{
                NSFontAttributeName: [NBTheme serifBold:26],
                NSForegroundColorAttributeName: NBTheme.ink
            }];
    [ts addAttributes:@{
        NSForegroundColorAttributeName: NBTheme.accentBlue,
        NSObliquenessAttributeName: @0.12  // Songti 无斜体面,用 obliqueness 模拟
    } range:NSMakeRange(3, 2)];
    UILabel *title = [[UILabel alloc] init];
    title.attributedText = ts;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"调一下, 还是深度喂屎";
    subtitle.font = [UIFont systemFontOfSize:13];
    subtitle.textColor = NBTheme.dim;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:subtitle];

    // BLE 呼吸点徽章(常驻状态;初始中性文案,不提前触发蓝牙权限弹窗)
    UIView *bleBadge = [self buildBLEBadge];
    [container addSubview:bleBadge];

    // ===== 上排两入口:V3 色晕卡面(插图区在卡上半,文字沉底) =====
    UIView *indepCard = [self buildV3EntryCardWithScene:NBHomeSceneIndependent
                                                  title:@"独立分析"
                                               subtitle:@"黑匣子 BBL 导入 · 秒出响应曲线"
                                                    pro:NO
                                                 action:@selector(independentEntryTapped)];
    UIView *iterCard = [self buildV3EntryCardWithScene:NBHomeSceneIteration
                                                 title:@"方案迭代"
                                              subtitle:@"多轮闭环收敛 · 换参飞 → 反馈"
                                                    pro:YES
                                                 action:@selector(iterationEntryTapped)];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[indepCard, iterCard]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 10;
    topRow.distribution = UIStackViewDistributionFillEqually;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:topRow];

    // ===== 第三入口:炸机诊断横条(无 PRO;PRO 归方案迭代) =====
    UIView *diagCard = [self buildV3DiagBar];
    [container addSubview:diagCard];

    // ===== 「我的方案」小标题 =====
    UIView *schemeHeader = [[UIView alloc] init];
    schemeHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:schemeHeader];

    UILabel *schemeTitle = [[UILabel alloc] init];
    schemeTitle.text = @"我的多轮迭代方案";
    schemeTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    schemeTitle.textColor = NBTheme.ink;
    schemeTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [schemeHeader addSubview:schemeTitle];

    UILabel *schemeCount = [[UILabel alloc] init];
    schemeCount.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    schemeCount.textColor = NBTheme.faint;
    schemeCount.translatesAutoresizingMaskIntoConstraints = NO;
    schemeCount.tag = 1001;  // 方案数刷新用
    [schemeHeader addSubview:schemeCount];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:container.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],

        [bleBadge.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [bleBadge.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [subtitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-16],
        [subtitle.bottomAnchor constraintEqualToAnchor:topRow.topAnchor constant:-14],

        [topRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [topRow.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        // 卡高由卡内约束自撑(插图固定高 86 挂在插图上),不用魔法数

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
        [schemeCount.centerYAnchor constraintEqualToAnchor:schemeHeader.centerYAnchor],
        [schemeCount.trailingAnchor constraintLessThanOrEqualToAnchor:schemeHeader.trailingAnchor]
    ]];

    return container;
}

/// V3 色晕入口卡:上半插图区(固定高 86,色晕渐变) + 下半标题行(+可选 PRO) + 单行副题
- (UIView *)buildV3EntryCardWithScene:(NBHomeScene)scene
                                 title:(NSString *)cardTitle
                              subtitle:(NSString *)subtitle
                                    pro:(BOOL)pro
                                 action:(SEL)action {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = NBTheme.card;
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [NBTheme.ink colorWithAlphaComponent:0.06].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.layer.shadowRadius = 10;
    card.layer.shadowOpacity = 1;  // 颜色里已带 alpha,这里固定 1
    card.translatesAutoresizingMaskIntoConstraints = NO;

    NBHomeIllustrationView *fig = [[NBHomeIllustrationView alloc] initWithFrame:CGRectZero scene:scene];
    fig.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:fig];
    [_headerIllustrations addObject:fig];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = cardTitle;
    titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
    titleLabel.textColor = NBTheme.ink;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = subtitle;
    subLabel.font = [UIFont systemFontOfSize:11.5];
    subLabel.textColor = NBTheme.dim;
    subLabel.numberOfLines = 1;
    subLabel.adjustsFontSizeToFitWidth = YES;
    subLabel.minimumScaleFactor = 0.85;
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [fig.topAnchor constraintEqualToAnchor:card.topAnchor],
        [fig.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [fig.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [fig.heightAnchor constraintEqualToConstant:86],

        [titleLabel.topAnchor constraintEqualToAnchor:fig.bottomAnchor constant:12],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],

        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],
        [subLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [subLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [subLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
    ]];

    if (pro) {
        // PRO:渐变容器 view(底层) + 白字 label(内容层)——文字不能放 UILabel.layer.contents 上,
        // sublayer 会盖住 contents,所以不能直接往 UILabel.layer 里插渐变
        UIView *proWrap = [[UIView alloc] init];
        proWrap.layer.cornerRadius = 6;
        proWrap.layer.masksToBounds = YES;
        proWrap.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:proWrap];

        self.proGradient = [CAGradientLayer layer];
        _proGradient.colors = @[(__bridge id)NBTheme.proOrange.CGColor, (__bridge id)NBTheme.proRed.CGColor];
        _proGradient.startPoint = CGPointMake(0, 0.5);
        _proGradient.endPoint = CGPointMake(1, 0.5);
        [proWrap.layer addSublayer:_proGradient];

        UILabel *proText = [[UILabel alloc] init];
        proText.text = @"PRO";
        proText.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        proText.textColor = UIColor.whiteColor;
        proText.translatesAutoresizingMaskIntoConstraints = NO;
        [proWrap addSubview:proText];

        self.proBadge = proWrap;
        // 宽度直接按文本量出(避免 wrap↔label 互相定宽的循环依赖)
        CGFloat textW = [@"PRO" sizeWithAttributes:@{NSFontAttributeName: proText.font}].width;
        [NSLayoutConstraint activateConstraints:@[
            [proWrap.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [proWrap.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
            [proWrap.widthAnchor constraintEqualToConstant:ceil(textW) + 12],
            [proWrap.heightAnchor constraintEqualToConstant:18],
            [proText.centerXAnchor constraintEqualToAnchor:proWrap.centerXAnchor],
            [proText.centerYAnchor constraintEqualToAnchor:proWrap.centerYAnchor]
        ]];
    }

    [self attachTapAction:action toView:card];
    return card;
}

/// 炸机诊断横条:左 38pt 珊瑚 tint 圆角块内「摔断四轴」小场景 + 标题/副题
- (UIView *)buildV3DiagBar {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = NBTheme.card;
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [NBTheme.ink colorWithAlphaComponent:0.06].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.layer.shadowRadius = 10;
    card.layer.shadowOpacity = 1;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *ico = [[UIView alloc] init];
    ico.backgroundColor = NBTheme.accentCoralTint;
    ico.layer.cornerRadius = 11;
    ico.layer.masksToBounds = YES;
    ico.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:ico];

    NBHomeIllustrationView *mini = [[NBHomeIllustrationView alloc] initWithFrame:CGRectZero scene:NBHomeSceneCrashMini];
    mini.translatesAutoresizingMaskIntoConstraints = NO;
    [ico addSubview:mini];
    [_headerIllustrations addObject:mini];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"炸机诊断";
    titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightBold];
    titleLabel.textColor = NBTheme.ink;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = @"教培机黑匣子不开源 · 我们读得懂";
    subLabel.font = [UIFont systemFontOfSize:11.5];
    subLabel.textColor = NBTheme.dim;
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [ico.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [ico.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [ico.widthAnchor constraintEqualToConstant:38],
        [ico.heightAnchor constraintEqualToConstant:38],

        [mini.topAnchor constraintEqualToAnchor:ico.topAnchor],
        [mini.leadingAnchor constraintEqualToAnchor:ico.leadingAnchor],
        [mini.trailingAnchor constraintEqualToAnchor:ico.trailingAnchor],
        [mini.bottomAnchor constraintEqualToAnchor:ico.bottomAnchor],

        [titleLabel.leadingAnchor constraintEqualToAnchor:ico.trailingAnchor constant:12],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],

        [subLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2]
    ]];

    [self attachTapAction:@selector(crashDiagEntryTapped) toView:card];
    return card;
}

/// BLE 呼吸点徽章:初始中性文案(不读 bluetoothStateText——它会 lazy 建中心并触发权限弹窗)
- (UIView *)buildBLEBadge {
    UIView *badge = [[UIView alloc] init];
    badge.backgroundColor = NBTheme.card;
    badge.layer.cornerRadius = 12;
    badge.layer.borderWidth = 1;
    badge.layer.borderColor = NBTheme.hairline.CGColor;
    badge.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *dot = [[UIView alloc] init];
    dot.backgroundColor = NBTheme.faint;  // 未就绪中性灰;就绪后 updateBLEBadge 换青绿
    dot.layer.cornerRadius = 3.5;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.tag = 2005;
    [badge addSubview:dot];

    UILabel *text = [[UILabel alloc] init];
    text.text = @"蓝牙待连接";
    text.font = [UIFont systemFontOfSize:10];
    text.textColor = NBTheme.dim;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.tag = 2006;
    [badge addSubview:text];

    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor constant:10],
        [dot.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:7],
        [dot.heightAnchor constraintEqualToConstant:7],

        [text.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
        [text.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:-10],
        [text.topAnchor constraintEqualToAnchor:badge.topAnchor constant:5],
        [text.bottomAnchor constraintEqualToAnchor:badge.bottomAnchor constant:-5]
    ]];

    // 1.6s 呼吸
    [UIView animateWithDuration:0.8
                          delay:0
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ dot.alpha = 0.35; }
                     completion:nil];
    return badge;
}

/// BLE 状态刷新(只在 onStateChanged 回调/central 已存在时调用,读 stateText 安全)
- (void)updateBLEBadgeReady:(BOOL)ready text:(NSString *)stateText {
    UIView *h = _headerView ?: _tableView.tableHeaderView;
    UIView *dot = [h viewWithTag:2005];
    UILabel *label = [h viewWithTag:2006];
    if (!dot || !label) return;
    dot.backgroundColor = ready ? NBTheme.accentGreen : NBTheme.faint;
    NSString *t = ready ? @"蓝牙已连接" : stateText;
    if (t.length) label.text = t;
}

/// 重挂 BLE 状态回调(单槽:清匣流水线/子页会覆写,回首页时重挂)
- (void)installBLEBadgeObserver {
    FCBluetoothService *ble = [FCBluetoothService shared];  // 安全:不创建 central,不触发权限弹窗
    __weak typeof(self) weakSelf = self;
    ble.onStateChanged = ^(BOOL ready, NSString *stateText) {
        __strong typeof(weakSelf) s = weakSelf;
        [s updateBLEBadgeReady:ready text:stateText];
    };
    // central 已存在(用户用过蓝牙功能)时立即刷一次;此时读 stateText 无弹窗风险
    if (ble.bluetoothReady) {
        [self updateBLEBadgeReady:YES text:ble.bluetoothStateText];
    }
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

#pragma mark - 三入口 Actions

/// 🛩️ 独立分析 → 直接进三态页(空态页内已有「✨加入示例」+「📁导入BBL」+「继续上次」,
/// 首页再弹"要加示例吗"属 0.3 旧设计的重复门,打断点击预期,已删)
- (void)independentEntryTapped {
    NSLog(@"[Home] 独立分析入口");
    [self enterIndependentAnalysis];
}

- (void)enterIndependentAnalysis {
    IndependentAnalysisViewController *vc = [[IndependentAnalysisViewController alloc] init];
    [self pushVC:vc];
}

/// 🎯 方案迭代 → 有链进最近工作台;无链弹推荐导入例子(加入=建示例链→进工作台)
- (void)iterationEntryTapped {
    NSLog(@"[Home] 方案迭代入口");
    [self loadSchemes];  // 刷新(按 createdAt 倒序)
    if (self.schemes.count > 0) {
        [self pushWorkbenchForChain:self.schemes.firstObject];
        return;
    }
    // 🔑 空态三选:导入自己的 BBL 建第一个方案(正经入口) / 加入示例(体验) / 取消
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"开始一个调参方案"
                          message:@"导入一份飞行 BBL 作为方案的第一轮,\n之后每次换参飞行都导入到同一条链迭代。"
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 导入 BBL 新建方案" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self presentSchemeBBLPicker];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"加入示例(体验)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self promptDemoWithTitle:@"加入示例"
                          message:@"用内置示例飞行数据体验多轮迭代流程?"
                         onJoined:^{ [self ensureDemoChainAndEnterWorkbench]; }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 导入 BBL 新建方案(第一轮入口)

- (void)presentSchemeBBLPicker {
    // BBL 无系统 UTType,用通用 data 放开,后缀在回调里校验
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSString *name = url.lastPathComponent;
    if (![name.pathExtension.lowercaseString isEqualToString:@"bbl"]) {
        [self showSimpleAlertWithTitle:@"请选择 .bbl 文件" message:name];
        return;
    }

    // asCopy:YES 已复制到临时区,转存 Documents
    // 🔑 存储前重名防御:同名 BBL 不覆盖,自动加序号(吴总→吴总1→吴总2),保留两者
    NSString *uniqueBase = [BBLImportService uniqueDocumentsBaseNameForBase:name.stringByDeletingPathExtension
                                                                  extension:name.pathExtension];
    NSString *dest = [[BBLImportService documentsDirectory]
        stringByAppendingPathComponent:[uniqueBase stringByAppendingPathExtension:name.pathExtension]];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&copyError]) {
        [self showSimpleAlertWithTitle:@"保存失败" message:copyError.localizedDescription];
        return;
    }

    // 后台批量转换全部 Session,成功后单选建链
    [SVProgressHUD showWithStatus:@"解码 BBL…"];
    BBLImportService *svc = [BBLImportService shared];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<BBLImportCSVResult *> *results = [svc convertAllSessionsForBBL:dest
                                                                      motorKV:nil
                                                                     progress:nil
                                                                        error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [SVProgressHUD dismiss];
            NSMutableArray<BBLImportCSVResult *> *ok = [[results filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(BBLImportCSVResult *r, NSDictionary *b) { return r.isSuccess; }]] mutableCopy];

            // 🔑 碎片段防御(与独立分析同款):<2秒解锁测试 Session 出不了曲线,建链=空方案
            // (首轮链 CSV 是碎片段 → 工作台无响应无诊断无CLI,弹"无推荐值"的根因)
            NSArray<BBLSessionInfo *> *infos = [[BBLImportService shared] listSessionsForBBL:dest error:nil];
            NSMutableDictionary<NSNumber *, NSNumber *> *durByLog = [NSMutableDictionary dictionary];
            for (BBLSessionInfo *info in infos) {
                durByLog[@(info.logIndex)] = @((double)info.durationUs / 1000000.0);
            }
            NSInteger stubs = 0;
            for (BBLImportCSVResult *r in [ok copy]) {
                NSNumber *d = durByLog[@(r.logIndex)];
                if (d && d.doubleValue > 0 && d.doubleValue < 2.0) {
                    [ok removeObject:r];
                    stubs++;
                }
            }
            if (ok.count == 0) {
                [self showSimpleAlertWithTitle:@"没有可用的飞行数据"
                    message:stubs > 0
                        ? @"全部 Session 不足 2 秒(多为解锁测试),无法建方案。\n短片段可用于炸机诊断(☰ 总列表)。"
                        : (results.firstObject.errorMessage ?: @"BBL 解码失败")];
                return;
            }
            if (ok.count == 1) {
                [self createSchemeChainFromSession:ok.firstObject];
            } else {
                [self showSessionPickSheet:ok];
            }
        });
    });
}

/// 多 Session 单选(一个方案 = 一条链 = 一个 Session 的迭代史;与工作台导入下一轮同交互)
- (void)showSessionPickSheet:(NSArray<BBLImportCSVResult *> *)sessions {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"选择一个 Session 作为方案第一轮"
                          message:@"每个 Session 独立成链互不混参"
                   preferredStyle:UIAlertControllerStyleActionSheet];
    for (BBLImportCSVResult *r in sessions) {
        [sheet addAction:[UIAlertAction actionWithTitle:r.sessionDescription ?: r.csvPath.lastPathComponent
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self createSchemeChainFromSession:r]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)createSchemeChainFromSession:(BBLImportCSVResult *)result {
    // 方案名暂用 BBL 文件名占位(Q2 手动命名后续加编辑)
    NSString *bblName = result.csvPath.lastPathComponent;  // CSV 名含 session 序号,文件名做 craft 名占位
    NSString *craftName = bblName ?: @"我的方案";
    IterationChain *chain = [[IterationChainManager sharedManager] createChainWithCraftName:craftName
                                                                                     csvPath:result.csvPath
                                                                                sessionIndex:result.logIndex];
    [self loadSchemes];
    [self pushWorkbenchForChain:chain];
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
    [self pushVC:vc];
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

#pragma mark - 一键清空飞控黑匣子(蓝牙流水线)

/// 🗑 清黑匣子入口:确认后全自动跑完 扫描→连接→握手→擦除→验证→挥手,全程 HUD 无页面
- (void)eraseBlackboxEntryTapped {
    if (self.bbEraseRunning) return;  // 防重入:上一条流水线还在跑
    // 破坏性操作必须确认:板载黑盒数据清了就没了
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"清空飞控黑匣子"
        message:@"将蓝牙连接飞控并擦除板载黑盒闪存,已记录的飞行日志不可恢复。\n\n请确认数据已下载保存,且飞控已通电、蓝牙模块就绪。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self bbEraseStart];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 第1步:扫描 3 秒收设备 → 0台报错 / 1台直连 / 多台弹选择
- (void)bbEraseStart {
    FCBluetoothService *ble = [FCBluetoothService shared];
    if (!ble.bluetoothReady) {
        // 首次点击:CBCentralManager 此刻才被点出来,系统上电要几百毫秒
        // (首次使用还要等权限弹窗确认)→ 不报错打断,等上电完成自动续跑,
        // 用户不再需要点第二次。15s 兜底覆盖蓝牙关闭/未授权等真失败。
        self.bbEraseRunning = YES;
        [SVProgressHUD showWithStatus:ble.bluetoothStateText];
        __weak typeof(self) weakSelf = self;
        ble.onStateChanged = ^(BOOL ready, NSString *stateText) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || !s.bbEraseRunning) return;
            if (ready) {
                ble.onStateChanged = nil;
                [SVProgressHUD showWithStatus:@"正在扫描飞控蓝牙…"];
                [s bbEraseStart];  // 就绪,从扫描起重新走流水线
            } else {
                [SVProgressHUD showWithStatus:stateText];  // 上电中/等权限确认
            }
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s || !s.bbEraseRunning || ble.bluetoothReady) return;
            ble.onStateChanged = nil;
            s.bbEraseRunning = NO;
            [SVProgressHUD showErrorWithStatus:ble.bluetoothStateText];
        });
        return;
    }
    self.bbEraseRunning = YES;
    self.bbPollCount = 0;
    [SVProgressHUD showWithStatus:@"正在扫描飞控蓝牙…"];
    [ble startScan];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.bbEraseRunning) { if (s) [ble stopScan]; return; }
        [ble stopScan];
        NSArray<FCBleDevice *> *devices = ble.foundDevices ?: @[];
        if (devices.count == 0) {
            [s bbEraseFinishSuccess:NO message:@"未发现飞控蓝牙\n请确认飞控通电、蓝牙模块指示灯亮"];
            return;
        }
        if (devices.count == 1) {
            [s bbEraseConnect:devices.firstObject];
            return;
        }
        // 多台:居中 Alert 选择(Alert 样式 iPad 免 popover 锚点)
        [SVProgressHUD dismiss];
        UIAlertController *pick = [UIAlertController alertControllerWithTitle:@"发现多台飞控"
                                                                      message:@"选择要清空黑匣子的设备"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        for (FCBleDevice *d in devices) {
            [pick addAction:[UIAlertAction actionWithTitle:d.name.length ? d.name : @"未命名设备"
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) { [s bbEraseConnect:d]; }]];
        }
        [pick addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            s.bbEraseRunning = NO;
        }]];
        [s presentViewController:pick animated:YES completion:nil];
    });
}

/// 第2步:连接
- (void)bbEraseConnect:(FCBleDevice *)device {
    [SVProgressHUD showWithStatus:[NSString stringWithFormat:@"正在连接 %@…", device.name ?: @"飞控"]];
    __weak typeof(self) weakSelf = self;
    [[FCBluetoothService shared] connectDevice:device completion:^(NSString *errorMessage) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.bbEraseRunning) return;
        if (errorMessage) {
            [s bbEraseFinishSuccess:NO message:[NSString stringWithFormat:@"连接失败:%@", errorMessage]];
            return;
        }
        [s bbEraseHandshake];
    }];
}

/// 第3步:MSP 链路探测(API_VERSION 必答秒回,分清"链路不通"和"擦除慢")
- (void)bbEraseHandshake {
    [SVProgressHUD showWithStatus:@"已连接,探测 MSP 链路…"];
    __weak typeof(self) weakSelf = self;
    [[FCBluetoothService shared] sendCommand:MSPCommandApiVersion payload:[NSData data] reply:^(NSData *p, NSString *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.bbEraseRunning) return;
        if (err) {
            [s bbEraseFinishSuccess:NO message:[NSString stringWithFormat:@"MSP 链路不通:%@", err]];
            return;
        }
        [s bbEraseSend];
    }];
}

/// 第4步:发擦除命令。老固件整片擦 NOR 时阻塞 MSP(30s+ 才回 ack),
/// sendCommand 的 5s 超时必然先引爆——超时≠失败,是预期路径;真实判定交给 SUMMARY 轮询
- (void)bbEraseSend {
    [SVProgressHUD showWithStatus:@"正在擦除黑匣子…(约30~60秒,请勿给飞控断电)"];
    FCBluetoothService *ble = [FCBluetoothService shared];
    __weak typeof(self) weakSelf = self;
    [ble sendCommand:MSPCommandDataflashErase payload:[NSData data] reply:^(NSData *p, NSString *err) {
        NSLog(@"[清黑匣] ERASE 返回(超时也属预期): %@", err ?: @"已ack");
    }];
    // 等 ERASE 的 5s 超时引爆(waitingReply 复位,否则 SUMMARY 发不出去)再开始轮询
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.bbEraseRunning) return;
        [s bbErasePoll];
    });
}

/// 第5步:轮询 SUMMARY(每5秒一次,最多18次≈96秒总窗口)直到"已用字节=0"
- (void)bbErasePoll {
    FCBluetoothService *ble = [FCBluetoothService shared];
    if (!ble.isConnected) {
        [self bbEraseFinishSuccess:NO message:@"擦除期间蓝牙断连,结果未知\n重连后再点一次「清空」可验证"];
        return;
    }
    self.bbPollCount++;
    if (self.bbPollCount > 18) {
        [self bbEraseFinishSuccess:NO message:@"擦除超时:飞控长时间无响应\n请重试一次,或改用插线方式清理"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[FCBluetoothService shared] sendCommand:MSPCommandDataflashSummary payload:[NSData data] reply:^(NSData *p, NSString *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.bbEraseRunning) return;
        if (err || p.length < 13) {
            // 擦除阻塞期探不进去 → 继续等下一轮
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s2 = weakSelf;
                if (!s2 || !s2.bbEraseRunning) return;
                [s2 bbErasePoll];
            });
            return;
        }
        // payload: flags(1) + sector(u32) + total(u32) + used(u32) = 13 字节
        uint8_t flags = ((const uint8_t *)p.bytes)[0];
        if (!(flags & 0x02)) {
            [s bbEraseFinishSuccess:NO message:@"飞控没有板载 dataflash 黑盒\n(SD 卡机型不支持此方式)"];
            return;
        }
        uint32_t used = 0;
        [p getBytes:&used range:NSMakeRange(9, 4)];  // iOS ARM 小端,直接读
        if (used == 0) {
            [s bbEraseFinishSuccess:YES message:@"黑匣子已清空"];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2 || !s2.bbEraseRunning) return;
            [s2 bbErasePoll];
        });
    }];
}

/// 终点:提示 + 挥手断链
- (void)bbEraseFinishSuccess:(BOOL)success message:(NSString *)message {
    self.bbEraseRunning = NO;
    if (success) {
        [SVProgressHUD showSuccessWithStatus:message];
        NSLog(@"[清黑匣] ✅ %@", message);
    } else {
        [SVProgressHUD showErrorWithStatus:message];
        NSLog(@"[清黑匣] ❌ %@", message);
    }
    [[FCBluetoothService shared] disconnect];  // 无论成败都挥手
}

/// 📡 蓝牙取数 → BLE 激活大容量存储 → USB 文件导入
- (void)bleImportEntryTapped {
    NSLog(@"[Home] 蓝牙取数入口");
    MassStorageImportViewController *vc = [[MassStorageImportViewController alloc] init];
    [self pushVC:vc];
}

- (void)pushCSVHistory {
    CSVHistoryViewController *vc = [[CSVHistoryViewController alloc] init];
    [self pushVC:vc];
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
    // 🔑 显示"最新已存在轮"的轮号(records.lastObject.iteration);
    // 旧用 currentIteration(=count+1,"下一轮"语义) → 1 轮的链显示"进行中·第2轮"(真机已踩)
    NSString *detail;
    if (chain.records.count == 0) {
        detail = @"尚未飞行 · 等待第 1 轮";
    } else {
        NSInteger latestRound = chain.records.lastObject.iteration;
        if (latestRound < 1) latestRound = (NSInteger)chain.records.count;
        NSString *status = chain.isConverged ? @"已收敛 ✓"
                                             : [NSString stringWithFormat:@"进行中 · 第 %ld 轮", (long)latestRound];
        detail = [NSString stringWithFormat:@"%ld 轮 · %@", (long)chain.records.count, status];
    }

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
    NSMutableParagraphStyle *namePara = [NSMutableParagraphStyle new];
    namePara.lineBreakMode = NSLineBreakByCharWrapping;  // 真实长文件名(中英混排)按字断行
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:name
                                                                attributes:@{
                                                                    NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
                                                                    NSForegroundColorAttributeName: NBTheme.ink,
                                                                    NSParagraphStyleAttributeName: namePara
                                                                }]];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [attr appendAttributedString:[[NSAttributedString alloc] initWithString:detail
                                                                attributes:@{
                                                                    NSFontAttributeName: [UIFont systemFontOfSize:12],
                                                                    NSForegroundColorAttributeName: NBTheme.dim
                                                                }]];

    cell.textLabel.attributedText = attr;
    cell.textLabel.numberOfLines = 0;
    // 🔑 不动 textLabel 的 translatesAutoresizingMask:默认 cell 的 textLabel 靠系统约束布局,
    // 关掉又不安自己的约束=首帧零帧贴左边缘(点击重排才"恢复",真机已踩)
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 0.4c:点方案 → 进该链的工作台
    IterationChain *chain = self.schemes[indexPath.row];
    IterationWorkbenchViewController *vc = [[IterationWorkbenchViewController alloc] initWithChainId:chain.chainId];
    [self pushVC:vc];
}

/// 方案列表左滑删除(整链硬删,含全部轮次)
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    IterationChain *chain = self.schemes[indexPath.row];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"删除这个方案?"
        message:[NSString stringWithFormat:@"「%@」及其全部迭代轮次将被硬删除,无法恢复。",
            chain.craftName.length > 0 ? chain.craftName : chain.chainId]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[IterationChainManager sharedManager] deleteChain:chain.chainId];
        [weakSelf loadSchemes];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
