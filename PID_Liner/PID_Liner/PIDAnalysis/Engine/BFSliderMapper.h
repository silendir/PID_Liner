//
//  BFSliderMapper.h
//  PID_Liner
//
//  BF Simplified Tuning (Slider) 正/反向映射器
//  参考: BF 源码 simplified_tuning.c — calculateNewPidValues()
//

#import <Foundation/Foundation.h>
#import "PIDRecommendationEngine.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Slider 倍率值

/// BF Simplified Tuning 7 个 Slider 参数（值域 [0, 200]，100 = 1.0x 默认值）
@interface BFSliderValues : NSObject

@property (nonatomic, assign) NSInteger piGain;            // simplified_pi_gain
@property (nonatomic, assign) NSInteger iGain;             // simplified_i_gain
@property (nonatomic, assign) NSInteger dGain;             // simplified_d_gain
@property (nonatomic, assign) NSInteger ffGain;            // simplified_feedforward_gain
@property (nonatomic, assign) NSInteger dMaxGain;          // simplified_d_max_gain
@property (nonatomic, assign) NSInteger pitchPiGain;       // simplified_pitch_pi_gain
@property (nonatomic, assign) NSInteger rollPitchRatio;    // simplified_roll_pitch_ratio

@end

#pragma mark - BF Slider 映射器

/// PID 真值 ↔ BF Slider 倍率双向转换
/// 公式来源: BF 源码 src/main/config/simplified_tuning.c
@interface BFSliderMapper : NSObject

/// 从三轴推荐 PID 真值反算 Slider 倍率（master=100 固定）
/// @param rollPID    Roll 轴推荐 PID
/// @param pitchPID   Pitch 轴推荐 PID
/// @param yawPID     Yaw 轴推荐 PID（D 恒为 0，不参与 dGain 计算）
/// @param versionCode 固件版本代码 (403=BF4.3, 405=BF4.5, 202512=BF2025.12)
+ (nullable BFSliderValues *)mapFromRollPID:(PIDValues *)rollPID
                                   pitchPID:(PIDValues *)pitchPID
                                     yawPID:(PIDValues *)yawPID
                            firmwareVersion:(NSInteger)versionCode;

/// 正映射: Slider → Roll PID 真值
+ (PIDValues *)forwardMapRoll:(BFSliderValues *)sliders
              firmwareVersion:(NSInteger)versionCode;

/// 正映射: Slider → Pitch PID 真值
+ (PIDValues *)forwardMapPitch:(BFSliderValues *)sliders
               firmwareVersion:(NSInteger)versionCode;

/// 正映射: Slider → Yaw PID 真值
+ (PIDValues *)forwardMapYaw:(BFSliderValues *)sliders
             firmwareVersion:(NSInteger)versionCode;

/// 验证 Slider 值是否在安全范围 [0, 200]
+ (BOOL)validateSliderValues:(BFSliderValues *)values;

/// 验证反算精度: 正算 PID 与目标 PID 误差是否在 ±tolerance 以内
+ (BOOL)verifyReverseMapping:(BFSliderValues *)sliders
                expectedRollPID:(PIDValues *)rollPID
               expectedPitchPID:(PIDValues *)pitchPID
                 expectedYawPID:(PIDValues *)yawPID
              firmwareVersion:(NSInteger)versionCode
                   tolerance:(double)tolerance;

/// 生成 Slider CLI 命令文本
+ (NSString *)generateSliderCLI:(BFSliderValues *)sliders
                firmwareVersion:(NSInteger)versionCode;

@end

NS_ASSUME_NONNULL_END
