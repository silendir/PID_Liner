//
//  IterationChain.h
//  PID_Liner
//
//  迭代闭环调参 — 迭代链数据模型
//  一条迭代链 = 一个Session的完整调参迭代历史
//  首轮由 BBL→CSV 创建，后续轮次通过"导入下一轮返参"追加
//

#import <Foundation/Foundation.h>
#import "PIDTuningRecord.h"

NS_ASSUME_NONNULL_BEGIN

/// 迭代链（一条完整的调参迭代历史）
@interface IterationChain : NSObject

/// 链唯一标识（自动生成的UUID）
@property (nonatomic, copy) NSString *chainId;

/// 飞行器名称（来自BBL header的craftName）
@property (nonatomic, copy) NSString *craftName;

/// 链创建时间（首次BBL→CSV时）
@property (nonatomic, strong) NSDate *createdAt;

/// 初始CSV文件路径（链的起点）
@property (nonatomic, copy) NSString *initialCSVPath;

/// 初始Session索引
@property (nonatomic, assign) NSInteger initialSessionIndex;

/// 调参记录数组（按 iteration 升序，每轮一条）
@property (nonatomic, strong) NSMutableArray<PIDTuningRecord *> *records;

/// 链是否已收敛
@property (nonatomic, assign) BOOL isConverged;

/// 当前轮次号 = records.count + 1
@property (nonatomic, readonly) NSInteger currentIteration;

/// 序列化
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

/// 追加一轮调参记录
- (void)appendRecord:(PIDTuningRecord *)record;

/// 获取最新一轮记录
- (nullable PIDTuningRecord *)latestRecord;

@end

NS_ASSUME_NONNULL_END
