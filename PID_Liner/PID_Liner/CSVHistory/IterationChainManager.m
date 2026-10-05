//
//  IterationChainManager.m
//  PID_Liner
//
//  迭代闭环调参 — 迭代链管理器实现
//

#import "IterationChainManager.h"
#import <math.h>

NSString * const IterationChainDidUpdateNotification = @"IterationChainDidUpdateNotification";

/// 链记录落盘后广播(主线程调用):工作台据此即时刷新 chip/轮次链
static void PostChainDidUpdate(NSString *chainId) {
    if (!chainId.length) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:IterationChainDidUpdateNotification
                                                        object:nil
                                                      userInfo:@{@"chainId": chainId}];
}

/// 🔬 递归清洗 JSON 不安全数值:NaN/Infinity 的 NSNumber → @0(计数入 *cleaned)
/// NSJSONSerialization 遇单个非法数即整体失败,链文件将写不进磁盘
static id MakeJSONSafe(id value, NSUInteger *cleaned) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double d = ((NSNumber *)value).doubleValue;
        if (isnan(d) || isinf(d)) {
            if (cleaned) (*cleaned)++;
            return @0;
        }
        return value;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            out[k] = MakeJSONSafe(v, cleaned);
        }];
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
        for (id v in (NSArray *)value) [out addObject:MakeJSONSafe(v, cleaned)];
        return out;
    }
    return value;
}

/// 最大保留轮数
static const NSInteger kMaxIterations = 5;

/// 存储目录名
static NSString *const kChainDirectoryName = @"IterationChains";

@implementation IterationChainManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static IterationChainManager *instance = nil;
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
        [self pruneDuplicateFingerprintRecords];
    }
    return self;
}

/// 🔧 一次性数据修复:剔除"同 CSV 指纹连续重复"的假轮次。
/// 成因=指纹幂等守卫上线前,反复进出工作台把同一 CSV 分析 N 次攒出 N 条重复记录;
/// 同指纹连续记录按定义不可能是真实的换参迭代,保留首条(真实轮)其余清除。
- (void)pruneDuplicateFingerprintRecords {
    NSString *dir = [self chainDirectory];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:file];
        IterationChain *chain = [self loadChainFromFile:path];
        if (chain.records.count < 2) continue;

        NSMutableArray<PIDTuningRecord *> *pruned = [NSMutableArray array];
        NSString *lastKeptFingerprint = nil;
        NSInteger removed = 0;
        for (PIDTuningRecord *r in chain.records) {
            if (r.csvFingerprint.length > 0 && [r.csvFingerprint isEqualToString:lastKeptFingerprint]) {
                removed++;  // 与上一条保留记录同指纹 = 重复分析的假轮次
                continue;
            }
            [pruned addObject:r];
            lastKeptFingerprint = r.csvFingerprint;
        }
        if (removed > 0) {
            chain.records = [pruned copy];
            [self saveChain:chain];
            NSLog(@"🧹 [迭代链] 已清除 %ld 条假轮次(链 %@)", (long)removed, chain.chainId);
        }
    }
}

- (NSInteger)maxIterations {
    return kMaxIterations;
}

#pragma mark - 查询

- (nullable IterationChain *)chainForId:(NSString *)chainId {
    if (!chainId.length) return nil;
    NSString *filePath = [self filePathForChainId:chainId];
    return [self loadChainFromFile:filePath];
}

- (NSArray<IterationChain *> *)chainsForCraft:(NSString *)craftName {
    if (!craftName.length) return @[];

    NSArray<IterationChain *> *all = [self allChains];
    NSMutableArray<IterationChain *> *filtered = [NSMutableArray array];
    for (IterationChain *chain in all) {
        if ([chain.craftName isEqualToString:craftName]) {
            [filtered addObject:chain];
        }
    }

    // 按 createdAt 升序
    [filtered sortUsingComparator:^NSComparisonResult(IterationChain *a, IterationChain *b) {
        return [a.createdAt compare:b.createdAt];
    }];

    return [filtered copy];
}

- (NSArray<IterationChain *> *)allChains {
    NSString *dir = [self chainDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&error];
    if (error) {
        NSLog(@"⚠️ [迭代链] 读取目录失败: %@", error.localizedDescription);
        return @[];
    }

    NSMutableArray<IterationChain *> *chains = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"json"]) {
            NSString *filePath = [dir stringByAppendingPathComponent:file];
            IterationChain *chain = [self loadChainFromFile:filePath];
            if (chain) {
                [chains addObject:chain];
            }
        }
    }

    return [chains copy];
}

#pragma mark - 创建

- (IterationChain *)createChainWithCraftName:(NSString *)craftName
                                     csvPath:(NSString *)csvPath
                                 sessionIndex:(NSInteger)sessionIndex {
    IterationChain *chain = [[IterationChain alloc] init];
    chain.craftName = craftName ?: @"";
    chain.initialCSVPath = csvPath;
    chain.initialSessionIndex = sessionIndex;

    [self saveChain:chain];

    NSLog(@"🔗 [迭代链] 创建新链: %@ (session %ld)", chain.chainId, (long)sessionIndex);
    return chain;
}

#pragma mark - 追加

- (void)appendRecord:(PIDTuningRecord *)record toChain:(NSString *)chainId {
    if (!record || !chainId.length) {
        NSLog(@"⚠️ [迭代链] 追加失败: record或chainId为空");
        return;
    }

    IterationChain *chain = [self chainForId:chainId];
    if (!chain) {
        NSLog(@"⚠️ [迭代链] 未找到链: %@", chainId);
        return;
    }

    // 设置 iteration 为链的当前轮次
    record.iteration = chain.nextIterationNumber;

    [chain appendRecord:record];

    // FIFO淘汰：超过最大轮数则删除最旧的
    while (chain.records.count > kMaxIterations) {
        [chain.records removeObjectAtIndex:0];
        NSLog(@"🗑 [迭代链] FIFO淘汰最旧记录 (链%@)", chainId);
    }

    [self saveChain:chain];

    NSLog(@"💾 [迭代链] 追加第%ld轮到链%@ (%@)",
          (long)record.iteration, chainId, chain.craftName);
    PostChainDidUpdate(chainId);
}

#pragma mark - 撤销(Q7)

/// 移除最新一轮(Q7:只删最新轮 + 硬删;空链/无链无操作)
- (void)removeLastRecordFromChain:(NSString *)chainId {
    if (!chainId.length) return;
    IterationChain *chain = [self chainForId:chainId];
    if (!chain) {
        NSLog(@"⚠️ [迭代链] 撤销失败,未找到链: %@", chainId);
        return;
    }
    if (chain.records.count == 0) return;
    [chain removeLastRecord];
    [self saveChain:chain];
    NSLog(@"↩ [迭代链] 已撤销链%@最新轮 (剩余%lu轮)", chainId, (unsigned long)chain.records.count);
    PostChainDidUpdate(chainId);
}

/// 重命名方案(改链 craftName 并持久化;首页方案列表/工作台链头随之更新)
- (void)updateCraftName:(NSString *)craftName forChain:(NSString *)chainId {
    if (!chainId.length || craftName.length == 0) return;
    IterationChain *chain = [self chainForId:chainId];
    if (!chain) {
        NSLog(@"⚠️ [迭代链] 改名失败,未找到链: %@", chainId);
        return;
    }
    chain.craftName = craftName;
    [self saveChain:chain];
    NSLog(@"✏️ [迭代链] 方案改名: %@ → %@", chainId, craftName);
    PostChainDidUpdate(chainId);
}

#pragma mark - 删除

- (void)deleteChain:(NSString *)chainId {
    if (!chainId.length) return;

    NSString *filePath = [self filePathForChainId:chainId];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:filePath]) {
        NSError *error = nil;
        [fm removeItemAtPath:filePath error:&error];
        if (error) {
            NSLog(@"⚠️ [迭代链] 删除失败: %@", error.localizedDescription);
        } else {
            NSLog(@"🗑 [迭代链] 已删除链: %@", chainId);
        }
    }
}

- (void)deleteChainsForCraft:(NSString *)craftName {
    NSArray<IterationChain *> *chains = [self chainsForCraft:craftName];
    for (IterationChain *chain in chains) {
        [self deleteChain:chain.chainId];
    }
}

#pragma mark - 私有方法

/// 迭代链存储目录
- (NSString *)chainDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject;
    return [docs stringByAppendingPathComponent:kChainDirectoryName];
}

/// 链ID对应的JSON文件路径
- (NSString *)filePathForChainId:(NSString *)chainId {
    return [[self chainDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", chainId]];
}

/// 从文件加载迭代链
- (nullable IterationChain *)loadChainFromFile:(NSString *)filePath {
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) return nil;

    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"⚠️ [迭代链] 解析JSON失败: %@", error.localizedDescription);
        return nil;
    }

    return [IterationChain fromDictionary:json];
}

/// 保存迭代链到文件
- (void)saveChain:(IterationChain *)chain {
    if (!chain || !chain.chainId.length) return;

    NSDictionary *json = [chain toDictionary];
    NSError *error = nil;
    // 🔬 序列化边界统一清洗:特征数字可合法产生 NaN/∞(如 稳态=0 时 超调=∞),
    // NSJSONSerialization 遇之整体失败 → 链文件永远写不进磁盘
    // → 数据齐全的方案定格"尚未飞行 0 轮"(真机已踩,144704 数字干净成功/151324 中毒失败)
    NSUInteger cleaned = 0;
    id safeJson = MakeJSONSafe(json, &cleaned);
    NSData *data = [NSJSONSerialization dataWithJSONObject:safeJson
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&error];
    if (error || !data) {
        NSLog(@"⚠️ [迭代链] 序列化失败: %@", error.localizedDescription);
        return;
    }
    if (cleaned > 0) {
        NSLog(@"🧹 [迭代链] 清洗 %lu 个非法数值(NaN/∞→0)后成功序列化", (unsigned long)cleaned);
    }

    NSString *filePath = [self filePathForChainId:chain.chainId];
    if (![data writeToFile:filePath atomically:YES]) {
        NSLog(@"⚠️ [迭代链] 链文件写盘失败: %@", filePath);
    }
}

/// 确保目录存在
- (void)ensureDirectoryExists {
    NSString *dir = [self chainDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
}

@end
