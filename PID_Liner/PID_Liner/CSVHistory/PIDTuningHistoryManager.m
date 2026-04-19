//
//  PIDTuningHistoryManager.m
//  PID_Liner
//
//  迭代闭环调参 — 调参历史持久化管理器
//

#import "PIDTuningHistoryManager.h"

/// 最大保留轮数
static const NSInteger kMaxIterations = 5;

/// 历史文件存储目录
static NSString *const kHistoryDirectoryName = @"PIDTuningHistory";

@implementation PIDTuningHistoryManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static PIDTuningHistoryManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self ensureDirectoryExists];
    }
    return self;
}

- (NSInteger)maxIterations {
    return kMaxIterations;
}

#pragma mark - 查询

- (NSArray<PIDTuningRecord *> *)recordsForCraft:(NSString *)craftName {
    if (!craftName.length) return @[];

    NSDictionary *json = [self loadJSONForCraft:craftName];
    if (!json) return @[];

    NSArray *recordsArray = json[@"records"];
    if (!recordsArray) return @[];

    NSMutableArray<PIDTuningRecord *> *records = [NSMutableArray arrayWithCapacity:recordsArray.count];
    for (NSDictionary *dict in recordsArray) {
        PIDTuningRecord *record = [PIDTuningRecord fromDictionary:dict];
        if (record) {
            [records addObject:record];
        }
    }

    // 按 iteration 升序排列
    [records sortUsingComparator:^NSComparisonResult(PIDTuningRecord *a, PIDTuningRecord *b) {
        return [@(a.iteration) compare:@(b.iteration)];
    }];

    return [records copy];
}

- (nullable PIDTuningRecord *)latestRecordForCraft:(NSString *)craftName {
    NSArray *records = [self recordsForCraft:craftName];
    return records.lastObject;
}

- (NSInteger)nextIterationForCraft:(NSString *)craftName {
    NSArray *records = [self recordsForCraft:craftName];
    if (records.count == 0) return 1;
    NSInteger maxIteration = 0;
    for (PIDTuningRecord *r in records) {
        if (r.iteration > maxIteration) maxIteration = r.iteration;
    }
    return maxIteration + 1;
}

- (NSArray<NSString *> *)allCraftNames {
    NSString *dir = [self historyDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&error];
    if (error) {
        NSLog(@"⚠️ [调参历史] 读取目录失败: %@", error.localizedDescription);
        return @[];
    }

    NSMutableArray *names = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file hasSuffix:@".json"]) {
            NSString *name = [file stringByDeletingPathExtension];
            [names addObject:name];
        }
    }
    return [names copy];
}

#pragma mark - 写入

- (void)saveRecord:(PIDTuningRecord *)record {
    if (!record || !record.craftName.length) {
        NSLog(@"⚠️ [调参历史] 保存失败: 记录无效或craftName为空");
        return;
    }

    // 加载现有记录
    NSMutableArray<PIDTuningRecord *> *records = [[self recordsForCraft:record.craftName] mutableCopy];

    // 追加新记录
    [records addObject:record];

    // FIFO淘汰：超过最大轮数则删除最旧的
    while (records.count > kMaxIterations) {
        [records removeObjectAtIndex:0];
        NSLog(@"🗑 [调参历史] FIFO淘汰最旧记录 (%@)", record.craftName);
    }

    // 保存到文件
    [self saveRecords:records forCraft:record.craftName];

    NSLog(@"💾 [调参历史] 保存第%ld轮记录 (%@), 共%lu轮",
          (long)record.iteration, record.craftName, (unsigned long)records.count);
}

#pragma mark - 删除

- (void)deleteHistoryForCraft:(NSString *)craftName {
    if (!craftName.length) return;

    NSString *filePath = [self filePathForCraft:craftName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:filePath]) {
        NSError *error = nil;
        [fm removeItemAtPath:filePath error:&error];
        if (error) {
            NSLog(@"⚠️ [调参历史] 删除失败: %@", error.localizedDescription);
        } else {
            NSLog(@"🗑 [调参历史] 已删除 %@ 的全部历史", craftName);
        }
    }
}

- (void)deleteAllHistory {
    NSString *dir = [self historyDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&error];
    if (error) return;

    for (NSString *file in files) {
        if ([file hasSuffix:@".json"]) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:file] error:nil];
        }
    }
    NSLog(@"🗑 [调参历史] 已删除全部历史");
}

#pragma mark - 私有方法

/// 历史文件目录
- (NSString *)historyDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject;
    return [docs stringByAppendingPathComponent:kHistoryDirectoryName];
}

/// 指定飞机的JSON文件路径
- (NSString *)filePathForCraft:(NSString *)craftName {
    // craftName可能包含特殊字符，需编码为安全文件名
    NSString *safeName = [self safeFileNameFromCraftName:craftName];
    return [[self historyDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", safeName]];
}

/// 加载指定飞机的JSON
- (nullable NSDictionary *)loadJSONForCraft:(NSString *)craftName {
    NSString *filePath = [self filePathForCraft:craftName];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) return nil;

    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"⚠️ [调参历史] 解析JSON失败: %@", error.localizedDescription);
        return nil;
    }
    return json;
}

/// 保存记录数组到JSON文件
- (void)saveRecords:(NSArray<PIDTuningRecord *> *)records forCraft:(NSString *)craftName {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:records.count];
    for (PIDTuningRecord *r in records) {
        [array addObject:[r toDictionary]];
    }

    NSDictionary *json = @{@"records": array};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&error];
    if (error || !data) {
        NSLog(@"⚠️ [调参历史] 序列化失败: %@", error.localizedDescription);
        return;
    }

    NSString *filePath = [self filePathForCraft:craftName];
    [data writeToFile:filePath atomically:YES];
}

/// craftName → 安全文件名（去除/:\*?等特殊字符）
- (NSString *)safeFileNameFromCraftName:(NSString *)craftName {
    NSCharacterSet *invalidChars = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSMutableString *safe = [craftName mutableCopy];
    [safe replaceOccurrencesOfString:@" "
                          withString:@"_"
                             options:0
                               range:NSMakeRange(0, safe.length)];
    // 移除非法字符
    NSArray *components = [safe componentsSeparatedByCharactersInSet:invalidChars];
    return [components componentsJoinedByString:@""];
}

/// 确保历史目录存在
- (void)ensureDirectoryExists {
    NSString *dir = [self historyDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
}

@end
