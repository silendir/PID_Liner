//
//  CSVRenameView.m
//  PID_Liner
//
//  CSV 文件重命名弹窗 View 实现
//

#import "CSVRenameView.h"
#import "CSVHistoryViewController.h"

@interface CSVRenameView () <UITextFieldDelegate>

@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *indicatorLabel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UILabel *originalFileNameLabel;  // 🔑 升为属性:setRecord 后才填文本(见 setRecord:)
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *confirmButton;
@property (nonatomic, strong) CSVRecord *record;
@property (nonatomic, copy) CSVRenameCompletion completion;
@property (nonatomic, copy) CSVRenameCancelCompletion cancelCompletion;

// 🔥 键盘避让相关
@property (nonatomic, strong) NSLayoutConstraint *containerCenterYConstraint;

@end

@implementation CSVRenameView

+ (void)showWithRecord:(CSVRecord *)record
             completion:(CSVRenameCompletion)completion
        cancelCompletion:(CSVRenameCancelCompletion)cancelCompletion {

    // 获取主窗口
    UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
    if (!window) {
        window = [UIApplication sharedApplication].keyWindow;
    }

    // 创建全屏遮罩
    CSVRenameView *renameView = [[CSVRenameView alloc] initWithFrame:window.bounds];
    renameView.record = record;
    renameView.completion = completion;
    renameView.cancelCompletion = cancelCompletion;

    [window addSubview:renameView];

    // 添加出现动画
    renameView.alpha = 0;
    renameView.containerView.transform = CGAffineTransformMakeScale(0.9, 0.9);

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        renameView.alpha = 1;
        renameView.containerView.transform = CGAffineTransformIdentity;
    } completion:nil];

    // 自动聚焦输入框
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [renameView.textField becomeFirstResponder];
    });
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

/// 🔑 record 赋值后回填 UI(showWithRecord 里 initWithFrame 先跑、record 后赋值,
/// setupUI 里读 _record 必为 nil → 文件名(null)+别名不回填)
- (void)setRecord:(CSVRecord *)record {
    _record = record;

    // 已有别名回填输入框
    if (_record.hasCustomName) {
        _textField.text = [_record.displayName stringByDeletingPathExtension];
    }

    // 当前文件名(超 40 字符保留尾部截断)
    NSString *displayFileName = _record.fileName ?: @"(未知)";
    if (displayFileName.length > 40) {
        displayFileName = [NSString stringWithFormat:@"...%@",
            [displayFileName substringFromIndex:displayFileName.length - 37]];
    }
    _originalFileNameLabel.text = [NSString stringWithFormat:@"当前文件名：%@", displayFileName];

    [self updateIndicator];
}

- (void)setupUI {
    // 半透明背景
    self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];

    // 点击背景取消
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped)];
    [self addGestureRecognizer:tap];

    // 🔥 容器视图
    _containerView = [[UIView alloc] init];
    _containerView.translatesAutoresizingMaskIntoConstraints = NO;
    _containerView.backgroundColor = [UIColor systemBackgroundColor];
    _containerView.layer.cornerRadius = 16;
    _containerView.layer.masksToBounds = YES;
    [self addSubview:_containerView];

    // 标题
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"重命名";
    titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [_containerView addSubview:titleLabel];

    // 🔥 文件名指示器
    _indicatorLabel = [[UILabel alloc] init];
    _indicatorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _indicatorLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _indicatorLabel.textAlignment = NSTextAlignmentCenter;
    _indicatorLabel.numberOfLines = 0;
    [_containerView addSubview:_indicatorLabel];

    // 🔥 输入框
    _textField = [[UITextField alloc] init];
    _textField.translatesAutoresizingMaskIntoConstraints = NO;
    _textField.borderStyle = UITextBorderStyleRoundedRect;
    _textField.font = [UIFont systemFontOfSize:16];
    _textField.placeholder = @"输入别名";
    _textField.delegate = self;

    // 🔑 record 相关回填(别名预填/当前文件名)全部移入 setRecord: ——
    // setupUI 跑在 initWithFrame 时 _record 还没赋值,在这里读必为 nil
    // → "当前文件名：(null)"+别名不回填(稳定版同病,真机已踩)

    // 添加输入变化监听
    [_textField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [_containerView addSubview:_textField];

    // 当前文件名标签(文本由 setRecord: 填)
    _originalFileNameLabel = [[UILabel alloc] init];
    _originalFileNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _originalFileNameLabel.font = [UIFont systemFontOfSize:13];
    _originalFileNameLabel.textColor = [UIColor secondaryLabelColor];
    _originalFileNameLabel.textAlignment = NSTextAlignmentCenter;
    _originalFileNameLabel.numberOfLines = 0;
    [_containerView addSubview:_originalFileNameLabel];

    // 分隔线
    UIView *separatorLine = [[UIView alloc] init];
    separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    separatorLine.backgroundColor = [UIColor separatorColor];
    [_containerView addSubview:separatorLine];

    // 🔥 按钮容器
    UIStackView *buttonStack = [[UIStackView alloc] init];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisHorizontal;
    buttonStack.distribution = UIStackViewDistributionFillEqually;
    buttonStack.spacing = 16;
    [_containerView addSubview:buttonStack];

    // 取消按钮
    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [_cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    _cancelButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _cancelButton.layer.cornerRadius = 12;
    _cancelButton.contentEdgeInsets = UIEdgeInsetsMake(12, 0, 12, 0);
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [buttonStack addArrangedSubview:_cancelButton];

    // 确定按钮
    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_confirmButton setTitle:@"确定" forState:UIControlStateNormal];
    _confirmButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_confirmButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _confirmButton.backgroundColor = [UIColor systemBlueColor];
    _confirmButton.layer.cornerRadius = 12;
    _confirmButton.contentEdgeInsets = UIEdgeInsetsMake(12, 0, 12, 0);
    [_confirmButton addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];
    [buttonStack addArrangedSubview:_confirmButton];

    // 🔥 存储 centerY 约束（用于键盘避让）
    _containerCenterYConstraint = [_containerView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor];
    _containerCenterYConstraint.active = YES;

    // 约束
    [NSLayoutConstraint activateConstraints:@[
        // 容器居中（centerY 已在上面设置）
        [_containerView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_containerView.widthAnchor constraintEqualToConstant:320],
        [_containerView.heightAnchor constraintEqualToConstant:300],

        // 标题
        [titleLabel.topAnchor constraintEqualToAnchor:_containerView.topAnchor constant:20],
        [titleLabel.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-20],

        // 指示器
        [_indicatorLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20],
        [_indicatorLabel.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:20],
        [_indicatorLabel.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-20],
        [_indicatorLabel.heightAnchor constraintEqualToConstant:40],

        // 输入框
        [_textField.topAnchor constraintEqualToAnchor:_indicatorLabel.bottomAnchor constant:12],
        [_textField.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:20],
        [_textField.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-20],
        [_textField.heightAnchor constraintEqualToConstant:40],

        // 当前文件名
        [_originalFileNameLabel.topAnchor constraintEqualToAnchor:_textField.bottomAnchor constant:8],
        [_originalFileNameLabel.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:20],
        [_originalFileNameLabel.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-20],

        // 分隔线
        [separatorLine.topAnchor constraintEqualToAnchor:_originalFileNameLabel.bottomAnchor constant:16],
        [separatorLine.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor],
        [separatorLine.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor],
        [separatorLine.heightAnchor constraintEqualToConstant:0.5],

        // 按钮容器
        [buttonStack.topAnchor constraintEqualToAnchor:separatorLine.bottomAnchor constant:12],
        [buttonStack.leadingAnchor constraintEqualToAnchor:_containerView.leadingAnchor constant:20],
        [buttonStack.trailingAnchor constraintEqualToAnchor:_containerView.trailingAnchor constant:-20],
        [buttonStack.bottomAnchor constraintEqualToAnchor:_containerView.bottomAnchor constant:-12],
        [buttonStack.heightAnchor constraintEqualToConstant:48],
    ]];

    // 初始化指示器
    [self updateIndicator];

    // 🔥 监听键盘显示/隐藏通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

/**
 * 🔥 输入框变化时更新指示器
 */
- (void)textFieldDidChange:(UITextField *)sender {
    [self updateIndicator];
}

/**
 * 🔥 更新文件名指示器
 */
- (void)updateIndicator {
    NSString *inputText = _textField.text ?: @"";
    NSString *trimmedText = [inputText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if (trimmedText.length > 0) {
        // 有输入，显示重命名后的文件名
        NSString *aliasWithExt = [trimmedText stringByAppendingPathExtension:@"csv"];
        _indicatorLabel.text = aliasWithExt;
        _indicatorLabel.textColor = [UIColor labelColor];
    } else {
        // 输入为空，显示还原提示
        _indicatorLabel.text = @"输入为空时还原原始文件名";
        _indicatorLabel.textColor = [UIColor secondaryLabelColor];
    }
}

/**
 * 点击背景取消
 */
- (void)backgroundTapped {
    [self dismiss];
}

/**
 * 取消按钮点击
 */
- (void)cancelTapped {
    [self dismiss];
    if (_cancelCompletion) {
        _cancelCompletion();
    }
}

/**
 * 确定按钮点击
 */
- (void)confirmTapped {
    NSString *inputText = _textField.text ?: @"";
    NSString *trimmedText = [inputText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    [self dismiss];

    if (_completion) {
        _completion(trimmedText);
    }
}

/**
 * 隐藏弹窗
 */
- (void)dismiss {
    // 🔥 移除键盘通知监听
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0;
        self.containerView.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

/**
 * 🔥 键盘将要显示 - 向上移动弹窗避让键盘
 */
- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat keyboardHeight = keyboardFrame.size.height;

    // 计算需要向上移动的距离（键盘高度的一半 + 额外间距）
    CGFloat offset = -keyboardHeight / 2 - 40;

    [UIView animateWithDuration:0.25 animations:^{
        self.containerCenterYConstraint.constant = offset;
        [self layoutIfNeeded];
    }];
}

/**
 * 🔥 键盘将要隐藏 - 恢复原位
 */
- (void)keyboardWillHide:(NSNotification *)notification {
    [UIView animateWithDuration:0.25 animations:^{
        self.containerCenterYConstraint.constant = 0;
        [self layoutIfNeeded];
    }];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self confirmTapped];
    return NO;
}

@end
