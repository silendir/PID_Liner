//
//  PIDCLIGenerator.m
//  PID_Liner
//
//  第5层：CLI 命令生成
//

#import "PIDCLIGenerator.h"

/// PID参数安全范围
static const double kPIDMaxValue = 200.0;
static const double kPIDMinValue = 0.0;
static const double kMaxChangeRatio = 0.30;  // 单次最大变更30%

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
    [output appendFormat:@"# 固件版本代码: %ld\n\n", (long)versionCode];

    // BF CLI 参数命名 (4.0+): {term}_{axis} 格式
    // D-term: BF 4.3-4.5 → d_min_roll=基础D, d_roll=峰值D
    //         BF 2025+   → d_roll=基础D, d_max_roll=峰值D
    // 参考: memory/bf-cli-params.md
    BOOL useNewNaming = (versionCode >= 202500);

    // 低于 4.3 的版本不支持自动调参 (无完整PID参数)
    if (versionCode > 0 && versionCode < 403) {
        [output appendString:@"# ⚠️ 固件版本低于 4.3，不建议自动调参\n"];
        return [output copy];
    }

    // Roll 轴
    if (rollResult && rollResult.recommendedPID) {
        [output appendString:@"# Roll 轴\n"];
        [self appendCommandsForAxis:@"roll"
                             result:rollResult
                              output:output
                        useNewNaming:useNewNaming];
    }

    // Pitch 轴
    if (pitchResult && pitchResult.recommendedPID) {
        [output appendString:@"\n# Pitch 轴\n"];
        [self appendCommandsForAxis:@"pitch"
                             result:pitchResult
                              output:output
                        useNewNaming:useNewNaming];
    }

    // Yaw 轴
    if (yawResult && yawResult.recommendedPID) {
        [output appendString:@"\n# Yaw 轴\n"];
        [self appendCommandsForAxis:@"yaw"
                             result:yawResult
                              output:output
                        useNewNaming:useNewNaming];
    }

    // 保存命令
    [output appendString:@"\nsave\n"];

    NSLog(@"📋 [CLI生成] 命令长度=%lu字符", (unsigned long)output.length);

    return [output copy];
}

+ (BOOL)validateChanges:(PIDValues *)oldValues
                 newValues:(PIDValues *)newValues {
    if (!oldValues || !newValues) return YES;

    // 检查单次变更比例
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

    // 检查范围
    if (newValues.p < kPIDMinValue || newValues.p > kPIDMaxValue ||
        newValues.i < kPIDMinValue || newValues.i > kPIDMaxValue ||
        newValues.d < kPIDMinValue || newValues.d > kPIDMaxValue ||
        newValues.ff < kPIDMinValue || newValues.ff > kPIDMaxValue) {
        NSLog(@"⚠️ [CLI安全] 参数超出安全范围 [0, %.0f]", kPIDMaxValue);
        return NO;
    }

    return YES;
}

#pragma mark - 私有方法

/// 为单轴生成CLI命令
+ (void)appendCommandsForAxis:(NSString *)axis
                       result:(PIDTuningResult *)result
                        output:(NSMutableString *)output
                  useNewNaming:(BOOL)useNewNaming {
    PIDValues *rec = result.recommendedPID;
    PIDValues *orig = result.originalPID;

    // 生成推理注释
    if (result.reasoning.length > 0) {
        [output appendFormat:@"# %@\n", result.reasoning];
    }

    // P — 格式: {term}_{axis} → p_roll
    if (orig.p > 0 && fabs(rec.p - orig.p) > 0.5) {
        [output appendFormat:@"set p_%@ = %d\n", axis, (int)round(rec.p)];
    }

    // I — 格式: i_roll
    if (orig.i > 0 && fabs(rec.i - orig.i) > 0.5) {
        [output appendFormat:@"set i_%@ = %d\n", axis, (int)round(rec.i)];
    }

    // D (命名取决于固件版本)
    if (orig.d > 0 && fabs(rec.d - orig.d) > 0.5) {
        if (useNewNaming) {
            // BF 2025+: d_roll = 基础D
            [output appendFormat:@"set d_%@ = %d\n", axis, (int)round(rec.d)];
        } else {
            // BF 4.3-4.5: d_min_roll = 基础D (d_roll 是峰值D)
            [output appendFormat:@"set d_min_%@ = %d\n", axis, (int)round(rec.d)];
        }
    }

    // FF — 格式: f_roll
    if (orig.ff > 0 && fabs(rec.ff - orig.ff) > 0.5) {
        [output appendFormat:@"set f_%@ = %d\n", axis, (int)round(rec.ff)];
    }
}

/// 从版本代码获取固件名称
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
