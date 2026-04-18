//
//  CSVAliasManager.m
//  PID_Liner
//
//  CSV 文件别名管理器实现
//

#import "CSVAliasManager.h"

// UserDefaults 存储键
static NSString *const kCSVFileAliasesKey = @"CSVFileAliases";

@implementation CSVAliasManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static CSVAliasManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 确保存储字典存在
        if ([self aliasesDictionary] == nil) {
            [self saveAliasesDictionary:@{}];
        }
    }
    return self;
}

#pragma mark - Private Methods

/**
 * 从 UserDefaults 读取别名字典
 */
- (nullable NSDictionary<NSString *, NSString *> *)aliasesDictionary {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:kCSVFileAliasesKey];
}

/**
 * 保存别名字典到 UserDefaults
 */
- (void)saveAliasesDictionary:(NSDictionary<NSString *, NSString *> *)aliases {
    [[NSUserDefaults standardUserDefaults] setObject:aliases forKey:kCSVFileAliasesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/**
 * 获取所有已使用的别名（用于查重）
 * @param excludeFileName 排除的文件名（用于重命名时排除自己）
 */
- (NSSet<NSString *> *)allUsedAliasesExcludingFileName:(nullable NSString *)excludeFileName {
    NSDictionary *aliases = [self aliasesDictionary];
    NSMutableSet *usedAliases = [NSMutableSet setWithCapacity:aliases.count];

    for (NSString *fileName in aliases) {
        // 如果是当前文件自己，跳过（用于重命名时查重）
        if (excludeFileName && [fileName isEqualToString:excludeFileName]) {
            continue;
        }
        NSString *alias = aliases[fileName];
        if (alias) {
            [usedAliases addObject:alias];
        }
    }

    return usedAliases;
}

#pragma mark - Public Methods

- (nullable NSString *)aliasForFileName:(NSString *)fileName {
    if (!fileName) return nil;

    NSDictionary *aliases = [self aliasesDictionary];
    return aliases[fileName];
}

- (void)setAlias:(NSString *)alias forFileName:(NSString *)fileName {
    if (!fileName || !alias) return;

    NSMutableDictionary *aliases = [[self aliasesDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];

    // 如果别名为空，则移除别名
    if (alias.length == 0) {
        [aliases removeObjectForKey:fileName];
    } else {
        aliases[fileName] = alias;
    }

    [self saveAliasesDictionary:aliases];

    NSLog(@"🏷️ 设置别名: %@ → %@", fileName, alias);
}

- (void)removeAliasForFileName:(NSString *)fileName {
    if (!fileName) return;

    NSMutableDictionary *aliases = [[self aliasesDictionary] mutableCopy];
    [aliases removeObjectForKey:fileName];
    [self saveAliasesDictionary:aliases];

    NSLog(@"🏷️ 移除别名: %@", fileName);
}

- (BOOL)hasAliasForFileName:(NSString *)fileName {
    if (!fileName) return NO;

    NSString *alias = [self aliasForFileName:fileName];
    return alias != nil && alias.length > 0;
}

- (NSString *)uniqueAliasWithBase:(NSString *)baseAlias excludingFileName:(nullable NSString *)excludeFileName {
    if (!baseAlias || baseAlias.length == 0) {
        return baseAlias;
    }

    NSString *cleanBase = [baseAlias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (cleanBase.length == 0) {
        return cleanBase;
    }

    NSSet *usedAliases = [self allUsedAliasesExcludingFileName:excludeFileName];

    // 如果没有重复，直接返回
    if (![usedAliases containsObject:cleanBase]) {
        return cleanBase;
    }

    // 有重复，添加后缀 (1), (2), (3)...
    NSInteger suffix = 1;
    NSString *uniqueAlias;

    do {
        uniqueAlias = [NSString stringWithFormat:@"%@(%ld)", cleanBase, (long)suffix];
        suffix++;
    } while ([usedAliases containsObject:uniqueAlias]);

    NSLog(@"🏷️ 别名重复，自动添加后缀: %@ → %@", baseAlias, uniqueAlias);
    return uniqueAlias;
}

- (NSDictionary<NSString *, NSString *> *)allAliases {
    return [self aliasesDictionary] ?: @{};
}

- (void)clearAllAliases {
    [self saveAliasesDictionary:@{}];
    NSLog(@"🏷️ 清空所有别名");
}

@end
