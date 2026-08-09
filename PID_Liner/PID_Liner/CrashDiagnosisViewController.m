//
//  CrashDiagnosisViewController.m
//  PID_Liner
//
//  炸机诊断独立屏 (任务#28 阶段0.4a)
//

#import "CrashDiagnosisViewController.h"
#import "CrashDiagnosisEngine.h"

/// 诊断屏三态(条件渲染,绝不平铺)
typedef NS_ENUM(NSInteger, CrashDiagnosisState) {
    CrashDiagnosisStatePaywall,   // 付费墙(IAP 占位)
    CrashDiagnosisStateLoading,   // 流式加载中
    CrashDiagnosisStateResult,    // 完成:报告 + localIndicators
};

/// 付费墙免费额度 Key(占位,StoreKit 后置再换)
static NSString *const kCrashDiagQuotaKey = @"crashDiagFreeQuota";
static const NSInteger kCrashDiagDefaultQuota = 3;

/// 把 v 限定到 [lo, hi]
static inline double CrashClamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@interface CrashDiagnosisViewController ()

@property (nonatomic, copy) NSString *csvPath;
@property (nonatomic, copy) NSString *displayTitle;
@property (nonatomic, assign) CrashDiagnosisState state;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

// 付费墙态
@property (nonatomic, strong) UIView *paywallCard;
@property (nonatomic, strong) UILabel *quotaLabel;

// 加载态
@property (nonatomic, strong) UIView *loadingCard;
@property (nonatomic, strong) UIActivityIndicatorView *indicator;
@property (nonatomic, strong) UITextView *streamingTextView;

// 结果态
@property (nonatomic, strong) UIView *reportCard;
@property (nonatomic, strong) UITextView *reportTextView;
@property (nonatomic, strong) UIStackView *indicatorsStack;   // localIndicators 卡片容器

@property (nonatomic, strong, nullable) CrashDiagnosisResult *lastResult;

@end

@implementation CrashDiagnosisViewController

#pragma mark - Init

- (instancetype)initWithCSVPath:(NSString *)csvPath title:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _csvPath = [csvPath copy] ?: @"";
        _displayTitle = [title copy] ?: @"炸机诊断";
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@", [NSString stringWithUTF8String:object_getClassName(self)]);
    self.title = self.displayTitle;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupNav];
    [self setupUI];
    [self applyState:CrashDiagnosisStatePaywall];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshQuotaLabel];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 离开屏即断开流式 + 取消请求(回调不再打到本屏 UI)
    if ([self isMovingFromParentViewController] || [self isBeingDismissed]) {
        [self cleanupEngine];
    }
}

#pragma mark - 导航栏(刷新 / 设置 / 停止)

- (void)setupNav {
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                style:UIBarButtonItemStylePlain
               target:self action:@selector(refreshDiagnosis:)];
    UIBarButtonItem *settingsBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"gearshape"]
                style:UIBarButtonItemStylePlain
               target:self action:@selector(showDiagnosisSettings:)];
    UIBarButtonItem *stopBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemStop
                             target:self action:@selector(cancelDiagnosis:)];
    self.navigationItem.rightBarButtonItems = @[stopBtn, settingsBtn, refreshBtn];
}

#pragma mark - UI 搭建

- (void)setupUI {
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    _contentStack = [[UIStackView alloc] init];
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = 14;
    _contentStack.alignment = UIStackViewAlignmentFill;
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_contentStack.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor constant:16],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor constant:-16],
        // 🔑 widthAnchor 对齐 frameLayoutGuide,让内容宽度跟随屏宽(不随内容无限拉伸)
        [_contentStack.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    self.paywallCard = [self buildPaywallCard];
    self.loadingCard = [self buildLoadingCard];
    self.reportCard  = [self buildReportCard];
    [_contentStack addArrangedSubview:self.paywallCard];
    [_contentStack addArrangedSubview:self.loadingCard];
    [_contentStack addArrangedSubview:self.reportCard];
}

/// 付费墙态(IAP 占位):免费额度提示 + 解锁按钮 + 开始诊断
- (UIView *)buildPaywallCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;

    UILabel *icon = [[UILabel alloc] init];
    icon.text = @"🩺";
    icon.font = [UIFont systemFontOfSize:42];
    icon.textAlignment = NSTextAlignmentCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:icon];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"AI 炸机诊断";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UILabel *desc = [[UILabel alloc] init];
    desc.text = @"上传飞行记录,AI 自动定位炸机根因\n失步 · 烧电机 · 缺相 · 振动";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = [UIColor secondaryLabelColor];
    desc.textAlignment = NSTextAlignmentCenter;
    desc.numberOfLines = 0;
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:desc];

    _quotaLabel = [[UILabel alloc] init];
    _quotaLabel.font = [UIFont systemFontOfSize:13];
    _quotaLabel.textColor = [UIColor secondaryLabelColor];
    _quotaLabel.textAlignment = NSTextAlignmentCenter;
    _quotaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_quotaLabel];

    UIButton *unlockBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [unlockBtn setTitle:@"🔓 解锁无限诊断 (PRO)" forState:UIControlStateNormal];
    unlockBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    unlockBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [unlockBtn addTarget:self action:@selector(unlockButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:unlockBtn];

    UIButton *startBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [startBtn setTitle:@"开始诊断" forState:UIControlStateNormal];
    [startBtn.titleLabel setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightBold]];
    startBtn.backgroundColor = [UIColor systemBlueColor];
    [startBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    startBtn.layer.cornerRadius = 12;
    startBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [startBtn addTarget:self action:@selector(startDiagnosisButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:startBtn];

    [NSLayoutConstraint activateConstraints:@[
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [icon.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [desc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [_quotaLabel.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:14],
        [_quotaLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [unlockBtn.topAnchor constraintEqualToAnchor:_quotaLabel.bottomAnchor constant:6],
        [unlockBtn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [startBtn.topAnchor constraintEqualToAnchor:unlockBtn.bottomAnchor constant:14],
        [startBtn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [startBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [startBtn.heightAnchor constraintEqualToConstant:46],
        [startBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]
    ]];
    return card;
}

/// 加载态:转圈 + 流式输出(Menlo 黑底终端风)
- (UIView *)buildLoadingCard {
    UIView *card = [[UIView alloc] init];

    _indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _indicator.translatesAutoresizingMaskIntoConstraints = NO;
    _indicator.hidesWhenStopped = YES;
    [card addSubview:_indicator];

    UILabel *label = [[UILabel alloc] init];
    label.text = @"正在分析飞行数据...";
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:label];

    _streamingTextView = [[UITextView alloc] init];
    _streamingTextView.editable = NO;
    _streamingTextView.font = [UIFont fontWithName:@"Menlo" size:12];
    _streamingTextView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1.0];
    _streamingTextView.textColor = [UIColor colorWithRed:0.85 green:0.87 blue:0.80 alpha:1.0];
    _streamingTextView.text = @"⏳ 正在分析飞行数据...\n\n";
    _streamingTextView.scrollEnabled = NO;   // 跟随外层 scrollView
    _streamingTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_streamingTextView];

    [NSLayoutConstraint activateConstraints:@[
        [_indicator.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [_indicator.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],

        [label.centerYAnchor constraintEqualToAnchor:_indicator.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:_indicator.trailingAnchor constant:8],

        [_streamingTextView.topAnchor constraintEqualToAnchor:_indicator.bottomAnchor constant:12],
        [_streamingTextView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [_streamingTextView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [_streamingTextView.heightAnchor constraintGreaterThanOrEqualToConstant:320],
        [_streamingTextView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]
    ]];
    return card;
}

/// 结果态:AI 报告 + localIndicators 可视化区
- (UIView *)buildReportCard {
    UIView *card = [[UIView alloc] init];

    UILabel *reportTitle = [[UILabel alloc] init];
    reportTitle.text = @"📋 AI 诊断报告";
    reportTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    reportTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:reportTitle];

    _reportTextView = [[UITextView alloc] init];
    _reportTextView.editable = NO;
    _reportTextView.font = [UIFont fontWithName:@"Menlo" size:12];
    _reportTextView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1.0];
    _reportTextView.textColor = [UIColor colorWithRed:0.85 green:0.87 blue:0.80 alpha:1.0];
    _reportTextView.scrollEnabled = NO;   // 跟随外层 scrollView
    _reportTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_reportTextView];

    UILabel *indTitle = [[UILabel alloc] init];
    indTitle.text = @"🔬 本地异常指标";
    indTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    indTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:indTitle];

    _indicatorsStack = [[UIStackView alloc] init];
    _indicatorsStack.axis = UILayoutConstraintAxisVertical;
    _indicatorsStack.spacing = 10;
    _indicatorsStack.alignment = UIStackViewAlignmentFill;
    _indicatorsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_indicatorsStack];

    [NSLayoutConstraint activateConstraints:@[
        [reportTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
        [reportTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [reportTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],

        [_reportTextView.topAnchor constraintEqualToAnchor:reportTitle.bottomAnchor constant:8],
        [_reportTextView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [_reportTextView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [_reportTextView.heightAnchor constraintGreaterThanOrEqualToConstant:200],

        [indTitle.topAnchor constraintEqualToAnchor:_reportTextView.bottomAnchor constant:18],
        [indTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],

        [_indicatorsStack.topAnchor constraintEqualToAnchor:indTitle.bottomAnchor constant:8],
        [_indicatorsStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [_indicatorsStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [_indicatorsStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4]
    ]];
    return card;
}

#pragma mark - 状态切换(条件渲染)

- (void)applyState:(CrashDiagnosisState)state {
    _state = state;
    self.paywallCard.hidden = (state != CrashDiagnosisStatePaywall);
    self.loadingCard.hidden = (state != CrashDiagnosisStateLoading);
    self.reportCard.hidden  = (state != CrashDiagnosisStateResult);

    if (state == CrashDiagnosisStateLoading) {
        [self.indicator startAnimating];
    } else {
        [self.indicator stopAnimating];
    }
}

#pragma mark - 诊断流程

/// 「开始诊断」按钮:扣额度(占位)→ 进加载态 → 调引擎
- (void)startDiagnosis {
    [self decrementQuota];   // ponytail:占位扣减,StoreKit 后置再换
    self.streamingTextView.text = @"⏳ 正在分析飞行数据...\n\n";
    [self applyState:CrashDiagnosisStateLoading];
    [self runDiagnosis];
}

/// 调引擎:流式回调 → streamingTextView;完成回调 → 渲染结果
- (void)runDiagnosis {
    CrashDiagnosisEngine *engine = [CrashDiagnosisEngine shared];
    __weak typeof(self) weakSelf = self;

    engine.onStreamingText = ^(NSString *partialText) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.streamingTextView.text = partialText ?: @"";
    };

    [engine diagnoseCSVAtPath:self.csvPath
                   completion:^(CrashDiagnosisResult *result) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        engine.onStreamingText = nil;
        [strongSelf.indicator stopAnimating];
        strongSelf.lastResult = result;
        [strongSelf renderResult:result];
        [strongSelf applyState:CrashDiagnosisStateResult];
    }];
}

/// 渲染完成态:报告文本 + localIndicators 三块可视化
- (void)renderResult:(CrashDiagnosisResult *)result {
    // ① 报告文本(失败时显示错误)
    if (result.error && result.reportText.length == 0) {
        self.reportTextView.text = [NSString stringWithFormat:@"❌ 诊断失败\n\n%@", result.error.localizedDescription];
    } else {
        self.reportTextView.text = result.reportText ?: @"无诊断结果";
    }
    // ② localIndicators 可视化(1.1 算了没用 → 本屏接上)
    [self renderLocalIndicators:result.localIndicators ?: @[]];
}

- (void)renderLocalIndicators:(NSArray<CrashAnomalyIndicator *> *)indicators {
    // 清空旧卡
    NSArray<UIView *> *old = [self.indicatorsStack.arrangedSubviews copy];
    for (UIView *v in old) {
        [self.indicatorsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (indicators.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"✓ 本地未检测到明显异常指标";
        empty.textColor = [UIColor secondaryLabelColor];
        empty.font = [UIFont systemFontOfSize:13];
        empty.numberOfLines = 0;
        [self.indicatorsStack addArrangedSubview:empty];
        return;
    }

    // ②-1 因果链(文字):根因 → 结果
    NSString *causal = [self buildCausalChainText:indicators];
    if (causal.length > 0) {
        UILabel *chainLabel = [[UILabel alloc] init];
        chainLabel.text = causal;
        chainLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        chainLabel.textColor = [UIColor systemOrangeColor];
        chainLabel.numberOfLines = 0;
        [self.indicatorsStack addArrangedSubview:chainLabel];
    }

    // ②-2 每项一张指标卡(含 ②-3 内嵌时间线)
    for (CrashAnomalyIndicator *ind in indicators) {
        if (!ind.detected) continue;   // 只显示检测到的
        [self.indicatorsStack addArrangedSubview:[self buildIndicatorCard:ind]];
    }
}

/// 单项异常指标卡:severity 色边 + type/axis/根因标 + detail + 内嵌飞行进度时间线
- (UIView *)buildIndicatorCard:(CrashAnomalyIndicator *)ind {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [self colorForSeverity:ind.severity].CGColor;

    NSString *axisTag = ind.axis.length > 0
        ? [NSString stringWithFormat:@" [%@]", ind.axis.uppercaseString] : @"";
    NSString *rootTag = ind.isRootCause ? @"  🎯根因" : @"";

    UILabel *title = [[UILabel alloc] init];
    title.text = [NSString stringWithFormat:@"%@ %@%@%@",
                  [self emojiForSeverity:ind.severity], ind.type ?: @"异常", axisTag, rootTag];
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.numberOfLines = 0;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.text = ind.detail.length > 0 ? ind.detail : @"(无详细描述)";
    detail.font = [UIFont systemFontOfSize:12];
    detail.textColor = [UIColor secondaryLabelColor];
    detail.numberOfLines = 0;
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:detail];

    UIView *timeline = [self buildTimelineView:ind];
    timeline.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:timeline];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],

        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [detail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [detail.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],

        [timeline.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:8],
        [timeline.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [timeline.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [timeline.heightAnchor constraintEqualToConstant:26],
        [timeline.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10]
    ]];
    return card;
}

/// 飞行进度时间线:0%(起飞)── 区间条 ── ●peak ── 100%(结束)
/// peakOccurrenceRatio 标红点;first~last 标淡橙区间
- (UIView *)buildTimelineView:(CrashAnomalyIndicator *)ind {
    UIView *container = [[UIView alloc] init];

    double first = CrashClamp(ind.firstOccurrenceRatio, 0, 1);
    double last  = CrashClamp(ind.lastOccurrenceRatio,  0, 1);
    if (last < first) { double t = first; first = last; last = t; }
    double peak  = CrashClamp(ind.peakOccurrenceRatio,  0, 1);

    UIView *track = [[UIView alloc] init];
    track.backgroundColor = [UIColor systemGray5Color];
    track.layer.cornerRadius = 3;
    track.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:track];

    UIView *range = [[UIView alloc] init];
    range.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.4];
    range.layer.cornerRadius = 3;
    range.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:range];

    UIView *peakDot = [[UIView alloc] init];
    peakDot.backgroundColor = [UIColor systemRedColor];
    peakDot.layer.cornerRadius = 5;
    peakDot.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:peakDot];

    UILabel *leftLabel = [[UILabel alloc] init];
    leftLabel.text = @"起飞";
    leftLabel.font = [UIFont systemFontOfSize:9];
    leftLabel.textColor = [UIColor tertiaryLabelColor];
    leftLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:leftLabel];

    UILabel *rightLabel = [[UILabel alloc] init];
    rightLabel.text = @"结束";
    rightLabel.font = [UIFont systemFontOfSize:9];
    rightLabel.textColor = [UIColor tertiaryLabelColor];
    rightLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:rightLabel];

    // 🔑 leading/centerX 不能用 anchor multiplier(NSLayoutXAxisAnchor 无 multiplier API)
    //    用 NSLayoutConstraint toItem: container.trailing × ratio 实现按比例定位
    double firstMul = first < 0.001 ? 0.001 : first;
    double widthMul = MAX(0.001, last - first);
    double peakMul  = peak  < 0.001 ? 0.001 : peak;

    [NSLayoutConstraint activateConstraints:@[
        [track.topAnchor constraintEqualToAnchor:container.topAnchor],
        [track.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [track.heightAnchor constraintEqualToConstant:6],

        [NSLayoutConstraint constraintWithItem:range
                                     attribute:NSLayoutAttributeLeading
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:container
                                     attribute:NSLayoutAttributeTrailing
                                    multiplier:firstMul constant:0],
        [NSLayoutConstraint constraintWithItem:range
                                     attribute:NSLayoutAttributeWidth
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:container
                                     attribute:NSLayoutAttributeWidth
                                    multiplier:widthMul constant:0],
        [range.centerYAnchor constraintEqualToAnchor:track.centerYAnchor],
        [range.heightAnchor constraintEqualToConstant:6],

        [NSLayoutConstraint constraintWithItem:peakDot
                                     attribute:NSLayoutAttributeCenterX
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:container
                                     attribute:NSLayoutAttributeTrailing
                                    multiplier:peakMul constant:0],
        [peakDot.centerYAnchor constraintEqualToAnchor:track.centerYAnchor],
        [peakDot.widthAnchor constraintEqualToConstant:10],
        [peakDot.heightAnchor constraintEqualToConstant:10],

        [leftLabel.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:3],
        [leftLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [rightLabel.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:3],
        [rightLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor]
    ]];
    return container;
}

/// 因果链文字:根因(type) → 结果(causedBy 非空)
- (NSString *)buildCausalChainText:(NSArray<CrashAnomalyIndicator *> *)indicators {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSMutableArray<NSString *> *effects = [NSMutableArray array];
    for (CrashAnomalyIndicator *ind in indicators) {
        if (!ind.detected) continue;
        NSString *label = ind.axis.length > 0
            ? [NSString stringWithFormat:@"%@[%@]", ind.type, ind.axis] : ind.type;
        if (ind.isRootCause) {
            [roots addObject:label];
        } else if (ind.causedBy.length > 0) {
            [effects addObject:label];
        }
    }
    if (roots.count == 0 && effects.count == 0) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (roots.count > 0)   [parts addObject:[roots componentsJoinedByString:@"/"]];
    if (effects.count > 0) [parts addObject:[effects componentsJoinedByString:@"/"]];
    return [NSString stringWithFormat:@"🔗 因果链:%@", [parts componentsJoinedByString:@" → "]];
}

#pragma mark - Actions

- (void)startDiagnosisButtonTapped {
    [self startDiagnosis];
}

- (void)refreshDiagnosis:(UIBarButtonItem *)sender {
    [self startDiagnosis];
}

- (void)cancelDiagnosis:(UIBarButtonItem *)sender {
    [self.navigationController popViewControllerAnimated:YES];
}

/// 解锁按钮(IAP 占位)
- (void)unlockButtonTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"PRO 即将上线"
                         message:@"StoreKit 内购集成进行中,届时可解锁无限次炸机诊断。\n当前可使用免费额度。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 诊断上下文规则输入(持久化 NSUserDefaults,跨会话)
- (void)showDiagnosisSettings:(UIBarButtonItem *)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"诊断上下文规则"
                         message:@"输入自定义规则,AI 诊断时会遵守这些规则。\n留空则仅使用默认规则。"
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"例如:不要推荐 D 项调整;我的飞机是 5 寸穿越机";
        textField.text = [CrashDiagnosisEngine shared].userContext ?: @"";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            UITextField *textField = alert.textFields.firstObject;
            [CrashDiagnosisEngine shared].userContext = textField.text;
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 引擎清理

- (void)cleanupEngine {
    CrashDiagnosisEngine *engine = [CrashDiagnosisEngine shared];
    engine.onStreamingText = nil;
    [engine cancelCurrentRequest];
    [self.indicator stopAnimating];
}

#pragma mark - 免费额度(占位,StoreKit 后置再换)

- (NSInteger)remainingQuota {
    NSInteger q = [[NSUserDefaults standardUserDefaults] integerForKey:kCrashDiagQuotaKey];
    // ponytail:首次(默认 0)给默认额度;StoreKit 后置后由购买态决定
    return q > 0 ? q : kCrashDiagDefaultQuota;
}

- (void)decrementQuota {
    // ponytail:占位扣减,≤0 不拦截(实验阶段与 Q6 质量门同理:只显示不拦阻)
    NSInteger q = self.remainingQuota;
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(0, q - 1) forKey:kCrashDiagQuotaKey];
}

- (void)refreshQuotaLabel {
    self.quotaLabel.text = [NSString stringWithFormat:@"本月剩余 %ld 次免费诊断", (long)self.remainingQuota];
}

#pragma mark - Helpers

- (UIColor *)colorForSeverity:(NSString *)severity {
    if ([severity isEqualToString:@"high"])   return [UIColor systemRedColor];
    if ([severity isEqualToString:@"medium"]) return [UIColor systemYellowColor];
    return [UIColor systemGreenColor];
}

- (NSString *)emojiForSeverity:(NSString *)severity {
    if ([severity isEqualToString:@"high"])   return @"🔴";
    if ([severity isEqualToString:@"medium"]) return @"🟡";
    return @"🟢";
}

@end
