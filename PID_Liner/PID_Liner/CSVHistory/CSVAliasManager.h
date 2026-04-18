//
//  CSVAliasManager.h
//  PID_Liner
//
//  CSV 文件别名管理器
//  功能：管理 CSV 文件的显示名称别名，实现自定义文件名而不改变实际文件名
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CSVAliasManager : NSObject

/**
 * 单例实例
 */
+ (instancetype)sharedManager;

/**
 * 获取指定文件的别名
 * @param fileName 实际文件名（含 .csv 后缀）
 * @return 别名，如果未设置则返回 nil
 */
- (nullable NSString *)aliasForFileName:(NSString *)fileName;

/**
 * 设置指定文件的别名
 * @param alias 别名（不含 .csv 后缀，会自动添加）
 * @param fileName 实际文件名（含 .csv 后缀）
 */
- (void)setAlias:(NSString *)alias forFileName:(NSString *)fileName;

/**
 * 移除指定文件的别名
 * @param fileName 实际文件名（含 .csv 后缀）
 */
- (void)removeAliasForFileName:(NSString *)fileName;

/**
 * 判断指定文件是否有别名
 * @param fileName 实际文件名（含 .csv 后缀）
 * @return YES 表示有别名，NO 表示无别名
 */
- (BOOL)hasAliasForFileName:(NSString *)fileName;

/**
 * 生成不重复的别名（自动添加后缀）
 * @param baseAlias 基础别名
 * @return 不重复的别名（如 "测试(2)"）
 */
- (NSString *)uniqueAliasWithBase:(NSString *)baseAlias excludingFileName:(nullable NSString *)excludeFileName;

/**
 * 获取所有别名映射
 * @return 字典，key 为实际文件名，value 为别名
 */
- (NSDictionary<NSString *, NSString *> *)allAliases;

/**
 * 清空所有别名
 */
- (void)clearAllAliases;

@end

NS_ASSUME_NONNULL_END
