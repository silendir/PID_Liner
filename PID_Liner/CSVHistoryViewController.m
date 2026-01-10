//
//  CSVHistoryViewController.m
//  PID_Liner
//
//  CSV转换历史记录页面实现
//

#import "CSVHistoryViewController.h"
#import "PIDAnalysisViewController.h"
#import "CSVAliasManager.h"
#import "CSVRenameView.h"

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

        // 🔥 加载别名
        [self updateDisplayName];
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

/**
 * 🔥 更新显示名称（从别名管理器加载）
 */
- (void)updateDisplayName {
    NSString *alias = [[CSVAliasManager sharedManager] aliasForFileName:_fileName];

    if (alias && alias.length > 0) {
        // 有别名，使用别名（添加 .csv 后缀）
        NSString *aliasWithExt = [alias stringByAppendingPathExtension:@"csv"];
        _displayName = aliasWithExt;
        _hasCustomName = YES;
    } else {
        // 无别名，使用原文件名
        _displayName = _fileName;
        _hasCustomName = NO;
    }
}

@end

#pragma mark - CSVHistoryViewController Implementation

@interface CSVHistoryViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
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

    // 🔥 使用显示名称（别名或原文件名）
    config.text = record.displayName;
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

    // 预览
    [alert addAction:[UIAlertAction actionWithTitle:@"预览内容"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self showCSVPreview:record];
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

    // 🔥 分享操作（最左侧）
    UIContextualAction *shareAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"分享"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self shareRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    shareAction.backgroundColor = [UIColor systemBlueColor];
    shareAction.image = [UIImage systemImageNamed:@"square.and.arrow.up"];

    // 🔥 重命名操作（中间）
    UIContextualAction *renameAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"重命名"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self renameRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    renameAction.backgroundColor = [UIColor systemOrangeColor];
    renameAction.image = [UIImage systemImageNamed:@"pencil"];

    // 删除操作（最右侧，红色）
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self deleteRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    // 顺序：分享 → 重命名 → 删除
    return [UISwipeActionsConfiguration configurationWithActions:@[shareAction, renameAction, deleteAction]];
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

    // 🔥 如果有别名，创建临时副本使用别名文件名
    NSURL *shareURL = fileURL;
    NSString *tempFilePath = nil;

    if (record.hasCustomName) {
        NSFileManager *fm = [NSFileManager defaultManager];

        // 创建临时文件路径
        NSString *tempDir = NSTemporaryDirectory();
        tempFilePath = [tempDir stringByAppendingPathComponent:record.displayName];

        // 删除可能存在的旧临时文件
        if ([fm fileExistsAtPath:tempFilePath]) {
            [fm removeItemAtPath:tempFilePath error:nil];
        }

        // 复制文件到临时位置
        NSError *error = nil;
        [fm copyItemAtPath:record.filePath toPath:tempFilePath error:&error];

        if (!error) {
            shareURL = [NSURL fileURLWithPath:tempFilePath];
            NSLog(@"📤 创建临时分享文件: %@", record.displayName);
        } else {
            NSLog(@"❌ 创建临时文件失败: %@", error.localizedDescription);
        }
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc]
        initWithActivityItems:@[shareURL]
        applicationActivities:nil];

    // iPad适配
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
        activityVC.popoverPresentationController.sourceView = cell;
        activityVC.popoverPresentationController.sourceRect = cell.bounds;
    }

    // 🔥 分享完成后清理临时文件
    __block NSString *cleanupPath = tempFilePath;
    [activityVC setCompletionWithItemsHandler:^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        if (cleanupPath) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:cleanupPath error:nil];
                NSLog(@"🗑️ 清理临时分享文件");
            });
        }
    }];

    [self presentViewController:activityVC animated:YES completion:nil];
}

/**
 * 🔥 重命名 CSV 文件（显示别名弹窗）
 */
- (void)renameRecordAtIndexPath:(NSIndexPath *)indexPath {
    CSVRecord *record = _csvRecords[indexPath.row];
    [self showRenameAlertForRecord:record indexPath:indexPath];
}

/**
 * 🔥 显示重命名弹窗 - 使用自定义 View
 */
- (void)showRenameAlertForRecord:(CSVRecord *)record indexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;

    [CSVRenameView showWithRecord:record
                        completion:^(NSString *alias) {
        [weakSelf performRename:alias forRecord:record atIndexPath:indexPath];
    }
                   cancelCompletion:^{
        // 取消，不做任何操作
    }];
}

/**
 * 🔥 执行重命名操作
 * @param alias 用户输入的别名（可能为空）
 * @param record 要重命名的记录
 * @param indexPath 记录在列表中的位置
 */
- (void)performRename:(NSString *)alias forRecord:(CSVRecord *)record atIndexPath:(NSIndexPath *)indexPath {
    if (alias.length > 0) {
        // 🔥 有输入：设置别名（自动处理重复）
        NSString *uniqueAlias = [[CSVAliasManager sharedManager] uniqueAliasWithBase:alias
                                                                 excludingFileName:record.fileName];
        [[CSVAliasManager sharedManager] setAlias:uniqueAlias forFileName:record.fileName];

        NSLog(@"🏷️ 设置别名: %@ → %@", record.fileName, uniqueAlias);
    } else {
        // 🔥 输入为空：删除别名，还原原文件名
        [[CSVAliasManager sharedManager] removeAliasForFileName:record.fileName];

        NSLog(@"🏷️ 还原原名: %@", record.fileName);
    }

    // 更新记录的显示名称
    [record updateDisplayName];

    // 刷新对应 Cell
    [_tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
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
