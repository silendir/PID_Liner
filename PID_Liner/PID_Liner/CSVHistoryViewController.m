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
#import "CrashDiagnosisViewController.h"
#import "IterationChainManager.h"
#import "BBLImportService.h"

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

#pragma mark - 显示模型

/// 扁平化显示项（用于TableView数据源）
@interface CSVDisplayItem : NSObject
@property (nonatomic, strong) CSVRecord *record;
@property (nonatomic, assign) NSInteger depth;           // 0=父记录, 1=子记录
@property (nonatomic, assign) BOOL isParent;             // 是否为父记录
@property (nonatomic, assign) BOOL isExpanded;           // 父记录: 是否展开
@property (nonatomic, assign) NSInteger childCount;      // 父记录: 子记录数
@property (nonatomic, assign) NSInteger groupIndex;      // 在 recordGroups 中的索引
@property (nonatomic, copy, nullable) NSString *chainId; // 关联的迭代链ID
@property (nonatomic, assign) NSInteger iterationNumber; // 子记录: 第几轮
@end

@implementation CSVDisplayItem
@end

/// CSV记录分组（父记录 + 子记录）
@interface CSVRecordGroup : NSObject
@property (nonatomic, strong) CSVRecord *parentRecord;
@property (nonatomic, strong) NSMutableArray<CSVRecord *> *childRecords;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, copy, nullable) NSString *chainId;
@end

@implementation CSVRecordGroup
@end

#pragma mark - CSVHistoryViewController Implementation

@interface CSVHistoryViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<CSVRecordGroup *> *recordGroups;
@property (nonatomic, strong) NSMutableArray<CSVDisplayItem *> *displayItems;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *chainInfoCache; // CSV路径 → 链信息
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
    _recordGroups = [NSMutableArray array];
    _displayItems = [NSMutableArray array];
    _chainInfoCache = [NSMutableDictionary dictionary];

    [self setupUI];
    [self loadExistingCSVFiles];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadExistingCSVFiles];
    // 🔑 空列表兜底:列表为空且本会话未弹过 → 弹「加入示例」(任务#28 阶段0.3 Demo 机制)
    [self checkAndPromptDemoIfEmpty];
}

#pragma mark - Demo 兜底机制(空列表 → 弹「加入示例」)

/// 会话级去重集合(进程生命周期;记录本会话已弹过 demo 的列表 key)
static NSMutableSet<NSString *> *kDemoPromptedKeys(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

/// 列表空且本会话未弹过 → 弹 demo 弹窗
- (void)checkAndPromptDemoIfEmpty {
    if (self.recordGroups.count > 0) return;            // 非空(老用户):不触发,零打扰
    NSString *key = @"CSVHistoryList";
    if ([kDemoPromptedKeys() containsObject:key]) return;  // 本会话已弹过(含用户取消):不再弹
    [kDemoPromptedKeys() addObject:key];                // 标记(无论加入/取消,本会话不再弹)

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"还没有飞行记录"
                         message:@"加入一条示例飞行数据(BF 4.5),体验分析与炸机诊断?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"加入示例" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [self loadDemoBBLAndReload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"不用了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 加入示例 = copy bundle 001.bbl → 沙盒 → 转 CSV(经 BBLImportService 统一管线) → reload
/// 🔑 加入后即普通记录,与用户导入的记录完全一样;bundle 001.bbl 实体永远不动
- (void)loadDemoBBLAndReload {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"001" ofType:@"bbl"];
    if (!bundlePath) {
        NSLog(@"❌ [Demo] bundle 内找不到 001.bbl");
        return;
    }

    NSString *docs = [self documentsDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destBBL = [docs stringByAppendingPathComponent:@"001.bbl"];

    // 沙盒已有 001.bbl 先移除,避免 copy 冲突
    if ([fm fileExistsAtPath:destBBL]) {
        [fm removeItemAtPath:destBBL error:nil];
    }
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:bundlePath toPath:destBBL error:&copyErr]) {
        NSLog(@"❌ [Demo] copy 001.bbl 失败: %@", copyErr.localizedDescription);
        return;
    }

    __weak typeof(self) weakSelf = self;
    // 后台转 CSV(经 BBLImportService 统一管线;001.bbl 取第一个 Session,motorKV=nil)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *convErr = nil;
        NSString *csvPath = [[BBLImportService shared] convertBBL:destBBL
                                                          logIndex:0
                                                           motorKV:nil
                                                             error:&convErr];
        if (!csvPath) {
            NSLog(@"❌ [Demo] 001.bbl 转换失败: %@", convErr.localizedDescription);
            return;
        }
        // 回主线程刷新列表
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf loadExistingCSVFiles];
        });
    });
}

/// Documents 目录(沙盒)
- (NSString *)documentsDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
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
    [_chainInfoCache removeAllObjects];

    // 1️⃣ 扫描所有CSV文件，创建CSVRecord + 提取链信息
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"csv"]) {
            NSString *fullPath = [documentsDir stringByAppendingPathComponent:file];

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

            // 提取迭代链信息并缓存
            NSDictionary *chainInfo = [self extractChainInfoFromCSVAtPath:fullPath];
            if (chainInfo) {
                _chainInfoCache[fullPath] = chainInfo;
            }
        }
    }

    // 2️⃣ 加载所有迭代链
    NSArray<IterationChain *> *allChains = [[IterationChainManager sharedManager] allChains];

    // 3️⃣ 按chainId分组子记录（两种来源：CSV头部标记 + 迭代链records）
    NSMutableDictionary<NSString *, NSMutableArray<CSVRecord *> *> *chainChildMap = [NSMutableDictionary dictionary];
    NSMutableSet *childFilePaths = [NSMutableSet set];

    // 3a. 来源1: CSV头部 # Chain ID: 标记
    for (CSVRecord *record in _csvRecords) {
        NSDictionary *chainInfo = _chainInfoCache[record.filePath];
        if (chainInfo) {
            NSString *chainId = chainInfo[@"chainId"];
            if (!chainChildMap[chainId]) {
                chainChildMap[chainId] = [NSMutableArray array];
            }
            [chainChildMap[chainId] addObject:record];
            [childFilePaths addObject:record.filePath];
        }
    }

    // 3b. 来源2: 迭代链JSON中的records（csvFileName匹配）
    for (IterationChain *chain in allChains) {
        NSString *chainId = chain.chainId;
        if (!chainChildMap[chainId]) {
            chainChildMap[chainId] = [NSMutableArray array];
        }

        for (PIDTuningRecord *tuningRecord in chain.records) {
            NSString *targetFileName = tuningRecord.csvFileName;
            if (!targetFileName.length) continue;

            // 在所有CSV中查找匹配的文件
            for (CSVRecord *csvRecord in _csvRecords) {
                if ([csvRecord.fileName isEqualToString:targetFileName] &&
                    ![childFilePaths containsObject:csvRecord.filePath] &&
                    ![csvRecord.filePath isEqualToString:chain.initialCSVPath]) {
                    [chainChildMap[chainId] addObject:csvRecord];
                    [childFilePaths addObject:csvRecord.filePath];
                    break;
                }
            }
        }
    }

    // 4️⃣ 构建分组
    NSMutableArray<CSVRecordGroup *> *groups = [NSMutableArray array];
    NSMutableSet *groupedPaths = [NSMutableSet set]; // 已归入某组的CSV路径

    // 4a. 处理有迭代链的记录
    for (IterationChain *chain in allChains) {
        // 查找父记录（chain的initialCSVPath）
        CSVRecord *parentRecord = nil;
        for (CSVRecord *record in _csvRecords) {
            if ([record.filePath isEqualToString:chain.initialCSVPath]) {
                parentRecord = record;
                break;
            }
        }

        if (!parentRecord) {
            // 父记录文件已删除，跳过此链（子记录后续作为独立记录处理）
            continue;
        }

        CSVRecordGroup *group = [[CSVRecordGroup alloc] init];
        group.chainId = chain.chainId;
        group.parentRecord = parentRecord;
        group.childRecords = chainChildMap[chain.chainId] ?: [NSMutableArray array];
        group.isExpanded = NO;

        [groupedPaths addObject:parentRecord.filePath];

        // 子记录按创建时间排序
        [group.childRecords sortUsingComparator:^NSComparisonResult(CSVRecord *a, CSVRecord *b) {
            return [a.createTime compare:b.createTime];
        }];
        for (CSVRecord *child in group.childRecords) {
            [groupedPaths addObject:child.filePath];
        }

        [groups addObject:group];
    }

    // 4b. 处理独立记录（非链父记录、非链子记录）
    for (CSVRecord *record in _csvRecords) {
        if (![groupedPaths containsObject:record.filePath]) {
            CSVRecordGroup *group = [[CSVRecordGroup alloc] init];
            group.parentRecord = record;
            group.childRecords = [NSMutableArray array];
            group.isExpanded = NO;
            [groups addObject:group];
        }
    }

    // 5️⃣ 按父记录创建时间倒序
    [groups sortUsingComparator:^NSComparisonResult(CSVRecordGroup *a, CSVRecordGroup *b) {
        return [b.parentRecord.createTime compare:a.parentRecord.createTime];
    }];

    self.recordGroups = groups;
    [self buildDisplayItems];
    [self updateEmptyState];
    [_tableView reloadData];
}

- (void)reloadData {
    [self loadExistingCSVFiles];
}

- (void)addRecord:(CSVRecord *)record {
    [_csvRecords insertObject:record atIndex:0];

    CSVRecordGroup *group = [[CSVRecordGroup alloc] init];
    group.parentRecord = record;
    group.childRecords = [NSMutableArray array];
    group.isExpanded = NO;

    [_recordGroups insertObject:group atIndex:0];
    [self buildDisplayItems];
    [self updateEmptyState];
    [_tableView reloadData];
}

- (void)updateEmptyState {
    _emptyLabel.hidden = (_recordGroups.count > 0);
    _tableView.hidden = (_recordGroups.count == 0);
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

    // 清理所有迭代链
    NSArray<IterationChain *> *allChains = [[IterationChainManager sharedManager] allChains];
    for (IterationChain *chain in allChains) {
        [[IterationChainManager sharedManager] deleteChain:chain.chainId];
    }

    [_csvRecords removeAllObjects];
    [_recordGroups removeAllObjects];
    [_displayItems removeAllObjects];
    [_chainInfoCache removeAllObjects];
    [self updateEmptyState];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CSVCell" forIndexPath:indexPath];

    CSVDisplayItem *item = self.displayItems[indexPath.row];
    CSVRecord *record = item.record;

    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];

    if (item.isParent) {
        // 🔹 父记录
        config.text = record.displayName;

        NSMutableString *subtitle = [NSMutableString string];
        [subtitle appendFormat:@"Session %ld | %@ | %ld 行\n%@",
                (long)record.sessionIndex + 1,
                [record formattedFileSize],
                (long)record.lineCount,
                [record formattedCreateTime]];

        if (item.childCount > 0) {
            [subtitle appendFormat:@"\n🔄 %ld轮迭代", (long)item.childCount];
        }

        config.secondaryText = subtitle;
        config.secondaryTextProperties.numberOfLines = 3;
        config.secondaryTextProperties.color = [UIColor secondaryLabelColor];

        if (item.childCount > 0) {
            // 有子记录：显示展开/折叠指示
            config.image = [UIImage systemImageNamed:item.isExpanded ? @"chevron.down" : @"chevron.right"];
            config.imageProperties.tintColor = [UIColor systemOrangeColor];
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            // 独立记录
            config.image = [UIImage systemImageNamed:@"doc.text"];
            config.imageProperties.tintColor = [UIColor systemBlueColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        // 🔹 子记录（迭代轮次）
        NSString *iterationLabel = item.iterationNumber > 0
            ? [NSString stringWithFormat:@"第%ld轮", (long)item.iterationNumber]
            : @"迭代飞行";
        config.text = [NSString stringWithFormat:@"%@ %@", iterationLabel, record.displayName];
        config.secondaryText = [NSString stringWithFormat:@"%@ | %@",
                [record formattedFileSize],
                [record formattedCreateTime]];
        config.secondaryTextProperties.numberOfLines = 1;
        config.secondaryTextProperties.color = [UIColor tertiaryLabelColor];
        config.image = [UIImage systemImageNamed:@"arrow.turn.down.right"];
        config.imageProperties.tintColor = [UIColor systemGrayColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    cell.contentConfiguration = config;

    // 子记录缩进
    cell.indentationLevel = (NSInteger)item.depth;
    cell.indentationWidth = 24;

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    CSVDisplayItem *item = self.displayItems[indexPath.row];

    if (item.isParent && item.childCount > 0) {
        // 父记录有子记录 → 展开/折叠
        [self toggleExpandForGroupAtIndex:item.groupIndex];
    } else {
        // 独立记录或子记录 → 显示操作菜单
        [self showActionSheetForRecord:item.record];
    }
}

/**
 * 显示操作选项（预览/分析/删除）
 */
- (void)showActionSheetForRecord:(CSVRecord *)record {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:record.fileName
        message:@"请选择操作"
        preferredStyle:UIAlertControllerStyleActionSheet];

    // 炸机诊断(0.4a → push 独立诊断屏,不再内联建 VC)
    [alert addAction:[UIAlertAction actionWithTitle:@"🩺 炸机诊断"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            CrashDiagnosisViewController *diagVC = [[CrashDiagnosisViewController alloc]
                initWithCSVPath:record.filePath title:record.displayName];
            [self.navigationController pushViewController:diagVC animated:YES];
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

    CSVDisplayItem *item = self.displayItems[indexPath.row];

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

    // 重命名操作
    UIContextualAction *renameAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"重命名"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self renameRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    renameAction.backgroundColor = [UIColor systemOrangeColor];
    renameAction.image = [UIImage systemImageNamed:@"pencil"];

    // 删除操作
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self deleteRecordAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    // 子记录不需要重命名（迭代CSV文件名是系统生成的）
    if (!item.isParent) {
        return [UISwipeActionsConfiguration configurationWithActions:@[shareAction, deleteAction]];
    }

    return [UISwipeActionsConfiguration configurationWithActions:@[shareAction, renameAction, deleteAction]];
}

#pragma mark - 分组与显示辅助方法

/// 从CSV文件头部提取迭代链信息
/// @return @{@"chainId": @"xxx", @"iteration": @(N)} 或 nil
- (nullable NSDictionary *)extractChainInfoFromCSVAtPath:(NSString *)filePath {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!handle) return nil;

    NSString *chainId = nil;
    NSInteger iteration = 0;

    @try {
        NSData *data = [handle readDataOfLength:4096];
        if (!data) return nil;

        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!content) return nil;

        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

            if ([trimmed hasPrefix:@"# Chain ID:"]) {
                chainId = [[trimmed substringFromIndex:[@"# Chain ID:" length]]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            } else if ([trimmed hasPrefix:@"# Chain Iteration:"]) {
                iteration = [[[trimmed substringFromIndex:[@"# Chain Iteration:" length]]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];
            }

            // 非注释行结束header区域
            if (trimmed.length > 0 && ![trimmed hasPrefix:@"#"]) break;
        }
    } @catch (NSException *exception) {
        NSLog(@"⚠️ 读取CSV链信息异常: %@", exception);
    } @finally {
        [handle closeFile];
    }

    if (chainId) {
        return @{@"chainId": chainId, @"iteration": @(iteration)};
    }
    return nil;
}

/// 从分组数据构建扁平化显示数组
- (void)buildDisplayItems {
    NSMutableArray<CSVDisplayItem *> *items = [NSMutableArray array];

    for (NSInteger g = 0; g < self.recordGroups.count; g++) {
        CSVRecordGroup *group = self.recordGroups[g];

        // 父记录
        CSVDisplayItem *parentItem = [[CSVDisplayItem alloc] init];
        parentItem.record = group.parentRecord;
        parentItem.depth = 0;
        parentItem.isParent = YES;
        parentItem.isExpanded = group.isExpanded;
        parentItem.childCount = group.childRecords.count;
        parentItem.groupIndex = g;
        parentItem.chainId = group.chainId;
        [items addObject:parentItem];

        // 子记录（仅在展开时）
        if (group.isExpanded) {
            for (NSInteger c = 0; c < group.childRecords.count; c++) {
                CSVDisplayItem *childItem = [[CSVDisplayItem alloc] init];
                childItem.record = group.childRecords[c];
                childItem.depth = 1;
                childItem.isParent = NO;
                childItem.groupIndex = g;

                // 从缓存中取迭代轮次号
                NSDictionary *cachedInfo = self.chainInfoCache[childItem.record.filePath];
                if (cachedInfo) {
                    childItem.iterationNumber = [cachedInfo[@"iteration"] integerValue];
                } else {
                    childItem.iterationNumber = (NSInteger)(c + 2); // 退化为序号
                }
                childItem.chainId = group.chainId;

                [items addObject:childItem];
            }
        }
    }

    self.displayItems = items;
}

/// 查找指定分组的父记录在 displayItems 中的索引
- (NSInteger)displayIndexForGroupParent:(NSInteger)groupIndex {
    for (NSInteger i = 0; i < self.displayItems.count; i++) {
        CSVDisplayItem *item = self.displayItems[i];
        if (item.isParent && item.groupIndex == groupIndex) {
            return i;
        }
    }
    return NSNotFound;
}

/// 展开/折叠指定分组
- (void)toggleExpandForGroupAtIndex:(NSInteger)groupIndex {
    CSVRecordGroup *group = self.recordGroups[groupIndex];
    NSInteger childCount = group.childRecords.count;
    if (childCount == 0) return;

    // 记录父记录位置
    NSInteger parentIndex = [self displayIndexForGroupParent:groupIndex];

    // 切换展开状态
    group.isExpanded = !group.isExpanded;

    // 构建插入/删除的indexPath
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
    for (NSInteger i = 0; i < childCount; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForRow:parentIndex + 1 + i inSection:0]];
    }

    // 重建显示数据
    [self buildDisplayItems];

    // 直接更新父Cell的图标（避免reload闪烁）
    UITableViewCell *parentCell = [_tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:parentIndex inSection:0]];
    if (parentCell) {
        id<UIContentConfiguration> config = [parentCell contentConfiguration];
        if ([config isKindOfClass:[UIListContentConfiguration class]]) {
            UIListContentConfiguration *newConfig = [(UIListContentConfiguration *)config copy];
            newConfig.image = [UIImage systemImageNamed:group.isExpanded ? @"chevron.down" : @"chevron.right"];
            parentCell.contentConfiguration = newConfig;
        }
    }

    // 动画插入/删除子行
    [_tableView beginUpdates];
    if (group.isExpanded) {
        [_tableView insertRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        [_tableView deleteRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationAutomatic];
    }
    [_tableView endUpdates];
}

#pragma mark - Actions

- (void)deleteRecordAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.displayItems.count) return;

    CSVDisplayItem *item = self.displayItems[indexPath.row];

    if (item.isParent && item.childCount > 0) {
        // 父记录有子记录 → 确认弹窗，连带删除
        NSString *message = [NSString stringWithFormat:@"此记录包含 %ld 轮迭代数据，将一并删除。", (long)item.childCount];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"删除记录"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self performDeleteParentAtIndexPath:indexPath];
        }]];

        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // 独立记录或子记录 → 直接删除
        [self performDeleteSingleRecord:item.record];
    }
}

/// 删除父记录及其所有子记录
- (void)performDeleteParentAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.displayItems.count) return;

    CSVDisplayItem *item = self.displayItems[indexPath.row];
    CSVRecordGroup *group = self.recordGroups[item.groupIndex];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 删除父记录
    [fm removeItemAtPath:item.record.filePath error:nil];

    // 删除所有子记录
    for (CSVRecord *child in group.childRecords) {
        [fm removeItemAtPath:child.filePath error:nil];
    }

    // 删除关联的迭代链
    if (group.chainId.length > 0) {
        [[IterationChainManager sharedManager] deleteChain:group.chainId];
    }

    NSLog(@"🗑 删除记录及%ld轮迭代: %@", (long)group.childRecords.count, item.record.fileName);
    [self loadExistingCSVFiles];
}

/// 删除单条记录（子记录或独立记录）
- (void)performDeleteSingleRecord:(CSVRecord *)record {
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:record.filePath error:&error];

    if (!error) {
        [self loadExistingCSVFiles];
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
    if (indexPath.row >= self.displayItems.count) return;
    CSVRecord *record = self.displayItems[indexPath.row].record;
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
    if (indexPath.row >= self.displayItems.count) return;
    CSVRecord *record = self.displayItems[indexPath.row].record;
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
    [self loadExistingCSVFiles];
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
        target:nil
        action:nil];
    previewVC.navigationItem.rightBarButtonItem.tag = [_csvRecords indexOfObject:record];
    // 使用自定义action通过block分享
    [previewVC.navigationItem.rightBarButtonItem setTarget:self];
    [previewVC.navigationItem.rightBarButtonItem setAction:@selector(shareCurrentPreview:)];

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
    if (index >= _csvRecords.count) return;

    // 从原始csvRecords找到记录，再在displayItems中查找对应indexPath
    CSVRecord *targetRecord = _csvRecords[index];
    for (NSInteger i = 0; i < self.displayItems.count; i++) {
        if ([self.displayItems[i].record.filePath isEqualToString:targetRecord.filePath]) {
            [self shareRecordAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
            return;
        }
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
