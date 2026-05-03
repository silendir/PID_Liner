//
//  IterationChainManager.h
//  PID_Liner
//
//  迭代闭环调参 — 迭代链管理器
//  管理所有迭代链的 CRUD，按 chainId 持久化到 Documents/IterationChains/
//

#import <Foundation/Foundation.h>
#import "IterationChain.h"

NS_ASSUME_NONNULL_BEGIN

/// 迭代链管理器（单例）
@interface IterationChainManager : NSObject

+ (instancetype)sharedManager;

/// 最大保留轮数（每条链）
@property (nonatomic, readonly) NSInteger maxIterations;

#pragma mark - 查询

/// 获取指定链ID的迭代链
- (nullable IterationChain *)chainForId:(NSString *)chainId;

/// 获取指定飞行器的所有迭代链
- (NSArray<IterationChain *> *)chainsForCraft:(NSString *)craftName;

/// 获取所有迭代链
- (NSArray<IterationChain *> *)allChains;

#pragma mark - 创建（首次BBL→CSV时调用）

/// 为一个初始CSV创建新的迭代链
/// @param craftName 飞行器名称
/// @param csvPath 初始CSV文件路径
/// @param sessionIndex Session索引
/// @return 新创建的迭代链
- (IterationChain *)createChainWithCraftName:(NSString *)craftName
                                    csvPath:(NSString *)csvPath
                                sessionIndex:(NSInteger)sessionIndex;

#pragma mark - 追加（二轮+迭代时调用）

/// 向指定链追加一轮调参记录
/// @param record 调参记录
/// @param chainId 目标链ID
- (void)appendRecord:(PIDTuningRecord *)record toChain:(NSString *)chainId;

#pragma mark - 删除

/// 删除指定链
- (void)deleteChain:(NSString *)chainId;

/// 删除指定飞行器的所有链
- (void)deleteChainsForCraft:(NSString *)craftName;

@end

NS_ASSUME_NONNULL_END
