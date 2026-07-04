//
//  BFSliderMapper.m
//  PID_Liner
//
//  BF Simplified Tuning (Slider) 正/反向映射实现
//  公式来源: BF 源码 src/main/config/simplified_tuning.c
//

#import "BFSliderMapper.h"

#pragma mark - 常量

/// Slider 值域
static const NSInteger kSliderMin = 0;
static const NSInteger kSliderMax = 200;
static const NSInteger kSliderDefault = 100;  // 1.0x

/// 推荐范围（非Expert模式 UI 限制）
static const NSInteger kSliderRecommendedMin = 70;   // 0.7x
static const NSInteger kSliderRecommendedMax = 140;  // 1.4x

/// BF 2025+ PID 默认值（pid.h）
static const double kDefaultP_Roll  = 45.0;
static const double kDefaultI_Roll  = 80.0;
static const double kDefaultD_Roll_2025 = 30.0;   // BF 2025+
static const double kDefaultD_Roll_43  = 40.0;    // BF 4.3-4.5
static const double kDefaultFF_Roll = 120.0;

static const double kDefaultP_Pitch   = 47.0;
static const double kDefaultI_Pitch   = 84.0;
static const double kDefaultD_Pitch_2025 = 34.0;
static const double kDefaultD_Pitch_43  = 46.0;
static const double kDefaultFF_Pitch  = 125.0;

static const double kDefaultP_Yaw  = 45.0;
static const double kDefaultI_Yaw  = 80.0;
static const double kDefaultFF_Yaw = 120.0;

/// DMax 默认值（仅 BF 2025+，未来 DMax 反算时使用）
__unused static const double kDefaultDMax_Roll  = 40.0;
__unused static const double kDefaultDMax_Pitch = 46.0;

#pragma mark - BFSliderValues

@implementation BFSliderValues

- (instancetype)init {
    self = [super init];
    if (self) {
        _piGain = kSliderDefault;
        _iGain = kSliderDefault;
        _dGain = kSliderDefault;
        _ffGain = kSliderDefault;
        _dMaxGain = kSliderDefault;
        _pitchPiGain = kSliderDefault;
        _rollPitchRatio = kSliderDefault;
    }
    return self;
}

@end

#pragma mark - BFSliderMapper

@implementation BFSliderMapper

#pragma mark - 默认值查询

/// 根据 firmware version 获取 D 默认值
+ (double)dDefaultForRoll:(NSInteger)versionCode {
    return (versionCode >= 202500) ? kDefaultD_Roll_2025 : kDefaultD_Roll_43;
}

+ (double)dDefaultForPitch:(NSInteger)versionCode {
    return (versionCode >= 202500) ? kDefaultD_Pitch_2025 : kDefaultD_Pitch_43;
}

#pragma mark - 反向映射 (PID → Slider)

+ (nullable BFSliderValues *)mapFromRollPID:(PIDValues *)rollPID
                                   pitchPID:(PIDValues *)pitchPID
                                     yawPID:(PIDValues *)yawPID
                            firmwareVersion:(NSInteger)versionCode {
    if (!rollPID || !pitchPID || !yawPID) return nil;

    BFSliderValues *s = [[BFSliderValues alloc] init];

    // 🔑 从 Roll P 反算 pi_gain
    // P_roll = 45 × (pi_gain/100)
    if (rollPID.p > 0) {
        s.piGain = [self clampSlider:round(rollPID.p / kDefaultP_Roll * 100.0)];
    }

    // 🔑 从 Roll I 反算 i_gain
    // I_roll = 80 × (pi_gain/100) × (i_gain/100)
    if (rollPID.i > 0 && s.piGain > 0) {
        double effectivePi = s.piGain / 100.0;
        s.iGain = [self clampSlider:round(rollPID.i / (kDefaultI_Roll * effectivePi) * 100.0)];
    }

    // 🔑 从 Roll D 反算 d_gain
    // D_roll = D_default × (d_gain/100)
    double dDefaultRoll = [self dDefaultForRoll:versionCode];
    if (rollPID.d > 0 && dDefaultRoll > 0) {
        s.dGain = [self clampSlider:round(rollPID.d / dDefaultRoll * 100.0)];
    }

    // 🔑 从 Roll FF 反算 ff_gain
    // FF_roll = 120 × (ff_gain/100)
    if (rollPID.ff > 0) {
        s.ffGain = [self clampSlider:round(rollPID.ff / kDefaultFF_Roll * 100.0)];
    }

    // 🔑 从 Pitch P 反算 pitch_pi_gain
    // P_pitch = 47 × (pi_gain/100) × (pitch_pi_gain/100)
    if (pitchPID.p > 0 && s.piGain > 0) {
        double effectivePi = s.piGain / 100.0;
        s.pitchPiGain = [self clampSlider:round(pitchPID.p / (kDefaultP_Pitch * effectivePi) * 100.0)];
    }

    // 🔑 从 Pitch D 反算 roll_pitch_ratio
    // D_pitch = D_default_pitch × (d_gain/100) × (roll_pitch_ratio/100)
    double dDefaultPitch = [self dDefaultForPitch:versionCode];
    if (pitchPID.d > 0 && s.dGain > 0 && dDefaultPitch > 0) {
        double effectiveD = s.dGain / 100.0;
        s.rollPitchRatio = [self clampSlider:round(pitchPID.d / (dDefaultPitch * effectiveD) * 100.0)];
    }

    // 🔑 DMax（仅 BF 2025+，暂固定为默认值 100）
    // DMax 计算涉及非线性混合公式，简单场景下固定为 100
    s.dMaxGain = kSliderDefault;

    return s;
}

#pragma mark - 正映射 (Slider → PID)

+ (PIDValues *)forwardMapRoll:(BFSliderValues *)sliders
              firmwareVersion:(NSInteger)versionCode {
    PIDValues *v = [[PIDValues alloc] init];
    double pi = sliders.piGain / 100.0;
    double i  = sliders.iGain / 100.0;
    double d  = sliders.dGain / 100.0;
    double ff = sliders.ffGain / 100.0;

    v.p  = round(kDefaultP_Roll * pi);
    v.i  = round(kDefaultI_Roll * pi * i);
    v.d  = round([self dDefaultForRoll:versionCode] * d);
    v.ff = round(kDefaultFF_Roll * ff);

    return v;
}

+ (PIDValues *)forwardMapPitch:(BFSliderValues *)sliders
               firmwareVersion:(NSInteger)versionCode {
    PIDValues *v = [[PIDValues alloc] init];
    double pi  = sliders.piGain / 100.0;
    double i   = sliders.iGain / 100.0;
    double d   = sliders.dGain / 100.0;
    double ff  = sliders.ffGain / 100.0;
    double ppi = sliders.pitchPiGain / 100.0;
    double rpr = sliders.rollPitchRatio / 100.0;

    v.p  = round(kDefaultP_Pitch * pi * ppi);
    v.i  = round(kDefaultI_Pitch * pi * i * ppi);
    v.d  = round([self dDefaultForPitch:versionCode] * d * rpr);
    v.ff = round(kDefaultFF_Pitch * ppi * ff);

    return v;
}

+ (PIDValues *)forwardMapYaw:(BFSliderValues *)sliders
             firmwareVersion:(NSInteger)versionCode {
    PIDValues *v = [[PIDValues alloc] init];
    double pi = sliders.piGain / 100.0;
    double i  = sliders.iGain / 100.0;
    double ff = sliders.ffGain / 100.0;

    v.p  = round(kDefaultP_Yaw * pi);
    v.i  = round(kDefaultI_Yaw * pi * i);
    v.d  = 0;  // Yaw D 恒为 0
    v.ff = round(kDefaultFF_Yaw * ff);

    return v;
}

#pragma mark - 验证

+ (BOOL)validateSliderValues:(BFSliderValues *)values {
    if (!values) return NO;

    NSInteger vals[] = {
        values.piGain, values.iGain, values.dGain,
        values.ffGain, values.dMaxGain,
        values.pitchPiGain, values.rollPitchRatio
    };

    for (int i = 0; i < 7; i++) {
        if (vals[i] < kSliderMin || vals[i] > kSliderMax) {
            NSLog(@"⚠️ [Slider验证] 值 %ld 超出硬限制 [%ld, %ld]", (long)vals[i], (long)kSliderMin, (long)kSliderMax);
            return NO;
        }
    }

    // 推荐范围警告（不拒绝）
    for (int i = 0; i < 7; i++) {
        if (vals[i] < kSliderRecommendedMin || vals[i] > kSliderRecommendedMax) {
            NSLog(@"⚠️ [Slider建议] 值 %ld 超出推荐范围 [%ld, %ld]", (long)vals[i], (long)kSliderRecommendedMin, (long)kSliderRecommendedMax);
        }
    }

    return YES;
}

+ (BOOL)verifyReverseMapping:(BFSliderValues *)sliders
                expectedRollPID:(PIDValues *)rollPID
               expectedPitchPID:(PIDValues *)pitchPID
                 expectedYawPID:(PIDValues *)yawPID
              firmwareVersion:(NSInteger)versionCode
                   tolerance:(double)tolerance {
    PIDValues *fwdRoll  = [self forwardMapRoll:sliders firmwareVersion:versionCode];
    PIDValues *fwdPitch = [self forwardMapPitch:sliders firmwareVersion:versionCode];
    PIDValues *fwdYaw   = [self forwardMapYaw:sliders firmwareVersion:versionCode];

    BOOL rollOK  = [self pidValue:fwdRoll.p  matchesExpected:rollPID.p  tolerance:tolerance]
                && [self pidValue:fwdRoll.i  matchesExpected:rollPID.i  tolerance:tolerance]
                && [self pidValue:fwdRoll.d  matchesExpected:rollPID.d  tolerance:tolerance]
                && [self pidValue:fwdRoll.ff matchesExpected:rollPID.ff tolerance:tolerance];

    BOOL pitchOK = [self pidValue:fwdPitch.p  matchesExpected:pitchPID.p  tolerance:tolerance]
                && [self pidValue:fwdPitch.i  matchesExpected:pitchPID.i  tolerance:tolerance]
                && [self pidValue:fwdPitch.d  matchesExpected:pitchPID.d  tolerance:tolerance]
                && [self pidValue:fwdPitch.ff matchesExpected:pitchPID.ff tolerance:tolerance];

    BOOL yawOK   = [self pidValue:fwdYaw.p  matchesExpected:yawPID.p  tolerance:tolerance]
                && [self pidValue:fwdYaw.i  matchesExpected:yawPID.i  tolerance:tolerance]
                && [self pidValue:fwdYaw.d  matchesExpected:yawPID.d  tolerance:tolerance]
                && [self pidValue:fwdYaw.ff matchesExpected:yawPID.ff tolerance:tolerance];

    if (!(rollOK && pitchOK && yawOK)) {
        NSLog(@"⚠️ [Slider验证] 反算精度不足:");
        if (!rollOK)  NSLog(@"   Roll: 期望 P=%.0f I=%.0f D=%.0f FF=%.0f, 实际 P=%.0f I=%.0f D=%.0f FF=%.0f",
                            rollPID.p, rollPID.i, rollPID.d, rollPID.ff,
                            fwdRoll.p, fwdRoll.i, fwdRoll.d, fwdRoll.ff);
        if (!pitchOK) NSLog(@"   Pitch: 期望 P=%.0f I=%.0f D=%.0f FF=%.0f, 实际 P=%.0f I=%.0f D=%.0f FF=%.0f",
                            pitchPID.p, pitchPID.i, pitchPID.d, pitchPID.ff,
                            fwdPitch.p, fwdPitch.i, fwdPitch.d, fwdPitch.ff);
        if (!yawOK)   NSLog(@"   Yaw: 期望 P=%.0f I=%.0f D=%.0f FF=%.0f, 实际 P=%.0f I=%.0f D=%.0f FF=%.0f",
                            yawPID.p, yawPID.i, yawPID.d, yawPID.ff,
                            fwdYaw.p, fwdYaw.i, fwdYaw.d, fwdYaw.ff);
    }

    return rollOK && pitchOK && yawOK;
}

#pragma mark - CLI 文本生成

+ (NSString *)generateSliderCLI:(BFSliderValues *)sliders
                firmwareVersion:(NSInteger)versionCode {
    NSMutableString *output = [NSMutableString string];

    [output appendString:@"set simplified_pids_mode = RPY\n"];
    [output appendFormat:@"set simplified_master_multiplier = %ld\n", (long)kSliderDefault];
    [output appendFormat:@"set simplified_pi_gain = %ld\n", (long)sliders.piGain];
    [output appendFormat:@"set simplified_i_gain = %ld\n", (long)sliders.iGain];
    [output appendFormat:@"set simplified_d_gain = %ld\n", (long)sliders.dGain];
    [output appendFormat:@"set simplified_feedforward_gain = %ld\n", (long)sliders.ffGain];

    // DMax 仅 BF 2025+
    if (versionCode >= 202500) {
        [output appendFormat:@"set simplified_d_max_gain = %ld\n", (long)sliders.dMaxGain];
    }

    [output appendFormat:@"set simplified_pitch_d_gain = %ld\n", (long)sliders.rollPitchRatio];
    [output appendFormat:@"set simplified_pitch_pi_gain = %ld\n", (long)sliders.pitchPiGain];

    return [output copy];
}

#pragma mark - 私有方法

/// Slider 值钳位到 [0, 200]
+ (NSInteger)clampSlider:(double)value {
    return (NSInteger)MAX(kSliderMin, MIN(kSliderMax, round(value)));
}

/// 单项 PID 值误差检查
+ (BOOL)pidValue:(double)actual matchesExpected:(double)expected tolerance:(double)tolerance {
    if (expected <= 0 && actual <= 0) return YES;
    if (expected <= 0 || actual <= 0) return NO;
    return fabs(actual - expected) <= tolerance;
}

@end
