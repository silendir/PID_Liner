//
//  PIDTuningRecord.h
//  PID_Liner
//
//  迭代闭环调参 — 单轮调参记录数据模型
//

#import <Foundation/Foundation.h>
#import "PIDRecommendationEngine.h"
#import "PIDDataModels.h"

NS_ASSUME_NONNULL_BEGIN

/// 单轴调参快照（实际特征 + 预测特征 + 推荐PID）
@interface PIDAxisTuningSnapshot : NSObject

@property (nonatomic, strong) PIDValues *recommendedPID;       // 本轮推荐PID
@property (nonatomic, strong) PIDValues *originalPID;          // 本轮原始PID
@property (nonatomic, strong, nullable) PIDResponseFeatures *actualFeatures;    // 实际曲线特征
@property (nonatomic, strong, nullable) PIDResponseFeatures *predictedFeatures; // 预测曲线特征
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *predictedCurve;    // 预测曲线数据

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end

/// 单轮调参记录
@interface PIDTuningRecord : NSObject

@property (nonatomic, copy) NSString *craftName;               // 飞机名称（主键）
@property (nonatomic, assign) NSInteger iteration;             // 第几轮 (1-based)
@property (nonatomic, strong) NSDate *createdAt;               // 创建时间
@property (nonatomic, copy) NSString *csvFileName;             // 源CSV文件名

/// 三轴快照
@property (nonatomic, strong) PIDAxisTuningSnapshot *rollSnapshot;
@property (nonatomic, strong) PIDAxisTuningSnapshot *pitchSnapshot;
@property (nonatomic, strong) PIDAxisTuningSnapshot *yawSnapshot;

/// CLI命令文本
@property (nonatomic, copy, nullable) NSString *cliCommands;

/// CLI 命令是否为 Slider 格式（包含 simplified_ 前缀）
@property (nonatomic, readonly) BOOL usesSliderFormat;

/// 修正系数 (从历史误差累积)
@property (nonatomic, assign) double gainCorrection;           // P变化对K的修正乘数
@property (nonatomic, assign) double dampingCorrection;        // D变化对ζ的修正乘数
@property (nonatomic, assign) double freqCorrection;           // FF变化对ωn的修正乘数

/// CSV数据指纹（用于检测重复导入同一份数据）
@property (nonatomic, copy, nullable) NSString *csvFingerprint; // 格式: "dataLength|md5前100行"

/// 飞行时间（从BBL header读取的真实飞行时刻）
@property (nonatomic, strong, nullable) NSDate *flightTime;

/// 收敛状态
@property (nonatomic, assign) double accuracy;                 // 本轮预测准确度 [0,1]
@property (nonatomic, assign) BOOL isConverged;                // 是否已收敛

/// 序列化
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

/// 获取指定轴的快照
- (nullable PIDAxisTuningSnapshot *)snapshotForAxis:(NSInteger)axisIndex;

@end

NS_ASSUME_NONNULL_END
