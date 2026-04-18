//
//  PIDCurveDiagnostic.h
//  PID_Liner
//
//  第3层：曲线特征 → 诊断 → 评分
//

#import <Foundation/Foundation.h>
#import "PIDDataModels.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 诊断问题

/// 单个PID问题
@interface PIDIssue : NSObject

@property (nonatomic, copy) NSString *issueType;      // "overshoot", "slow_response", "d_noise", "oscillation", "low_i"
@property (nonatomic, assign) double severity;         // 0~1 严重度
@property (nonatomic, copy) NSString *localizedDesc;   // 中文描述
@property (nonatomic, copy) NSString *suggestedAction; // 建议动作 (如 "P × 0.7")

@end

#pragma mark - 单轴诊断结果

/// 单轴PID诊断结果
@interface PIDAxisDiagnosis : NSObject

@property (nonatomic, assign) NSInteger axisIndex;       // 0=Roll 1=Pitch 2=Yaw
@property (nonatomic, copy) NSString *axisName;           // "Roll", "Pitch", "Yaw"
@property (nonatomic, assign) double score;               // 0~100
@property (nonatomic, strong) NSArray<PIDIssue *> *issues;
@property (nonatomic, strong) PIDResponseFeatures *features; // 原始特征

@end

#pragma mark - 综合诊断结果

/// 三轴综合诊断
@interface PIDCurveDiagnostic : NSObject

/// 三轴诊断结果
@property (nonatomic, strong) NSArray<PIDAxisDiagnosis *> *axisDiagnoses;

/// 综合评分 (0~100)
@property (nonatomic, assign) double overallScore;

/// 诊断摘要
@property (nonatomic, copy) NSString *summary;

/**
 * 从三轴特征执行诊断
 * @param features 三轴特征数组 [Roll, Pitch, Yaw]
 * @return 综合诊断结果
 */
+ (instancetype)diagnoseWithFeatures:(NSArray<PIDResponseFeatures *> *)features;

@end

NS_ASSUME_NONNULL_END
