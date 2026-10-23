//
//  NBBaseViewController.m
//  PID_Liner
//

#import "NBBaseViewController.h"

@implementation NBBaseViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyStandardNavigationBarStyle];
}

/// V3 统一导航:云白底 + 发丝分割 + 墨色标题;返回键 = 白圆底 chevron(带防连点,保留侧滑)
- (void)applyStandardNavigationBarStyle {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = NBTheme.bg;
    appearance.shadowColor = NBTheme.hairline;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: NBTheme.ink};
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;

    self.navigationController.navigationBar.tintColor = NBTheme.ink;

    // 白圆返回键(页面自己没挂左侧按钮时才装;根页面/自定义左键的页面自动跳过)
    if (self.navigationController.topViewController == self &&
        self.navigationItem.leftBarButtonItem == nil &&
        self.navigationController.viewControllers.firstObject != self) {
        [self installStyledBackButton];
        // 自定义返回键会关掉系统侧滑,把 gesture delegate 置空以保留侧滑返回
        self.navigationController.interactivePopGestureRecognizer.delegate = nil;
    }

    // 空标题 back item:下一页的返回键不带「Back」文字
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
}

- (void)installStyledBackButton {
    // 极简返回键:一个 < 而已(无圆框无文字)
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.frame = CGRectMake(0, 0, 34, 32);
    [back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];
    [back setTintColor:NBTheme.dim];
    [back addTarget:self action:@selector(styledBackTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:back];
}

- (void)styledBackTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

@end
