//
//  ViewController.m
//  PID_Liner
//
//  Created by 梁隽 on 2025/11/13.
//

#import "ViewController.h"
#import "BlackboxDecoder.h"
#import "CSVHistoryViewController.h"

@interface ViewController ()
@property (nonatomic, strong) BlackboxDecoder *decoder;
@property (nonatomic, strong) UINavigationController *navController;
@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@",[NSString stringWithUTF8String:object_getClassName(self)]);
    self.decoder = [[BlackboxDecoder alloc] init];
    self.selectedSessionIndex = -1; // 默认全部

    [self setupUI];
    [self loadBBLFile];
}

#pragma mark - UI Setup

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"PID Liner";

    // 设置右上角"历史"按钮
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(historyButtonTapped)];

    CGFloat buttonWidth = 280;
    CGFloat buttonHeight = 50;

    // ========== Session选择按钮（下拉选择样式）==========
    _sessionSelectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_sessionSelectButton setTitle:@"选择 Session ▼" forState:UIControlStateNormal];
    _sessionSelectButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _sessionSelectButton.backgroundColor = [UIColor systemBlueColor];
    [_sessionSelectButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _sessionSelectButton.layer.cornerRadius = 8;
    _sessionSelectButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_sessionSelectButton addTarget:self action:@selector(sessionSelectButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_sessionSelectButton];

    // ========== 转换按钮 ==========
    _convertButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_convertButton setTitle:@"转换 BBL → CSV" forState:UIControlStateNormal];
    _convertButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _convertButton.backgroundColor = [UIColor systemGreenColor];
    [_convertButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _convertButton.layer.cornerRadius = 10;
    _convertButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_convertButton addTarget:self action:@selector(convertButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_convertButton];

    // ========== 状态标签 ==========
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"准备就绪";
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.font = [UIFont systemFontOfSize:15];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // ========== 日志文本视图 ==========
    _logTextView = [[UITextView alloc] init];
    _logTextView.editable = NO;
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _logTextView.layer.cornerRadius = 8;
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logTextView];

    // ========== 设置约束 ==========
    [NSLayoutConstraint activateConstraints:@[
        // Session选择按钮
        [_sessionSelectButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_sessionSelectButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:30],
        [_sessionSelectButton.widthAnchor constraintEqualToConstant:buttonWidth],
        [_sessionSelectButton.heightAnchor constraintEqualToConstant:buttonHeight],

        // 转换按钮
        [_convertButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_convertButton.topAnchor constraintEqualToAnchor:_sessionSelectButton.bottomAnchor constant:20],
        [_convertButton.widthAnchor constraintEqualToConstant:buttonWidth],
        [_convertButton.heightAnchor constraintEqualToConstant:buttonHeight],

        // 状态标签
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_statusLabel.topAnchor constraintEqualToAnchor:_convertButton.bottomAnchor constant:20],

        // 日志文本视图
        [_logTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_logTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_logTextView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:15],
        [_logTextView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20]
    ]];
}

#pragma mark - Data Loading

- (void)loadBBLFile {
    NSLog(@"loadBBLFile() - 加载BBL文件");

    // 获取Documents目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];

    // 查找BBL文件
    NSString *bblPath = [documentsDir stringByAppendingPathComponent:@"003.bbl"];

    // 如果Documents目录没有，尝试从Bundle读取
    if (![[NSFileManager defaultManager] fileExistsAtPath:bblPath]) {
        bblPath = [[NSBundle mainBundle] pathForResource:@"003" ofType:@"bbl"];
    }

    if (!bblPath || ![[NSFileManager defaultManager] fileExistsAtPath:bblPath]) {
        _statusLabel.text = @"❌ 找不到BBL文件";
        [_sessionSelectButton setTitle:@"无可用文件" forState:UIControlStateNormal];
        _sessionSelectButton.enabled = NO;
        _convertButton.enabled = NO;
        return;
    }

    _currentBBLPath = bblPath;
    NSLog(@"✅ 找到BBL文件: %@", bblPath);

    // 加载Session列表
    [self loadSessionList];
}

- (void)loadSessionList {
    NSLog(@"loadSessionList() - 加载Session列表");

    if (!_currentBBLPath) {
        return;
    }

    // 设置输出目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    _decoder.outputDirectory = [paths firstObject];

    // 获取Session列表
    _sessions = [_decoder listLogs:_currentBBLPath];

    if (_sessions.count == 0) {
        _statusLabel.text = @"❌ 无法解析BBL文件";
        [_sessionSelectButton setTitle:@"解析失败" forState:UIControlStateNormal];
        _sessionSelectButton.enabled = NO;
        _convertButton.enabled = NO;
        return;
    }

    NSLog(@"✅ 找到 %lu 个Session", (unsigned long)_sessions.count);

    // 更新UI
    _selectedSessionIndex = -1; // 默认全部
    [self updateSessionButtonTitle];

    NSString *fileName = [_currentBBLPath lastPathComponent];
    _statusLabel.text = [NSString stringWithFormat:@"📄 %@\n共 %lu 个 Session 可选", fileName, (unsigned long)_sessions.count];

    // 显示Session信息
    NSMutableString *logText = [NSMutableString stringWithString:@"=== Session 列表 ===\n\n"];
    for (BBLSessionInfo *session in _sessions) {
        [logText appendFormat:@"%@\n", session.description];
    }
    _logTextView.text = logText;
}

- (void)updateSessionButtonTitle {
    NSString *title;
    if (_selectedSessionIndex < 0) {
        title = [NSString stringWithFormat:@"全部 Session (%lu个) ▼", (unsigned long)_sessions.count];
    } else if (_selectedSessionIndex < (NSInteger)_sessions.count) {
        BBLSessionInfo *session = _sessions[_selectedSessionIndex];
        title = [NSString stringWithFormat:@"Session %d ▼", session.logIndex + 1];
    } else {
        title = @"选择 Session ▼";
    }
    [_sessionSelectButton setTitle:title forState:UIControlStateNormal];
}

#pragma mark - Button Actions

- (void)sessionSelectButtonTapped:(UIButton *)sender {
    NSLog(@"sessionSelectButtonTapped() - 显示Session选择");

    if (_sessions.count == 0) {
        return;
    }

    // 使用ActionSheet实现下拉选择（兼容任意数量的Session）
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"选择要转换的 Session"
        message:[NSString stringWithFormat:@"共 %lu 个 Session", (unsigned long)_sessions.count]
        preferredStyle:UIAlertControllerStyleActionSheet];

    // "全部"选项
    UIAlertAction *allAction = [UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"✅ 全部转换 (%lu个)", (unsigned long)_sessions.count]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            self.selectedSessionIndex = -1;
            [self updateSessionButtonTitle];
            NSLog(@"选择: 全部Session");
        }];
    [alert addAction:allAction];

    // 各个Session选项
    for (NSInteger i = 0; i < (NSInteger)_sessions.count; i++) {
        BBLSessionInfo *session = _sessions[i];
        NSString *title = [NSString stringWithFormat:@"Session %d - %@",
                           session.logIndex + 1,
                           session.description];

        UIAlertAction *action = [UIAlertAction
            actionWithTitle:title
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                self.selectedSessionIndex = i;
                [self updateSessionButtonTitle];
                NSLog(@"选择: Session %ld", (long)i + 1);
            }];
        [alert addAction:action];
    }

    // 取消按钮
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad适配
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sender;
        alert.popoverPresentationController.sourceRect = sender.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)convertButtonTapped:(UIButton *)sender {
    NSLog(@"convertButtonTapped() - 开始转换");
    [self convertBBLToCSV];
}

- (void)historyButtonTapped {
    NSLog(@"historyButtonTapped() - 打开历史记录");

    CSVHistoryViewController *historyVC = [[CSVHistoryViewController alloc] init];
    [self.navigationController pushViewController:historyVC animated:YES];
}

#pragma mark - Conversion

- (void)convertBBLToCSV {
    NSLog(@"convertBBLToCSV() - 开始转换流程");

    if (!_currentBBLPath || _sessions.count == 0) {
        _statusLabel.text = @"❌ 没有可转换的文件";
        return;
    }

    // 禁用按钮，防止重复点击
    _convertButton.enabled = NO;
    _sessionSelectButton.enabled = NO;
    _statusLabel.text = @"⏳ 正在转换...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSString *> *generatedFiles = [NSMutableArray array];
        NSMutableString *logText = [NSMutableString stringWithString:@"=== 转换日志 ===\n\n"];
        BOOL allSuccess = YES;

        // 确定要转换的Session范围
        NSInteger startIndex = 0;
        NSInteger endIndex = self.sessions.count;

        if (self.selectedSessionIndex >= 0 && self.selectedSessionIndex < (NSInteger)self.sessions.count) {
            startIndex = self.selectedSessionIndex;
            endIndex = self.selectedSessionIndex + 1;
        }

        // 逐个转换Session
        for (NSInteger i = startIndex; i < endIndex; i++) {
            BBLSessionInfo *session = self.sessions[i];
            NSLog(@"转换 Session %ld...", (long)i + 1);

            [logText appendFormat:@"📝 转换 Session %d...\n", session.logIndex + 1];

            // 生成CSV文件名：{源文件}_{日期}_{时间戳}_session{N}.csv
            NSString *csvFileName = [self generateCSVFileName:self.currentBBLPath sessionIndex:session.logIndex];
            NSString *outputPath = [self.decoder.outputDirectory stringByAppendingPathComponent:csvFileName];

            // 执行解码
            int result = [self.decoder decodeFlightLog:self.currentBBLPath logIndex:session.logIndex];

            if (result == 0) {
                // 解码成功，重命名文件为新格式
                NSString *originalFileName = [NSString stringWithFormat:@"%@.%02d.csv",
                    [[self.currentBBLPath lastPathComponent] stringByDeletingPathExtension],
                    session.logIndex + 1];
                NSString *originalPath = [self.decoder.outputDirectory stringByAppendingPathComponent:originalFileName];

                NSError *error = nil;

                // 如果目标文件已存在，先删除
                if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
                    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
                }

                // 重命名文件
                if ([[NSFileManager defaultManager] moveItemAtPath:originalPath toPath:outputPath error:&error]) {
                    [generatedFiles addObject:csvFileName];
                    [logText appendFormat:@"   ✅ 生成: %@\n", csvFileName];
                    NSLog(@"✅ Session %ld 转换成功: %@", (long)i + 1, csvFileName);
                } else {
                    // 如果重命名失败，使用原文件名
                    [generatedFiles addObject:originalFileName];
                    [logText appendFormat:@"   ✅ 生成: %@\n", originalFileName];
                    NSLog(@"⚠️ 重命名失败，使用原文件名: %@", error.localizedDescription);
                }
            } else {
                allSuccess = NO;
                [logText appendFormat:@"   ❌ 转换失败: %@\n", self.decoder.lastErrorMessage];
                NSLog(@"❌ Session %ld 转换失败", (long)i + 1);
            }
        }

        // 更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            self.convertButton.enabled = YES;
            self.sessionSelectButton.enabled = YES;

            if (allSuccess) {
                self.statusLabel.text = [NSString stringWithFormat:@"✅ 转换完成！\n生成 %lu 个CSV文件",
                                         (unsigned long)generatedFiles.count];
            } else {
                self.statusLabel.text = @"⚠️ 部分转换失败，请查看日志";
            }

            [logText appendString:@"\n=== 转换完成 ==="];
            self.logTextView.text = logText;
        });
    });
}

#pragma mark - Helper Methods

/// 生成CSV文件名：{源文件}_{日期}_{时间戳}_session{N}.csv
- (NSString *)generateCSVFileName:(NSString *)bblPath sessionIndex:(NSInteger)sessionIndex {
    // 获取源文件名（不含扩展名）
    NSString *baseName = [[bblPath lastPathComponent] stringByDeletingPathExtension];

    // 生成日期时间戳：yyyyMMdd_HHmmss
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    // 组合文件名：{源文件}_{日期}_{时间戳}_session{N}.csv
    NSString *fileName = [NSString stringWithFormat:@"%@_%@_session%ld.csv",
                          baseName, timestamp, (long)sessionIndex + 1];

    return fileName;
}

@end
