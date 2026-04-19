//
//  PIDTuningHistoryManager.h
//  PID_Liner
//
//  迭代闭环调参 — 调参历史持久化管理器
//  按 craftName 分组存储，每架飞机最多保留5轮记录(FIFO)
//

#import <Foundation/Foundation.h>
#import "PIDTuningRecord.h"

NS_ASSUME_NONNULL_BEGIN

/// 调参历史管理器
@interface PIDTuningHistoryManager : NSObject

/// 单例
+ (instancetype)sharedManager;

/// 最大保留轮数
@property (nonatomic, readonly) NSInteger maxIterations;

#pragma mark - 查询

/// 获取指定飞机的调参历史（按时间升序）
/// @param craftName 飞机名称
/// @return 调参记录数组，可能为空
- (NSArray<PIDTuningRecord *> *)recordsForCraft:(NSString *)craftName;

/// 获取指定飞机的最新一轮记录
/// @param craftName 飞机名称
/// @return 最新的记录，无历史则返回nil
- (nullable PIDTuningRecord *)latestRecordForCraft:(NSString *)craftName;

/// 获取指定飞机的下一轮迭代号
/// @param craftName 飞机名称
/// @return 下一轮号 (1-based)
- (NSInteger)nextIterationForCraft:(NSString *)craftName;

/// 获取所有飞机名称列表
- (NSArray<NSString *> *)allCraftNames;

#pragma mark - 写入

/// 保存一轮调参记录（自动FIFO淘汰）
/// @param record 调参记录
- (void)saveRecord:(PIDTuningRecord *)record;

#pragma mark - 删除

/// 删除指定飞机的全部调参历史
/// @param craftName 飞机名称
- (void)deleteHistoryForCraft:(NSString *)craftName;

/// 删除所有飞机的全部调参历史
- (void)deleteAllHistory;

@end

NS_ASSUME_NONNULL_END
