//
//  PIDRecommendationEngine.m
//  PID_Liner
//
//  第4层：诊断 → 推荐 → 预测曲线
//

#import "PIDRecommendationEngine.h"
#import "PIDTraceAnalyzer.h"
#import <math.h>

#pragma mark - PIDValues

@implementation PIDValues

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    PIDValues *v = [[PIDValues alloc] init];
    v.p = [dict[@"p"] doubleValue];
    v.i = [dict[@"i"] doubleValue];
    v.d = [dict[@"d"] doubleValue];
    v.ff = [dict[@"ff"] doubleValue];
    return v;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.p > 0) d[@"p"] = @(self.p);
    if (self.i > 0) d[@"i"] = @(self.i);
    if (self.d > 0) d[@"d"] = @(self.d);
    if (self.ff > 0) d[@"ff"] = @(self.ff);
    return [d copy];
}

@end

#pragma mark - PIDTuningResult

@implementation PIDTuningResult
@end

#pragma mark - PIDRecommendationEngine

@implementation PIDRecommendationEngine

- (PIDTuningResult *)generateRecommendationWithDiagnosis:(PIDAxisDiagnosis *)diagnosis
                                               currentPID:(PIDValues *)currentPID
                                          currentResponse:(NSArray<NSNumber *> *)currentResponse
                                              sampleRate:(double)sampleRate {
    PIDTuningResult *result = [[PIDTuningResult alloc] init];

    if (!diagnosis) return result;

    // 保存原始PID
    PIDValues *original = currentPID ?: [[PIDValues alloc] init];
    result.originalPID = original;

    // 🔧 基于诊断问题计算推荐PID
    PIDValues *recommended = [[PIDValues alloc] init];
    recommended.p = original.p > 0 ? original.p : 42.0;  // BF 默认值
    recommended.i = original.i > 0 ? original.i : 85.0;
    recommended.d = original.d > 0 ? original.d : 35.0;
    recommended.ff = original.ff > 0 ? original.ff : 65.0;

    NSMutableString *reasoning = [NSMutableString string];
    [reasoning appendFormat:@"%@轴调参建议: ", diagnosis.axisName];

    for (PIDIssue *issue in diagnosis.issues) {
        if ([issue.issueType isEqualToString:@"overshoot"]) {
            // P 过高 → 降低 P
            recommended.p *= 0.75;
            [reasoning appendFormat:@"降低P(%.0f→%.0f)消除超调; ",
             original.p > 0 ? original.p : recommended.p / 0.75, recommended.p];
        } else if ([issue.issueType isEqualToString:@"slow_response"]) {
            // 响应迟缓 → 提高 P 或 FF
            if (original.ff > 0) {
                recommended.ff *= 1.25;
                [reasoning appendFormat:@"提高FF(%.0f→%.0f)加速响应; ", original.ff, recommended.ff];
            } else {
                recommended.p *= 1.2;
                [reasoning appendFormat:@"提高P(%.0f→%.0f)加速响应; ", original.p, recommended.p];
            }
        } else if ([issue.issueType isEqualToString:@"oscillation"]) {
            // 震荡 → 提高 D
            recommended.d *= 1.15;
            [reasoning appendFormat:@"提高D(%.0f→%.0f)抑制震荡; ", original.d, recommended.d];
        } else if ([issue.issueType isEqualToString:@"low_i"]) {
            // I 不足 → 提高 I
            recommended.i *= 1.15;
            [reasoning appendFormat:@"提高I(%.0f→%.0f)改善稳态; ", original.i, recommended.i];
        }
    }

    // 安全限制：单次变更不超过 ±30%
    recommended.p = [self clampPID:recommended.p from:original.p maxChange:0.30];
    recommended.i = [self clampPID:recommended.i from:original.i maxChange:0.30];
    recommended.d = [self clampPID:recommended.d from:original.d maxChange:0.30];
    recommended.ff = [self clampPID:recommended.ff from:original.ff maxChange:0.30];

    result.recommendedPID = recommended;
    result.reasoning = [reasoning copy];

    // 🔧 用二阶系统模型生成预测曲线
    // 从当前曲线拟合二阶参数
    double gain = 0.0;    // K (稳态增益)
    double wn = 0.0;      // 自然频率
    double zeta = 0.0;    // 阻尼比

    [self fitSecondOrderFromResponse:currentResponse
                               gain:&gain
                       naturalFreq:&wn
                      dampingRatio:&zeta];

    // 根据PID变化比例修正二阶参数
    if (original.p > 0 && recommended.p != original.p) {
        gain *= (recommended.p / original.p);
    }
    if (original.d > 0 && recommended.d != original.d) {
        zeta *= sqrt(recommended.d / original.d);
        zeta = MAX(0.1, MIN(2.0, zeta));  // 阻尼比限制在合理范围
    }
    if (original.ff > 0 && recommended.ff != original.ff) {
        wn *= pow(recommended.ff / original.ff, 0.3);
        wn = MAX(10.0, wn);  // 最低自然频率
    }

    // 生成预测曲线
    NSInteger curveLen = currentResponse.count > 0 ? currentResponse.count : 4000;
    NSArray<NSNumber *> *predictedCurve = [self.class predictedCurveWithGain:gain
                                                                naturalFreq:wn
                                                               dampingRatio:zeta
                                                                     length:curveLen
                                                                  duration:0.5];
    result.predictedCurve = predictedCurve;

    // 计算预测特征
    if (predictedCurve.count > 10) {
        PIDResponseFeatures *predFeatures = [PIDTraceAnalyzer extractFeaturesFromResponse:predictedCurve
                                                                                sampleRate:sampleRate];
        result.predictedOvershoot = predFeatures.overshoot;
        result.predictedRiseTime = predFeatures.riseTime;
    }

    NSLog(@"📊 [推荐] %@: P %.0f→%.0f, I %.0f→%.0f, D %.0f→%.0f, FF %.0f→%.0f",
          diagnosis.axisName,
          original.p, recommended.p,
          original.i, recommended.i,
          original.d, recommended.d,
          original.ff, recommended.ff);
    NSLog(@"  预测: 超调=%.1f%%, 上升=%.1fms", result.predictedOvershoot * 100, result.predictedRiseTime);

    return result;
}

#pragma mark - 二阶系统模型

+ (NSArray<NSNumber *> *)predictedCurveWithGain:(double)gain
                                   naturalFreq:(double)wn
                                  dampingRatio:(double)zeta
                                        length:(NSInteger)length
                                     duration:(double)duration {
    NSMutableArray<NSNumber *> *curve = [NSMutableArray arrayWithCapacity:length];

    if (wn <= 0 || length < 2) {
        // 退化为常数
        for (NSInteger i = 0; i < length; i++) {
            [curve addObject:@(gain)];
        }
        return [curve copy];
    }

    double dt = duration / (length - 1);
    // ωd = ωn * √(1-ζ²) (阻尼自然频率)
    double wd = wn * sqrt(fabs(1.0 - zeta * zeta));

    for (NSInteger i = 0; i < length; i++) {
        double t = i * dt;

        double value;
        if (zeta < 1.0) {
            // 欠阻尼: h(t) = K * [1 - e^(-ζωn·t) * (cos(ωd·t) + ζ/√(1-ζ²) * sin(ωd·t)) / 1]
            // 简化: h(t) = K * [1 - e^(-ζωn·t) / √(1-ζ²) * sin(ωd·t + φ)]
            double expTerm = exp(-zeta * wn * t);
            double phi = atan2(sqrt(1.0 - zeta * zeta), zeta);
            double sqrtTerm = sqrt(1.0 - zeta * zeta);
            value = gain * (1.0 - expTerm / sqrtTerm * sin(wd * t + phi));
        } else if (fabs(zeta - 1.0) < 1e-6) {
            // 临界阻尼: h(t) = K * [1 - (1 + ωn·t) * e^(-ωn·t)]
            value = gain * (1.0 - (1.0 + wn * t) * exp(-wn * t));
        } else {
            // 过阻尼: h(t) = K * [1 - e^(-ζωn·t) * cosh(...) ]
            double s1 = wn * (-zeta + sqrt(zeta * zeta - 1.0));
            double s2 = wn * (-zeta - sqrt(zeta * zeta - 1.0));
            value = gain * (1.0 - (s1 * exp(s2 * t) - s2 * exp(s1 * t)) / (s1 - s2));
        }

        [curve addObject:@(value)];
    }

    return [curve copy];
}

#pragma mark - 私有方法

/// 从当前阶跃响应拟合二阶传递函数参数
- (void)fitSecondOrderFromResponse:(NSArray<NSNumber *> *)response
                              gain:(double *)outGain
                      naturalFreq:(double *)outWn
                     dampingRatio:(double *)outZeta {
    // 默认值
    *outGain = 1.0;
    *outWn = 50.0;     // ~80Hz
    *outZeta = 0.7;    // 适度阻尼

    if (!response || response.count < 50) return;

    NSInteger n = response.count;
    double dt = 0.5 / (n - 1);

    // K (增益) = 稳态值
    NSInteger tailStart = (NSInteger)(n * 0.9);
    double steadySum = 0.0;
    for (NSInteger i = tailStart; i < n; i++) {
        steadySum += [response[i] doubleValue];
    }
    double K = steadySum / (n - tailStart);
    if (fabs(K) < 1e-9) K = 1.0;
    *outGain = K;

    // ζ (阻尼比) ← 超调量: ζ ≈ -ln(OS) / √(π² + ln²(OS))
    // 找峰值
    double peakVal = 0.0;
    for (NSInteger i = 0; i < n; i++) {
        double v = [response[i] doubleValue];
        if (fabs(v) > fabs(peakVal)) peakVal = v;
    }
    double overshoot = fabs(K) > 1e-9 ? fabs(peakVal - K) / fabs(K) : 0.0;

    if (overshoot > 0.01 && overshoot < 0.99) {
        double lnOS = log(overshoot);
        *outZeta = -lnOS / sqrt(M_PI * M_PI + lnOS * lnOS);
    } else {
        *outZeta = 0.7;  // 默认
    }

    // ωn ← 上升时间: ωn ≈ 1.8 / t_rise
    double target10 = K * 0.1;
    double target90 = K * 0.9;
    NSInteger rise10Idx = -1;
    NSInteger rise90Idx = -1;
    for (NSInteger i = 0; i < n; i++) {
        double v = [response[i] doubleValue];
        if (rise10Idx < 0 && v >= target10) rise10Idx = i;
        if (rise10Idx >= 0 && v >= target90) { rise90Idx = i; break; }
    }

    if (rise10Idx >= 0 && rise90Idx > rise10Idx) {
        double riseTime = (rise90Idx - rise10Idx) * dt;
        if (riseTime > 1e-6) {
            *outWn = 1.8 / riseTime;
        }
    }
}

/// 安全限制：单次变更不超过 ±maxChange 比例
- (double)clampPID:(double)newValue from:(double)oldValue maxChange:(double)maxChange {
    if (oldValue <= 0) return newValue;  // 无原始值时不限制

    double minVal = oldValue * (1.0 - maxChange);
    double maxVal = oldValue * (1.0 + maxChange);
    return MAX(minVal, MIN(maxVal, newValue));
}

@end
