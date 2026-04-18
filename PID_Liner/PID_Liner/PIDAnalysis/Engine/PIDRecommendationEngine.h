//
//  PIDRecommendationEngine.h
//  PID_Liner
//
//  第4层：诊断 → 推荐 → 预测曲线
//

#import <Foundation/Foundation.h>
#import "PIDCurveDiagnostic.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - PID参数值

/// PID四参数值
@interface PIDValues : NSObject

@property (nonatomic, assign) double p;
@property (nonatomic, assign) double i;
@property (nonatomic, assign) double d;
@property (nonatomic, assign) double ff;

/// 从字典构建 {p:, i:, d:, ff:}
+ (instancetype)fromDictionary:(NSDictionary *)dict;

/// 转换为字典
- (NSDictionary *)toDictionary;

@end

#pragma mark - 推荐结果

/// 单轴推荐结果
@interface PIDTuningResult : NSObject

@property (nonatomic, strong) PIDValues *recommendedPID;          // 推荐的新PID值
@property (nonatomic, strong) PIDValues *originalPID;             // 原始PID值
@property (nonatomic, strong) NSArray<NSNumber *> *predictedCurve; // 预测曲线
@property (nonatomic, assign) double predictedOvershoot;          // 预测超调
@property (nonatomic, assign) double predictedRiseTime;           // 预测上升时间
@property (nonatomic, copy) NSString *reasoning;                  // 推理说明

@end

#pragma mark - 推荐引擎

/// 基于诊断结果推荐参数变更，并用二阶系统模型生成预测曲线
@interface PIDRecommendationEngine : NSObject

/**
 * 为单轴生成推荐
 * @param diagnosis 单轴诊断结果
 * @param currentPID 当前PID值 (可为nil，使用默认值)
 * @param currentResponse 当前阶跃响应曲线
 * @param sampleRate 采样率
 * @return 推荐结果
 */
- (PIDTuningResult *)generateRecommendationWithDiagnosis:(PIDAxisDiagnosis *)diagnosis
                                               currentPID:(nullable PIDValues *)currentPID
                                          currentResponse:(NSArray<NSNumber *> *)currentResponse
                                              sampleRate:(double)sampleRate;

/**
 * 用二阶系统模型生成预测阶跃响应曲线
 * @param gain K (增益)
 * @param naturalFreq wn (自然频率 rad/s)
 * @param dampingRatio zeta (阻尼比)
 * @param length 曲线点数
 * @param duration 时间范围 (秒)
 * @return 预测曲线
 */
+ (NSArray<NSNumber *> *)predictedCurveWithGain:(double)gain
                                   naturalFreq:(double)naturalFreq
                                  dampingRatio:(double)dampingRatio
                                        length:(NSInteger)length
                                     duration:(double)duration;

@end

NS_ASSUME_NONNULL_END
