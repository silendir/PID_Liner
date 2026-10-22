//
//  CSVHistoryViewController.m
//  PID_Liner
//
//  CSV转换历史记录页面实现
//

#import "CSVHistoryViewController.h"
#import "IndependentAnalysisViewController.h"
#import "IterationWorkbenchViewController.h"
#import "CSVAliasManager.h"
#import "CSVRenameView.h"
#import "CrashDiagnosisViewController.h"
#import "IterationChainManager.h"
#import "BBLImportService.h"
#import "NBTheme.h"

/// 行数流式统计的封顶值:超过即不再数,显示为"N+ 行"(防超大文件卡顿;
/// 显示层必须带"+"否则会被误读为文件精确行数——2026-10-13 排查黄线事故时被它误导过)
static const NSInteger kLineCountStatCap = 100000;

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
    // 🔑 行数统计不再在 init 里做——曾经这里主线程逐字节扫描整个 CSV(大文件上百 MB)
    // 是列表打开卡顿的根因;现在由 CSVHistoryViewController 后台异步补齐(见 countLinesAsyncIfNeeded)
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

// (CSVRecordGroup 已上移到 .h —— 分组逻辑抽为 +groupsFromRecords: 纯函数供单元测试;
//  旧的扁平化 CSVDisplayItem 随 section 化改造删除:section = BBL 组,cell = Session)

@implementation CSVRecordGroup
@end

#pragma mark - CSVHistoryViewController Implementation

@interface CSVHistoryViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<CSVRecordGroup *> *recordGroups;
@end

@implementation CSVHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"本类为:%@",[NSString stringWithUTF8String:object_getClassName(self)]);
    self.title = @"CSV转换记录";
    self.view.backgroundColor = NBTheme.bg;  // V3:云白,与首页同家族

    // 🔑 V3 导航:本页 appearance(亮底+发丝分割),标题 ink——与首页同一套令牌
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = NBTheme.bg;
    appearance.shadowColor = NBTheme.hairline;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: NBTheme.ink};
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;

    // 初始化数据源
    if (!_csvRecords) {
        _csvRecords = [NSMutableArray array];
    }
    _recordGroups = [NSMutableArray array];

    [self setupUI];
    // 🔑 不在这里 loadExistingCSVFiles——紧跟的 viewWillAppear 会触发一次,别重复扫描
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadExistingCSVFiles];
    // 🔑 空列表兜底:列表为空且本会话未弹过 → 弹「加入示例」(任务#28 阶段0.3 Demo 机制)
    [self checkAndPromptDemoIfEmpty];
}

#pragma mark - Demo 兜底机制(空列表 → 弹「加入示例」)

/// 列表空 → 弹 demo 弹窗(🔑 每次空都弹,不去重;用户反馈三入口统一空态引导)
- (void)checkAndPromptDemoIfEmpty {
    if (self.recordGroups.count > 0) return;            // 非空:不触发

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

/// 加入示例 = copy bundle 001.bbl → 转 CSV(经 BBLImportService) → reload
/// 🔑 加入后即普通记录,与用户导入的记录完全一样;bundle 001.bbl 实体永远不动
- (void)loadDemoBBLAndReload {
    __weak typeof(self) weakSelf = self;
    [BBLImportService loadDemoBBLWithCompletion:^(NSString *csvPath, NSError *error) {
        if (!csvPath) {
            NSLog(@"❌ [Demo] 001.bbl 转换失败: %@", error.localizedDescription);
            return;
        }
        [weakSelf loadExistingCSVFiles];
    }];
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
    // 🔑 grouped:section = BBL 转换批次(section头 = 账本卡头,cell = Session),卡头不悬浮
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 80;
    // 🔑 组头高度用固定值(自适应 section header 在部分 iOS 版本会塌成 0 → 整页空白,真机已踩)
    // 74pt = 3+68+3:卡内容纳两行批次名 + 元信息行
    _tableView.sectionHeaderHeight = 74;
    _tableView.estimatedSectionHeaderHeight = 74;
    _tableView.sectionFooterHeight = 10;  // 组间距
    if (@available(iOS 15.0, *)) { _tableView.sectionHeaderTopPadding = 0; }
    _tableView.backgroundColor = NBTheme.bg;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;  // 卡片行自带间隙,不要系统分割线
    [_tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CSVCell"];
    [self.view addSubview:_tableView];

    // 空状态提示
    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"暂无转换记录\n\n请在主页面选择Session并转换";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textColor = NBTheme.faint;
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

    // 1️⃣ 扫描所有 CSV → CSVRecord
    //    sourceBBL(转换批次身份)优先读 header "# Source BBL:"(新管线写入,重名落盘时已加序号),
    //    历史文件无此行 → 回退文件名前缀(`_sessionN` 之前的部分)
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"csv"]) {
            NSString *fullPath = [documentsDir stringByAppendingPathComponent:file];

            NSString *baseName = [file stringByDeletingPathExtension];
            NSArray *parts = [baseName componentsSeparatedByString:@"_session"];

            NSString *sourceBBL = @"未知";
            NSInteger sessionIndex = 0;

            if (parts.count >= 2) {
                sourceBBL = [CSVHistoryViewController bblIdentityFromBaseName:parts[0]];
                sessionIndex = [parts[1] integerValue];
            } else {
                sourceBBL = baseName;
            }

            NSString *headerBBL = [self readSourceBBLHeader:fullPath];
            if (headerBBL.length > 0) sourceBBL = headerBBL;

            CSVRecord *record = [[CSVRecord alloc] initWithFileName:file
                                                           filePath:fullPath
                                                          sourceBBL:sourceBBL
                                                       sessionIndex:sessionIndex];
            [_csvRecords addObject:record];
        }
    }

    // 2️⃣ 按 sourceBBL 聚成分组(纯函数,单元测试覆盖)
    self.recordGroups = [[self class] groupsFromRecords:_csvRecords];
    NSLog(@"🔍 [CSV列表] 文件数=%lu 记录数=%lu 组数=%lu", (unsigned long)files.count, (unsigned long)_csvRecords.count, (unsigned long)self.recordGroups.count);
    [self updateEmptyState];
    [_tableView reloadData];
    [self countLinesAsyncIfNeeded];
}

/// 🔑 纯函数分组:按 sourceBBL 聚合(一次转换 BBL = 一个组)
/// 父行 = 组内最小 sessionIndex 的记录;子行按 sessionIndex 升序;组按父记录创建时间倒序
+ (NSArray<CSVRecordGroup *> *)groupsFromRecords:(NSArray<CSVRecord *> *)records {
    NSMutableDictionary<NSString *, NSMutableArray<CSVRecord *> *> *byBBL = [NSMutableDictionary dictionary];
    for (CSVRecord *record in records) {
        NSString *key = record.sourceBBL.length > 0 ? record.sourceBBL : record.fileName;
        if (!byBBL[key]) byBBL[key] = [NSMutableArray array];
        [byBBL[key] addObject:record];
    }

    NSMutableArray<CSVRecordGroup *> *groups = [NSMutableArray array];
    for (NSString *key in byBBL) {
        NSMutableArray<CSVRecord *> *sessions = byBBL[key];
        [sessions sortUsingComparator:^NSComparisonResult(CSVRecord *a, CSVRecord *b) {
            if (a.sessionIndex != b.sessionIndex) {
                return a.sessionIndex < b.sessionIndex ? NSOrderedAscending : NSOrderedDescending;
            }
            return [a.createTime compare:b.createTime];
        }];
        CSVRecordGroup *group = [[CSVRecordGroup alloc] init];
        group.groupKey = key;
        group.parentRecord = sessions.firstObject;
        group.childRecords = sessions.count > 1
            ? [NSMutableArray arrayWithArray:[sessions subarrayWithRange:NSMakeRange(1, sessions.count - 1)]]
            : [NSMutableArray array];
        group.isExpanded = NO;
        [groups addObject:group];
    }

    [groups sortUsingComparator:^NSComparisonResult(CSVRecordGroup *a, CSVRecordGroup *b) {
        return [b.parentRecord.createTime compare:a.parentRecord.createTime];
    }];
    return groups;
}

/// 从 CSV 文件名前缀恢复 BBL 身份:剥掉尾部的转换时间戳 `_(8位日期)_(6位时间)`
/// 🔑 时间戳是「逐 Session 解码时刻」——同一 BBL 的各 Session 解码跨秒后前缀会裂开
/// (真机实锤:25mini.BBL 的 5 个 Session 裂成 121050/121051/121052/121053 四个前缀),
/// 必须按 BBL 本名聚合;新管线此值优先来自 header "# Source BBL:"
+ (NSString *)bblIdentityFromBaseName:(NSString *)baseName {
    if (baseName.length == 0) return baseName;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"_[0-9]{8}_[0-9]{6}$" options:0 error:&err];
    if (err) return baseName;
    NSString *stripped = [re stringByReplacingMatchesInString:baseName
                                                      options:0
                                                        range:NSMakeRange(0, baseName.length)
                                                 withTemplate:@""];
    while ([stripped hasSuffix:@"_"]) {  // BBL 本名自带下划线结尾的,剥完时间戳后裁掉
        stripped = [stripped substringToIndex:stripped.length - 1];
    }
    return stripped;
}

/// 读 CSV 头部 "# Source BBL:"(4KB 内;无此行返回 nil,调用方回退文件名前缀)
- (nullable NSString *)readSourceBBLHeader:(NSString *)filePath {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!handle) return nil;
    @try {
        NSData *data = [handle readDataOfLength:4096];
        if (!data) return nil;
        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:@"# Source BBL:"]) {
                return [[trimmed substringFromIndex:[@"# Source BBL:" length]]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
            if (trimmed.length > 0 && ![trimmed hasPrefix:@"#"]) break;  // 头部注释区结束
        }
    } @catch (NSException *exception) {
        NSLog(@"⚠️ 读取 Source BBL 异常: %@", exception);
    } @finally {
        [handle closeFile];
    }
    return nil;
}

/// 行数统计缓存(NSCache 线程安全):路径|文件大小 → 行数;同会话内文件没变就不重算
+ (NSCache<NSString *, NSNumber *> *)lineCountCache {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    return cache;
}

/// 🔑 行数后台补齐:列表用 fileSize 秒开,行数流式统计放后台跑完再刷一次
/// (大 CSV 的整文件扫描曾经是 push 卡顿的根因;缓存命中后二次进入零开销)
- (void)countLinesAsyncIfNeeded {
    NSCache *cache = [[self class] lineCountCache];
    NSMutableArray<CSVRecord *> *pending = [NSMutableArray array];
    for (CSVRecord *r in _csvRecords) {
        if (r.lineCount > 0) continue;  // 已有行数
        NSString *key = [NSString stringWithFormat:@"%@|%@", r.filePath, @(r.fileSize)];
        NSNumber *cached = [cache objectForKey:key];
        if (cached) {
            r.lineCount = cached.integerValue;
        } else {
            [pending addObject:r];
        }
    }
    [_tableView reloadData];  // 缓存命中的行数先刷出来

    if (pending.count == 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (CSVRecord *r in pending) {
            NSString *key = [NSString stringWithFormat:@"%@|%@", r.filePath, @(r.fileSize)];
            NSInteger lines = [r countLinesInFileStreaming:r.filePath maxLines:kLineCountStatCap];
            [cache setObject:@(lines) forKey:key];
            r.lineCount = lines;  // NSInteger 写入,主线程 reload 后可见
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [_tableView reloadData];  // 一次性刷新行数列
        });
    });
}

- (void)reloadData {
    [self loadExistingCSVFiles];
}

- (void)addRecord:(CSVRecord *)record {
    [_csvRecords insertObject:record atIndex:0];
    [self loadExistingCSVFiles];  // 按 BBL 批次重聚(新记录可能归入已有组)
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
    [self updateEmptyState];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.recordGroups.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    CSVRecordGroup *group = self.recordGroups[section];
    return group.isExpanded ? (group.childRecords.count + 1) : 0;  // 展开时第 0 行 = 组内 S1
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CSVCell" forIndexPath:indexPath];

    CSVRecordGroup *group = self.recordGroups[indexPath.section];
    CSVRecord *record = (indexPath.row == 0) ? group.parentRecord : group.childRecords[indexPath.row - 1];

    // 🔑 V3 卡片行:白底圆角卡(云白间隙当分隔),复用时只建一次
    if (!cell.backgroundView) {
        UIView *wrap = [[UIView alloc] init];
        wrap.backgroundColor = [UIColor clearColor];
        UIView *card = [[UIView alloc] initWithFrame:CGRectInset(wrap.bounds, 8, 3)];
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        card.backgroundColor = NBTheme.card;
        card.layer.cornerRadius = 16;
        card.layer.borderWidth = 1;
        card.layer.borderColor = NBTheme.hairline.CGColor;
        [wrap addSubview:card];
        cell.backgroundView = wrap;
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    }

    UIListContentConfiguration *config = [UIListContentConfiguration subtitleCellConfiguration];
    config.textProperties.color = NBTheme.ink;
    config.textToSecondaryTextVerticalPadding = 3;

    // 🔹 Session 行(S 序号来自文件名"_sessionN",已是 1-based 人类序,显示不 +1)
    // 🔑 行数统计上限10万,到顶的文件显示"100000+行"而非误导性的精确值
    NSString *lineText = (record.lineCount >= kLineCountStatCap)
        ? [NSString stringWithFormat:@"%ld+ 行", (long)kLineCountStatCap]
        : [NSString stringWithFormat:@"%ld 行", (long)record.lineCount];
    config.text = [NSString stringWithFormat:@"S%ld · %@", (long)record.sessionIndex, record.displayName];
    config.secondaryText = [NSString stringWithFormat:@"%@ | %@\n%@",
            [record formattedFileSize],
            lineText,
            [record formattedCreateTime]];
    config.secondaryTextProperties.numberOfLines = 2;
    config.secondaryTextProperties.color = NBTheme.dim;
    config.image = [UIImage systemImageNamed:@"doc.text"];
    config.imageProperties.tintColor = NBTheme.accentBlue;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    cell.contentConfiguration = config;
    return cell;
}

#pragma mark - 组头(BBL 账本卡头)

/// 组头 = 账本卡:teal 圆点 + BBL 批次名 + 聚合元信息 + Session 数 + 折叠箭头;点击展开/收起
/// 🔑 实现:纯 frame 布局的普通 UIView——UITableViewHeaderFooterView + Auto Layout 在真机/模拟器
/// 上渲染为空白(排查实锤),换 frame 实现彻底绕开该坑;高度由 sectionHeaderHeight 固定 74 保证
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    CSVRecordGroup *group = self.recordGroups[section];
    CSVRecord *head = group.parentRecord;

    NSInteger totalSize = head.fileSize;
    NSInteger totalLines = head.lineCount;
    for (CSVRecord *child in group.childRecords) {
        totalSize += child.fileSize;
        totalLines += child.lineCount;
    }

    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, 74)];
    v.backgroundColor = [UIColor colorWithRed:1 green:0.87 blue:0.35 alpha:0.35];  // DEBUG:可见性探测底,显示确认后移除

    UIView *card = [[UIView alloc] initWithFrame:CGRectInset(v.bounds, 8, 3)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.backgroundColor = NBTheme.card;
    card.layer.cornerRadius = 16;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NBTheme.hairline.CGColor;
    [v addSubview:card];

    CGFloat cardW = CGRectGetWidth(card.bounds);

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(13, CGRectGetMidY(card.bounds) - 4.5, 9, 9)];
    dot.backgroundColor = NBTheme.accentGreen;
    dot.layer.cornerRadius = 4.5;
    [card addSubview:dot];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(31, 9, cardW - 31 - 16, 36)];
    name.text = group.groupKey;
    name.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    name.textColor = NBTheme.ink;
    name.numberOfLines = 2;
    name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:name];

    UILabel *count = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 104, CGRectGetMidY(card.bounds) - 7, 92, 14)];
    count.text = [NSString stringWithFormat:@"%ld 个Session", (long)(group.childRecords.count + 1)];
    count.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
    count.textColor = NBTheme.accentGreen;
    count.textAlignment = NSTextAlignmentRight;
    count.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [card addSubview:count];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectMake(31, 48, cardW - 31 - 18, 12)];
    meta.text = [NSString stringWithFormat:@"%ld SESSIONS · %.1f MB · %ld 行",
                 (long)(group.childRecords.count + 1),
                 totalSize / (1024.0 * 1024.0),
                 (long)totalLines];
    meta.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    meta.textColor = NBTheme.faint;
    meta.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:meta];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(groupHeadTapped:)];
    [v addGestureRecognizer:tap];
    v.tag = section;

    return v;
}

/// 组头点击 → 展开/收起该 BBL 组
- (void)groupHeadTapped:(UITapGestureRecognizer *)tap {
    [self toggleExpandForGroupAtIndex:tap.view.tag];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 所有 Session 行 → 操作菜单(组头的展开/收起在卡头点击,不占 didSelect)
    [self showActionSheetForRecord:[self recordAtIndexPath:indexPath]];
}

/// 组内寻址:row 0 = 父 Session(S1),其余 = 子 Session
- (nullable CSVRecord *)recordAtIndexPath:(NSIndexPath *)indexPath {
    CSVRecordGroup *group = self.recordGroups[indexPath.section];
    if (!group) return nil;
    if (indexPath.row == 0) return group.parentRecord;
    if (indexPath.row - 1 < (NSInteger)group.childRecords.count) return group.childRecords[indexPath.row - 1];
    return nil;
}

/**
 * 显示操作选项（预览/分析/删除）
 */
- (void)showActionSheetForRecord:(CSVRecord *)record {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:record.fileName
        message:@"请选择操作"
        preferredStyle:UIAlertControllerStyleActionSheet];

    // 📈 独立分析PID(新单屏三态页):蓝牙下载等 App 内 CSV 的主分析入口(预载直进结果态;
    // 结果缓存命中则免重分析秒出曲线)
    [alert addAction:[UIAlertAction actionWithTitle:@"📈 独立分析PID"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            IndependentAnalysisViewController *vc = [[IndependentAnalysisViewController alloc] init];
            vc.preloadedCSVPath = record.filePath;
            [self.navigationController pushViewController:vc animated:YES];
        }]];

    // 🔄 创建迭代PID方案:以此 CSV 为首飞轮建链进工作台(多轮闭环从这里起步)
    [alert addAction:[UIAlertAction actionWithTitle:@"🔄 创建迭代PID方案"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [IterationWorkbenchViewController presentNewChainForCSVPath:record.filePath
                                                     fromViewController:self];
        }]];

    // 炸机诊断(0.4a → push 独立诊断屏,不再内联建 VC)
    [alert addAction:[UIAlertAction actionWithTitle:@"🩺 炸机诊断"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            CrashDiagnosisViewController *diagVC = [[CrashDiagnosisViewController alloc]
                initWithCSVPath:record.filePath title:record.displayName];
            [self.navigationController pushViewController:diagVC animated:YES];
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

    // 原始转换产物:每行(含组头展开后的 S1)都可直接分享/重命名/删除
    CSVRecord *record = [self recordAtIndexPath:indexPath];

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

    return [UISwipeActionsConfiguration configurationWithActions:@[shareAction, renameAction, deleteAction]];
}

#pragma mark - 分组与显示辅助方法

/// 展开/折叠指定 BBL 组(整段 section 重建,卡头箭头/子行一并刷新)
- (void)toggleExpandForGroupAtIndex:(NSInteger)section {
    CSVRecordGroup *group = self.recordGroups[section];
    if (group.childRecords.count == 0) return;  // 单 Session 批次无子行
    group.isExpanded = !group.isExpanded;
    [_tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
              withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Actions

- (void)deleteRecordAtIndexPath:(NSIndexPath *)indexPath {
    // 原始转换产物语义:一次只删一个 Session 文件(整批清理走右上角清空)
    CSVRecord *record = [self recordAtIndexPath:indexPath];
    if (!record) return;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"删除这条 Session 记录?"
        message:[NSString stringWithFormat:@"「%@」将被删除,不可恢复。", record.displayName]
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performDeleteSingleRecord:record];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
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
    CSVRecord *record = [self recordAtIndexPath:indexPath];
    if (!record) return;
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
    CSVRecord *record = [self recordAtIndexPath:indexPath];
    if (!record) return;
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

    // 按 filePath 在分组结构中定位(section,row)后复用分享流程
    CSVRecord *targetRecord = _csvRecords[index];
    for (NSInteger s = 0; s < self.recordGroups.count; s++) {
        CSVRecordGroup *group = self.recordGroups[s];
        NSMutableArray<CSVRecord *> *all = [NSMutableArray arrayWithObject:group.parentRecord];
        [all addObjectsFromArray:group.childRecords];
        for (NSInteger r = 0; r < all.count; r++) {
            if ([all[r].filePath isEqualToString:targetRecord.filePath]) {
                [self shareRecordAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
                return;
            }
        }
    }
}

/**
 * 分析CSV文件
 */
@end
