//
//  PIDCLIGenerator.m
//  PID_Liner
//
//  第5层：CLI 命令生成（BF Slider 倍率输出）
//

#import "PIDCLIGenerator.h"
#import "BFSliderMapper.h"

/// 单次最大变更比例（降级路径用）
static const double kMaxChangeRatio = 0.30;

@implementation PIDCLIGenerator

+ (NSString *)generateCLICommands:(nullable PIDTuningResult *)rollResult
                      pitchResult:(nullable PIDTuningResult *)pitchResult
                        yawResult:(nullable PIDTuningResult *)yawResult
                       currentPID:(nullable NSDictionary *)currentPID
                   firmwareVersion:(NSInteger)versionCode {

    NSMutableString *output = [NSMutableString string];

    // 头部注释
    NSString *fwName = [self firmwareNameForVersion:versionCode];
    [output appendFormat:@"# PID_Liner 推荐调整 (%@)\n", fwName];
    [output appendFormat:@"# 固件版本代码: %ld\n", (long)versionCode];

    // BF CLI 参数命名 (4.0+): {term}_{axis} 格式
    BOOL useNewNaming = (versionCode >= 202500);

    // 低于 4.3 的版本不支持自动调参
    if (versionCode > 0 && versionCode < 403) {
        [output appendString:@"# ⚠️ 固件版本低于 4.3，不建议自动调参\n"];
        return [output copy];
    }

    // 提取三轴推荐 PID
    PIDValues *rollPID  = rollResult.recommendedPID;
    PIDValues *pitchPID = pitchResult.recommendedPID;
    PIDValues *yawPID   = yawResult.recommendedPID;

    if (!rollPID && !pitchPID && !yawPID) {
        [output appendString:@"# 无推荐参数\n"];
        return [output copy];
    }

    // ── 尝试 Slider 模式输出 ──
    if (rollPID && pitchPID && yawPID) {
        NSString *sliderOutput = [self generateSliderOutput:rollResult
                                                pitchResult:pitchResult
                                                  yawResult:yawResult
                                               firmwareVersion:versionCode
                                                 useNewNaming:useNewNaming];
        if (sliderOutput) {
            [output appendString:sliderOutput];
            return [output copy];
        }
    }

    // ── 降级: 直接 PID 值输出（某轴缺失或 Slider 反算失败） ──
    [output appendString:@"# ⚠️ Slider 反算不可用，使用直接 PID 值\n"];
    [output appendString:@"# 建议先执行: set simplified_pids_mode = OFF\n\n"];

    if (rollResult && rollResult.recommendedPID) {
        [output appendString:@"# Roll 轴\n"];
        [self appendLegacyCommandsForAxis:@"roll" result:rollResult output:output useNewNaming:useNewNaming];
    }
    if (pitchResult && pitchResult.recommendedPID) {
        [output appendString:@"\n# Pitch 轴\n"];
        [self appendLegacyCommandsForAxis:@"pitch" result:pitchResult output:output useNewNaming:useNewNaming];
    }
    if (yawResult && yawResult.recommendedPID) {
        [output appendString:@"\n# Yaw 轴\n"];
        [self appendLegacyCommandsForAxis:@"yaw" result:yawResult output:output useNewNaming:useNewNaming];
    }

    [output appendString:@"\nsave\n"];
    return [output copy];
}

+ (BOOL)validateChanges:(PIDValues *)oldValues
                 newValues:(PIDValues *)newValues {
    if (!oldValues || !newValues) return YES;

    double changes[] = {
        oldValues.p > 0 ? fabs(newValues.p - oldValues.p) / oldValues.p : 0,
        oldValues.i > 0 ? fabs(newValues.i - oldValues.i) / oldValues.i : 0,
        oldValues.d > 0 ? fabs(newValues.d - oldValues.d) / oldValues.d : 0,
        oldValues.ff > 0 ? fabs(newValues.ff - oldValues.ff) / oldValues.ff : 0
    };

    for (int i = 0; i < 4; i++) {
        if (changes[i] > kMaxChangeRatio) {
            NSLog(@"⚠️ [CLI安全] 参数变更%.0f%%超过%.0f%%限制",
                  changes[i] * 100, kMaxChangeRatio * 100);
            return NO;
        }
    }

    return YES;
}

#pragma mark - Slider 输出

/// 尝试生成 Slider 格式输出，失败返回 nil
+ (nullable NSString *)generateSliderOutput:(PIDTuningResult *)rollResult
                               pitchResult:(PIDTuningResult *)pitchResult
                                 yawResult:(PIDTuningResult *)yawResult
                            firmwareVersion:(NSInteger)versionCode
                              useNewNaming:(BOOL)useNewNaming {
    PIDValues *rollPID  = rollResult.recommendedPID;
    PIDValues *pitchPID = pitchResult.recommendedPID;
    PIDValues *yawPID   = yawResult.recommendedPID;

    // 反算 Slider
    BFSliderValues *sliders = [BFSliderMapper mapFromRollPID:rollPID
                                                    pitchPID:pitchPID
                                                      yawPID:yawPID
                                             firmwareVersion:versionCode];
    if (!sliders) return nil;

    // 安全验证
    if (![BFSliderMapper validateSliderValues:sliders]) {
        NSLog(@"⚠️ [CLI] Slider 值超出安全范围，降级");
        return nil;
    }

    // 精度验证（±2 tolerance，因为 round 后可能有累积误差）
    if (![BFSliderMapper verifyReverseMapping:sliders
                               expectedRollPID:rollPID
                              expectedPitchPID:pitchPID
                                expectedYawPID:yawPID
                             firmwareVersion:versionCode
                                  tolerance:2.0]) {
        NSLog(@"⚠️ [CLI] Slider 反算精度不足，降级");
        return nil;
    }

    NSMutableString *output = [NSMutableString string];

    // 注释: PID 真值参考
    PIDValues *fwdRoll  = [BFSliderMapper forwardMapRoll:sliders firmwareVersion:versionCode];
    PIDValues *fwdPitch = [BFSliderMapper forwardMapPitch:sliders firmwareVersion:versionCode];
    PIDValues *fwdYaw   = [BFSliderMapper forwardMapYaw:sliders firmwareVersion:versionCode];

    [output appendFormat:@"\n# PID真值(参考): Roll P=%d I=%d D=%d FF=%d | Pitch P=%d I=%d D=%d FF=%d | Yaw P=%d I=%d D=%d FF=%d\n",
        (int)fwdRoll.p, (int)fwdRoll.i, (int)fwdRoll.d, (int)fwdRoll.ff,
        (int)fwdPitch.p, (int)fwdPitch.i, (int)fwdPitch.d, (int)fwdPitch.ff,
        (int)fwdYaw.p, (int)fwdYaw.i, (int)fwdYaw.d, (int)fwdYaw.ff];

    // 推理注释
    if (rollResult.reasoning.length > 0) {
        [output appendFormat:@"# Roll: %@\n", rollResult.reasoning];
    }
    if (pitchResult.reasoning.length > 0) {
        [output appendFormat:@"# Pitch: %@\n", pitchResult.reasoning];
    }
    if (yawResult.reasoning.length > 0) {
        [output appendFormat:@"# Yaw: %@\n", yawResult.reasoning];
    }

    [output appendString:@"\n"];

    // Slider CLI 命令
    [output appendString:[BFSliderMapper generateSliderCLI:sliders firmwareVersion:versionCode]];
    [output appendString:@"\nsave\n"];

    NSLog(@"📋 [CLI生成] Slider模式: pi=%ld i=%ld d=%ld ff=%ld ppi=%ld rpr=%ld",
          (long)sliders.piGain, (long)sliders.iGain, (long)sliders.dGain,
          (long)sliders.ffGain, (long)sliders.pitchPiGain, (long)sliders.rollPitchRatio);

    return [output copy];
}

#pragma mark - 降级路径 (直接 PID 值)

+ (void)appendLegacyCommandsForAxis:(NSString *)axis
                              result:(PIDTuningResult *)result
                              output:(NSMutableString *)output
                        useNewNaming:(BOOL)useNewNaming {
    PIDValues *rec = result.recommendedPID;
    PIDValues *orig = result.originalPID;

    if (result.reasoning.length > 0) {
        [output appendFormat:@"# %@\n", result.reasoning];
    }

    if (orig.p > 0 && fabs(rec.p - orig.p) > 0.5) {
        [output appendFormat:@"set p_%@ = %d\n", axis, (int)round(rec.p)];
    }
    if (orig.i > 0 && fabs(rec.i - orig.i) > 0.5) {
        [output appendFormat:@"set i_%@ = %d\n", axis, (int)round(rec.i)];
    }
    if (orig.d > 0 && fabs(rec.d - orig.d) > 0.5) {
        if (useNewNaming) {
            [output appendFormat:@"set d_%@ = %d\n", axis, (int)round(rec.d)];
        } else {
            [output appendFormat:@"set d_min_%@ = %d\n", axis, (int)round(rec.d)];
        }
    }
    if (orig.ff > 0 && fabs(rec.ff - orig.ff) > 0.5) {
        [output appendFormat:@"set f_%@ = %d\n", axis, (int)round(rec.ff)];
    }
}

#pragma mark - 工具方法

+ (NSString *)firmwareNameForVersion:(NSInteger)versionCode {
    if (versionCode >= 202500) {
        NSInteger year = versionCode / 100;
        NSInteger month = versionCode % 100;
        return [NSString stringWithFormat:@"Betaflight %ld.%02ld", (long)year, (long)month];
    } else if (versionCode > 0) {
        NSInteger major = versionCode / 100;
        NSInteger minor = versionCode % 100;
        return [NSString stringWithFormat:@"Betaflight %ld.%ld", (long)major, (long)minor];
    }
    return @"Betaflight (未知版本)";
}

@end
