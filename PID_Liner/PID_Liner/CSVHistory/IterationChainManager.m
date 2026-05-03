//
//  IterationChainManager.m
//  PID_Liner
//
//  迭代闭环调参 — 迭代链管理器实现
//

#import "IterationChainManager.h"

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
    }
    return self;
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
    record.iteration = chain.currentIteration;

    [chain appendRecord:record];

    // FIFO淘汰：超过最大轮数则删除最旧的
    while (chain.records.count > kMaxIterations) {
        [chain.records removeObjectAtIndex:0];
        NSLog(@"🗑 [迭代链] FIFO淘汰最旧记录 (链%@)", chainId);
    }

    [self saveChain:chain];

    NSLog(@"💾 [迭代链] 追加第%ld轮到链%@ (%@)",
          (long)record.iteration, chainId, chain.craftName);
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
    NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:&error];
    if (error || !data) {
        NSLog(@"⚠️ [迭代链] 序列化失败: %@", error.localizedDescription);
        return;
    }

    NSString *filePath = [self filePathForChainId:chain.chainId];
    [data writeToFile:filePath atomically:YES];
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
