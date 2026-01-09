//
//  ViewController.m
//  PID_Liner
//
//  Created by 梁隽 on 2025/11/13.
//

#import "ViewController.h"
#import "BlackboxDecoder.h"
#import "CSVHistoryViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
    self.isUsingImportedFile = NO;  // 默认使用内置文件

    // 🔥 启动时清理沙盒中上次导入的BBL文件（保留CSV文件）
    [self cleanupImportedBBLFiles];

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

    // ========== 进度条 ==========
    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = [UIColor systemBlueColor];
    _progressView.trackTintColor = [UIColor systemGray4Color];
    _progressView.hidden = YES;  // 初始隐藏
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_progressView];

    // ========== 导入BBL文件按钮 ==========
    _importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_importButton setTitle:@"📂 导入BBL文件" forState:UIControlStateNormal];
    _importButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _importButton.backgroundColor = [UIColor clearColor];
    [_importButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    _importButton.layer.borderWidth = 1;
    _importButton.layer.borderColor = [UIColor systemGray3Color].CGColor;
    _importButton.layer.cornerRadius = 8;
    _importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_importButton addTarget:self action:@selector(importButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_importButton];

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

        // 导入按钮（在状态标签下方）
        [_importButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_importButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:15],
        [_importButton.widthAnchor constraintEqualToConstant:200],
        [_importButton.heightAnchor constraintEqualToConstant:36],

        // 进度条
        [_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
        [_progressView.topAnchor constraintEqualToAnchor:_importButton.bottomAnchor constant:15],
        [_progressView.heightAnchor constraintEqualToConstant:4],

        // 日志文本视图
        [_logTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_logTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_logTextView.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor constant:15],
        [_logTextView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20]
    ]];
}

#pragma mark - Data Loading

- (void)loadBBLFile {
    NSLog(@"loadBBLFile() - 加载BBL文件");

    // 获取Documents目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];

    // 🔥 优先查找沙盒中的BBL文件（用户导入的）
    NSString *bblPath = nil;
    self.isUsingImportedFile = NO;

    // 查找Documents目录下所有.bbl文件
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *documentsFiles = [fm contentsOfDirectoryAtPath:documentsDir error:nil];
    for (NSString *file in documentsFiles) {
        if ([file.pathExtension isEqualToString:@"bbl"]) {
            bblPath = [documentsDir stringByAppendingPathComponent:file];
            self.isUsingImportedFile = YES;
            NSLog(@"📂 找到沙盒BBL文件: %@", file);
            break;
        }
    }

    // 如果沙盒没有，使用Bundle默认文件
    if (!bblPath) {
        bblPath = [[NSBundle mainBundle] pathForResource:@"001" ofType:@"bbl"];
        self.isUsingImportedFile = NO;
    }

    if (!bblPath || ![[NSFileManager defaultManager] fileExistsAtPath:bblPath]) {
        _statusLabel.text = @"❌ 找不到BBL文件";
        [_sessionSelectButton setTitle:@"无可用文件" forState:UIControlStateNormal];
        _sessionSelectButton.enabled = NO;
        _convertButton.enabled = NO;
        _importButton.enabled = NO;
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

    // 🔥 显示文件名，区分内置/导入
    NSString *fileName = [_currentBBLPath lastPathComponent];
    NSString *fileLabel = _isUsingImportedFile ?
        [NSString stringWithFormat:@"📄 %@ (已导入)", fileName] :
        [NSString stringWithFormat:@"📄 %@", fileName];

    _statusLabel.text = [NSString stringWithFormat:@"%@\n共 %lu 个 Session 可选",
                          fileLabel, (unsigned long)_sessions.count];

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

/// 更新当前BBL状态显示（刷新蓝/绿按钮指向）
- (void)updateCurrentBBLStatus {
    // 更新Session按钮标题
    [self updateSessionButtonTitle];

    // 确保按钮可用
    _sessionSelectButton.enabled = _sessions.count > 0;
    _convertButton.enabled = _sessions.count > 0;
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

    // 显示并重置进度条
    _progressView.hidden = NO;
    _progressView.progress = 0.0;

    // 获取总Session数量
    NSInteger startIndex = 0;
    NSInteger endIndex = _sessions.count;
    if (_selectedSessionIndex >= 0 && _selectedSessionIndex < (NSInteger)_sessions.count) {
        startIndex = _selectedSessionIndex;
        endIndex = _selectedSessionIndex + 1;
    }
    NSInteger totalSessions = endIndex - startIndex;

    // 后台线程执行转换（不阻塞UI）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray<NSString *> *generatedFiles = [NSMutableArray array];
        NSMutableString *logText = [NSMutableString stringWithString:@"=== 转换日志 ===\n\n"];
        BOOL allSuccess = YES;

        // 逐个转换Session
        for (NSInteger i = startIndex; i < endIndex; i++) {
            BBLSessionInfo *session = _sessions[i];
            NSLog(@"转换 Session %ld...", (long)i + 1);

            [logText appendFormat:@"📝 转换 Session %d...\n", session.logIndex + 1];

            // 生成CSV文件名：{源文件}_{日期}_{时间戳}_session{N}.csv
            NSString *csvFileName = [self generateCSVFileName:self.currentBBLPath sessionIndex:session.logIndex];
            NSString *outputPath = [self.decoder.outputDirectory stringByAppendingPathComponent:csvFileName];

            // 更新进度（当前Session/总Session数）
            float currentProgress = (float)(i - startIndex + 1) / (float)totalSessions;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressView.progress = currentProgress;
                self.statusLabel.text = [NSString stringWithFormat:@"⏳ 转换中... %ld/%ld",
                                        (long)(i - startIndex + 1), (long)totalSessions];
            });

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

        // 更新UI（完成）
        dispatch_async(dispatch_get_main_queue(), ^{
            self.convertButton.enabled = YES;
            self.sessionSelectButton.enabled = YES;

            // 隐藏进度条
            self.progressView.hidden = YES;
            self.progressView.progress = 0.0;

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

#pragma mark - Import BBL File

/// 清理沙盒中导入的BBL文件（启动时调用，保留CSV文件）
- (void)cleanupImportedBBLFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];

    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:documentsDir error:&error];

    if (error) {
        NSLog(@"⚠️ 无法读取Documents目录: %@", error.localizedDescription);
        return;
    }

    NSInteger cleanedCount = 0;
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"bbl"]) {
            NSString *filePath = [documentsDir stringByAppendingPathComponent:file];
            if ([fm removeItemAtPath:filePath error:nil]) {
                cleanedCount++;
                NSLog(@"🧹 清理导入文件: %@", file);
            }
        }
    }

    if (cleanedCount > 0) {
        NSLog(@"✅ 清理了 %ld 个导入的BBL文件", (long)cleanedCount);
    }
}

/// 导入按钮点击
- (void)importButtonTapped:(UIButton *)sender {
    NSLog(@"importButtonTapped() - 打开文件选择器");

    // 🔥 使用旧的 API（iOS 11+），接受所有文件类型
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                                inMode:UIDocumentPickerModeImport];

    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationPageSheet;

    [self presentViewController:picker animated:YES completion:^{
        NSLog(@"文件选择器已弹出");
    }];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {

    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) {
        return;
    }

    NSString *fileName = sourceURL.lastPathComponent;
    NSLog(@"📂 用户选择文件: %@", fileName);

    // 🔥 获取文件扩展名（小写）
    NSString *extension = [fileName.pathExtension lowercaseString];

    // 🔥 只接受 .bbl 和 .csv 文件
    if (![extension isEqualToString:@"bbl"] && ![extension isEqualToString:@"csv"]) {
        NSLog(@"❌ 文件类型错误: %@ (只支持.bbl和.csv文件)", extension);
        _statusLabel.text = [NSString stringWithFormat:@"❌ 文件类型错误\n只能导入 .bbl 或 .csv 文件\n您选择了: .%@", extension];
        return;
    }

    // 安全访问资源
    [sourceURL startAccessingSecurityScopedResource];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];

    // 🔥 保留原文件名，复制到沙盒
    NSString *destFileName = sourceURL.lastPathComponent;
    NSString *destPath = [documentsDir stringByAppendingPathComponent:destFileName];

    // 如果目标文件已存在，先删除
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }

    NSError *error = nil;
    BOOL success = [fm copyItemAtPath:sourceURL.path toPath:destPath error:&error];

    [sourceURL stopAccessingSecurityScopedResource];

    if (!success) {
        NSLog(@"❌ 文件复制失败: %@", error.localizedDescription);
        _statusLabel.text = [NSString stringWithFormat:@"❌ 导入失败: %@", error.localizedDescription];
        return;
    }

    NSLog(@"✅ 文件复制成功: %@", destFileName);

    // 🔥 统一处理：BBL 自动转换，CSV 验证后添加到历史记录
    if ([extension isEqualToString:@"bbl"]) {
        // BBL 文件：设置为当前文件，用户可选择转换
        _currentBBLPath = destPath;
        _isUsingImportedFile = YES;
        [self loadSessionList];
        _statusLabel.text = [NSString stringWithFormat:@"✅ 已导入: %@\n请在上方选择 Session 后点击转换", destFileName];
    } else if ([extension isEqualToString:@"csv"]) {
        // CSV 文件：验证是否是有效的 BBL CSV
        if ([self validateBBLCSV:destPath]) {
            // ✅ 有效的 CSV，保留在沙盒，历史记录可见
            // 重新显示当前BBL的状态，保持蓝/绿按钮正确
            [self updateCurrentBBLStatus];
            _statusLabel.text = [NSString stringWithFormat:@"✅ CSV 已导入，可在历史记录查看\n%@", destFileName];
            NSLog(@"✅ 验证通过: 有效的 BBL CSV 文件");
        } else {
            // ❌ 无效的 CSV：保留文件，重新显示当前BBL状态，蓝/绿按钮保持正确
            [self updateCurrentBBLStatus];
            NSString *currentFile = [_currentBBLPath lastPathComponent];
            _statusLabel.text = [NSString stringWithFormat:@"⚠️ 不是飞行数据CSV\n文件已保留但无法使用\n当前操作: %@ (%lu个Session)",
                                  currentFile, (unsigned long)_sessions.count];
            NSLog(@"❌ 验证失败: 不是 BBL 转换的 CSV，文件保留，当前操作对象不变");
        }
    }
}

/// 验证 CSV 文件是否是 BBL 转换的（检查头部特征列）
- (BOOL)validateBBLCSV:(NSString *)filePath {
    // 🔥 读取 CSV 文件，检查是否包含 BBL CSV 的特征列
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:filePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (error || !content) {
        NSLog(@"❌ 无法读取 CSV 文件: %@", error.localizedDescription);
        return NO;
    }

    // 🔥 获取第一行（表头）
    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (lines.count == 0) {
        return NO;
    }

    NSString *headerLine = lines[0];
    // 🔥 检查是否包含 BBL CSV 的特征列
    // BBL CSV 包含: time (us/ms), rcCommand, setpoint, gyroADC, motor 等
    BOOL hasTimeColumn = [headerLine containsString:@"time (us)"] ||
                         [headerLine containsString:@"time (ms)"] ||
                         [headerLine containsString:@"time[ms]"] ||
                         [headerLine containsString:@"time[us]"];
    BOOL hasDataColumn = [headerLine containsString:@"rcCommand"] ||
                         [headerLine containsString:@"setpoint"] ||
                         [headerLine containsString:@"gyroADC"] ||
                         [headerLine containsString:@"motor["];

    BOOL isValid = hasTimeColumn && hasDataColumn;

    NSLog(@"📋 CSV 表头: %@", [headerLine substringToIndex:MIN(headerLine.length, 150)]);
    NSLog(@"🔍 包含 time 列: %@, 包含数据列: %@", hasTimeColumn ? @"✅" : @"❌", hasDataColumn ? @"✅" : @"❌");

    return isValid;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSLog(@"documentPickerWasCancelled() - 用户取消选择");
}

@end
