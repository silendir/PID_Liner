//
//  CSVHistoryViewController.m
//  PID_Liner
//
//  CSV转换历史记录页面实现
//

#import "CSVHistoryViewController.h"
#import "PIDAnalysisViewController.h"
#import "CrashDiagnosisEngine.h"

#pragma mark - CSVRecord Implementation

@implementation CSVRecord

- (instancetype)initWithFileName:(NSString *)fileName
                        filePath:(NSString *)filePath
                       sourceBBL:(NSString *)sourceBBL
                    sessionIndex:(NSInteger)sessionIndex {
    self = [super init];
    if (self) {
        _fileName = fileName;
        _filePath = filePath;
        _sourceBBL = sourceBBL;
        _sessionIndex = sessionIndex;
        _createTime = [NSDate date];
        _fileSize = 0;
        _lineCount = 0;

        // 获取文件信息
        [self loadFileInfo];
    }
    return self;
}

- (void)loadFileInfo {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:_filePath error:nil];
    if (attrs) {
        _fileSize = [attrs[NSFileSize] integerValue];
        _createTime = attrs[NSFileCreationDate] ?: [NSDate date];
    }

    // 使用流式读取统计行数，避免大文件导致内存问题
    _lineCount = [self countLinesInFileStreaming:_filePath maxLines:100000];
}

/// 流式读取文件统计行数，设置上限避免超大文件卡顿
/// @param filePath 文件路径
/// @param maxLines 最大统计行数，超过则返回该值（表示 "N+ 行"）
- (NSInteger)countLinesInFileStreaming:(NSString *)filePath maxLines:(NSInteger)maxLines {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!fileHandle) {
        return 0;
    }

    NSInteger lineCount = 0;
    const NSUInteger bufferSize = 8192; // 8KB 缓冲区
    NSData *data = nil;

    @try {
        while ((data = [fileHandle readDataOfLength:bufferSize]) && data.length > 0) {
            const char *bytes = (const char *)data.bytes;
            NSUInteger length = data.length;

            for (NSUInteger i = 0; i < length; i++) {
                if (bytes[i] == '\n') {
                    lineCount++;
                    // 达到上限则提前返回
                    if (lineCount >= maxLines) {
                        [fileHandle closeFile];
                        return maxLines;
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"统计行数异常: %@", exception);
    } @finally {
        [fileHandle closeFile];
    }

    return lineCount;
}

- (NSString *)formattedFileSize {
    if (_fileSize < 1024) {
        return [NSString stringWithFormat:@"%ld B", (long)_fileSize];
    } else if (_fileSize < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", _fileSize / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%.2f MB", _fileSize / (1024.0 * 1024.0)];
    }
}

- (NSString *)formattedCreateTime {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:_createTime];
}

@end

#pragma mark - CSVHistoryViewController Implementation

@interface CSVHistoryViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong, nullable) UITextView *currentDiagTextView;
@property (nonatomic, strong, nullable) UIActivityIndicatorView *currentDiagIndicator;
@property (nonatomic, strong, nullable) CSVRecord *currentDiagRecord;
@end

@implementation CSVHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@",[NSString stringWithUTF8String:object_getClassName(self)]);
    self.title = @"CSV转换记录";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 初始化数据源
    if (!_csvRecords) {
        _csvRecords = [NSMutableArray array];
    }

    [self setupUI];
    [self loadExistingCSVFiles];
}

- (void)setupUI {
    // 设置导航栏
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
        target:self
        action:@selector(clearAllRecords)];

    // 创建TableView
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 80;
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CSVCell"];
    [self.view addSubview:_tableView];

    // 空状态提示
    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"暂无转换记录\n\n请在主页面选择Session并转换";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:16];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [_emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40]
    ]];
}

#pragma mark - Data Management

- (void)loadExistingCSVFiles {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = [paths firstObject];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:documentsDir error:nil];

    [_csvRecords removeAllObjects];

    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"csv"]) {
            NSString *fullPath = [documentsDir stringByAppendingPathComponent:file];

            // 解析文件名获取源BBL和Session信息
            // 格式: {源文件}_{日期}_{时间戳}_session{N}.csv
            NSString *baseName = [file stringByDeletingPathExtension];
            NSArray *parts = [baseName componentsSeparatedByString:@"_session"];

            NSString *sourceBBL = @"未知";
            NSInteger sessionIndex = 0;

            if (parts.count >= 2) {
                sourceBBL = parts[0];
                sessionIndex = [parts[1] integerValue];
            } else {
                sourceBBL = baseName;
            }

            CSVRecord *record = [[CSVRecord alloc] initWithFileName:file
                                                           filePath:fullPath
                                                          sourceBBL:sourceBBL
                                                       sessionIndex:sessionIndex];
            [_csvRecords addObject:record];
        }
    }

    // 按创建时间倒序排列
    [_csvRecords sortUsingComparator:^NSComparisonResult(CSVRecord *obj1, CSVRecord *obj2) {
        return [obj2.createTime compare:obj1.createTime];
    }];

    [self updateEmptyState];
    [_tableView reloadData];
}

- (void)reloadData {
    [self loadExistingCSVFiles];
}

- (void)addRecord:(CSVRecord *)record {
    [_csvRecords insertObject:record atIndex:0];
    [self updateEmptyState];
    [_tableView reloadData];
}

- (void)updateEmptyState {
    _emptyLabel.hidden = (_csvRecords.count > 0);
    _tableView.hidden = (_csvRecords.count == 0);
}

- (void)clearAllRecords {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"确认删除"
        message:@"确定要删除所有CSV文件吗？此操作不可恢复。"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performClearAll];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performClearAll {
    NSFileManager *fm = [NSFileManager defaultManager];

    for (CSVRecord *record in _csvRecords) {
        NSError *error = nil;
        [fm removeItemAtPath:record.filePath error:&error];
        if (error) {
            NSLog(@"❌ 删除文件失败: %@", error.localizedDescription);
        }
    }

    [_csvRecords removeAllObjects];
    [self updateEmptyState];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _csvRecords.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CSVCell" forIndexPath:indexPath];

    // 使用新的配置API
    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];

    CSVRecord *record = _csvRecords[indexPath.row];

    config.text = record.fileName;
    config.secondaryText = [NSString stringWithFormat:@"Session %ld | %@ | %ld 行\n%@",
                            (long)record.sessionIndex + 1,
                            [record formattedFileSize],
                            (long)record.lineCount,
                            [record formattedCreateTime]];
    config.secondaryTextProperties.numberOfLines = 2;
    config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    config.image = [UIImage systemImageNamed:@"doc.text"];
    config.imageProperties.tintColor = [UIColor systemBlueColor];

    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    CSVRecord *record = _csvRecords[indexPath.row];
    [self showActionSheetForRecord:record];
}

/**
 * 显示操作选项（预览/分析/删除）
 */
- (void)showActionSheetForRecord:(CSVRecord *)record {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:record.fileName
        message:@"请选择操作"
        preferredStyle:UIAlertControllerStyleActionSheet];

    // 炸机诊断
    [alert addAction:[UIAlertAction actionWithTitle:@"🩺 炸机诊断"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self showCrashDiagnosis:record];
        }]];

    // 分析
    [alert addAction:[UIAlertAction actionWithTitle:@"📊 PID分析"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self analyzeCSV:record];
        }]];

    // 取消
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel
        handler:nil]];

    // iPad适配
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(
            self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {

    // 删除操作
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self deleteRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    // 分享操作
    UIContextualAction *shareAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"分享"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self shareRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    shareAction.backgroundColor = [UIColor systemBlueColor];
    shareAction.image = [UIImage systemImageNamed:@"square.and.arrow.up"];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, shareAction]];
}

#pragma mark - Actions

- (void)deleteRecordAtIndexPath:(NSIndexPath *)indexPath {
    CSVRecord *record = _csvRecords[indexPath.row];

    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:record.filePath error:&error];

    if (!error) {
        [_csvRecords removeObjectAtIndex:indexPath.row];
        [_tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        [self updateEmptyState];
    } else {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"删除失败"
            message:error.localizedDescription
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)shareRecordAtIndexPath:(NSIndexPath *)indexPath {
    CSVRecord *record = _csvRecords[indexPath.row];
    NSURL *fileURL = [NSURL fileURLWithPath:record.filePath];

    UIActivityViewController *activityVC = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL]
        applicationActivities:nil];

    // iPad适配
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
        activityVC.popoverPresentationController.sourceView = cell;
        activityVC.popoverPresentationController.sourceRect = cell.bounds;
    }

    [self presentViewController:activityVC animated:YES completion:nil];
}

#pragma mark - 炸机诊断

- (void)showCrashDiagnosis:(CSVRecord *)record {
    // 创建诊断结果页面
    UIViewController *diagVC = [[UIViewController alloc] init];
    diagVC.title = @"炸机诊断";
    diagVC.view.backgroundColor = [UIColor systemBackgroundColor];

    // TextView 显示诊断报告
    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.font = [UIFont fontWithName:@"Menlo" size:12];
    textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    textView.text = @"⏳ 正在分析飞行数据...";
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [diagVC.view addSubview:textView];

    // 加载指示器
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [diagVC.view addSubview:indicator];

    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:diagVC.view.safeAreaLayoutGuide.topAnchor constant:10],
        [textView.leadingAnchor constraintEqualToAnchor:diagVC.view.leadingAnchor constant:10],
        [textView.trailingAnchor constraintEqualToAnchor:diagVC.view.trailingAnchor constant:-10],
        [textView.bottomAnchor constraintEqualToAnchor:diagVC.view.safeAreaLayoutGuide.bottomAnchor constant:-10],

        [indicator.centerXAnchor constraintEqualToAnchor:diagVC.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:diagVC.view.centerYAnchor]
    ]];

    // 导航栏按钮：刷新 + 设置 + 取消
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(refreshDiagnosis:)];
    UIBarButtonItem *settingsBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"gearshape"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(showDiagnosisSettings:)];
    UIBarButtonItem *stopBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemStop
        target:self
        action:@selector(cancelDiagnosis:)];
    diagVC.navigationItem.rightBarButtonItems = @[stopBtn, settingsBtn, refreshBtn];

    [self.navigationController pushViewController:diagVC animated:YES];

    // 保存引用以便刷新和取消
    self.currentDiagTextView = textView;
    self.currentDiagIndicator = indicator;
    self.currentDiagRecord = record;

    // 启动诊断
    [self runDiagnosisForRecord:record textView:textView indicator:indicator];
}

- (void)cancelDiagnosis:(UIBarButtonItem *)sender {
    [[CrashDiagnosisEngine shared] cancelCurrentRequest];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)refreshDiagnosis:(UIBarButtonItem *)sender {
    if (!self.currentDiagRecord) return;

    // 重置 UI 状态
    self.currentDiagTextView.text = @"⏳ 正在重新分析飞行数据...";
    [self.currentDiagIndicator startAnimating];

    // 先取消上一次请求
    [[CrashDiagnosisEngine shared] cancelCurrentRequest];

    // 重新启动诊断
    [self runDiagnosisForRecord:self.currentDiagRecord
                       textView:self.currentDiagTextView
                       indicator:self.currentDiagIndicator];
}

- (void)runDiagnosisForRecord:(CSVRecord *)record
                     textView:(UITextView *)textView
                     indicator:(UIActivityIndicatorView *)indicator {
    CrashDiagnosisEngine *engine = [CrashDiagnosisEngine shared];

    // 🔑 流式输出：每收到一段文本就更新 TextView
    engine.onStreamingText = ^(NSString *partialText) {
        textView.text = partialText;
    };

    [engine diagnoseCSVAtPath:record.filePath
        completion:^(CrashDiagnosisResult *result) {
            [indicator stopAnimating];
            engine.onStreamingText = nil;

            if (result.error && !result.reportText) {
                textView.text = [NSString stringWithFormat:@"❌ 诊断失败\n\n%@", result.error.localizedDescription];
            } else {
                textView.text = result.reportText ?: @"无诊断结果";
            }
        }];
}

- (void)showDiagnosisSettings:(UIBarButtonItem *)sender {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"诊断上下文规则"
        message:@"输入自定义规则，AI 诊断时会遵守这些规则。\n留空则仅使用默认规则。"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"例如：不要推荐 D 项调整；我的飞机是 5 寸穿越机";
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

- (void)showCSVPreview:(CSVRecord *)record {
    // 创建预览页面
    UIViewController *previewVC = [[UIViewController alloc] init];
    previewVC.title = record.fileName;
    previewVC.view.backgroundColor = [UIColor systemBackgroundColor];

    // 创建TextView显示CSV内容
    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.font = [UIFont fontWithName:@"Menlo" size:11];
    textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [previewVC.view addSubview:textView];

    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.topAnchor constant:10],
        [textView.leadingAnchor constraintEqualToAnchor:previewVC.view.leadingAnchor constant:10],
        [textView.trailingAnchor constraintEqualToAnchor:previewVC.view.trailingAnchor constant:-10],
        [textView.bottomAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.bottomAnchor constant:-10]
    ]];

    // 流式读取CSV内容，只获取前100行，避免大文件内存问题
    NSInteger maxPreviewLines = 100;
    NSString *previewContent = [self readFirstNLines:record.filePath maxLines:maxPreviewLines];

    if (previewContent) {
        NSMutableString *previewText = [NSMutableString stringWithString:previewContent];

        // 如果文件总行数超过预览行数，显示提示
        if (record.lineCount > maxPreviewLines) {
            [previewText appendFormat:@"\n\n... 还有 %ld 行 ...", (long)(record.lineCount - maxPreviewLines)];
        }

        textView.text = previewText;
    } else {
        textView.text = @"无法读取文件";
    }

    // 添加分享按钮
    previewVC.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(shareCurrentPreview:)];
    previewVC.navigationItem.rightBarButtonItem.tag = [_csvRecords indexOfObject:record];

    // 临时创建的ViewController没有viewDidLoad，在push前打印类名以供调试
    NSLog(@"本类为:%@ (CSV预览页)", [NSString stringWithUTF8String:object_getClassName(previewVC)]);
    [self.navigationController pushViewController:previewVC animated:YES];
}

/// 流式读取文件前N行内容
/// @param filePath 文件路径
/// @param maxLines 最大读取行数
- (NSString *)readFirstNLines:(NSString *)filePath maxLines:(NSInteger)maxLines {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!fileHandle) {
        return nil;
    }

    NSMutableData *resultData = [NSMutableData data];
    NSInteger lineCount = 0;
    const NSUInteger bufferSize = 8192; // 8KB 缓冲区
    NSData *data = nil;

    @try {
        while ((data = [fileHandle readDataOfLength:bufferSize]) && data.length > 0) {
            const char *bytes = (const char *)data.bytes;
            NSUInteger length = data.length;

            for (NSUInteger i = 0; i < length; i++) {
                [resultData appendBytes:&bytes[i] length:1];

                if (bytes[i] == '\n') {
                    lineCount++;
                    if (lineCount >= maxLines) {
                        [fileHandle closeFile];
                        return [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding];
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"读取文件异常: %@", exception);
        [fileHandle closeFile];
        return nil;
    }

    [fileHandle closeFile];
    return [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding];
}

- (void)shareCurrentPreview:(UIBarButtonItem *)sender {
    NSInteger index = sender.tag;
    if (index < _csvRecords.count) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
        [self shareRecordAtIndexPath:indexPath];
    }
}

/**
 * 分析CSV文件
 */
- (void)analyzeCSV:(CSVRecord *)record {
    NSLog(@"📊 开始分析CSV: %@", record.fileName);

    // 创建分析视图控制器
    PIDAnalysisViewController *analysisVC = [[PIDAnalysisViewController alloc]
        initWithCSVFilePath:record.filePath];

    [self.navigationController pushViewController:analysisVC animated:YES];
}

@end
