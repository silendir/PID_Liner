//
//  NoiseDiagnosisEngine.m
//  PID_Liner
//
//  噪声频带诊断引擎实现(频带诊断v1) —— 判据来自六轮实测方法论
//

#import "NoiseDiagnosisEngine.h"

// 判据阈值 v1(单案例初值,多机型样本后校准)
static const double kLesionBandPct   = 15.0;   // TPA 病灶线: 高油门 30~150Hz 能量占比 %
static const double kMechBandPct     = 30.0;   // 机械嫌疑线: 150~300Hz 占比 %
static const double kJumpThreshold   = 120.0;  // 油门突变阈值(100ms 内 PWM 变化量)

@implementation NoiseDiagnosisResult
@end

@implementation NoiseDiagnosisEngine

+ (NoiseDiagnosisResult *)diagnoseWithSpectrum:(PIDSpectrumResult *)spectrum
                             throttlePerWindow:(NSArray<NSNumber *> *)throttlePerWindow
                                   throttleSeq:(NSArray<NSNumber *> *)throttleSeq
                                         bpPWM:(double)bpPWM {
    NoiseDiagnosisResult *r = [[NoiseDiagnosisResult alloc] init];
    r.bpPWM = bpPWM;

    if (!spectrum.spectrum.count || throttlePerWindow.count != spectrum.spectrum.count) {
        r.tpaVerdict = @"数据不足,无法诊断";
        r.agVerdict = @"数据不足,无法诊断";
        r.mechVerdict = @"数据不足";
        r.adviceLines = @[@"频谱或油门数据缺失,请重新分析"];
        return r;
    }

    NSArray<NSNumber *> *freqs = spectrum.frequencies;
    NSUInteger nFreq = freqs.count;

    // ---- 每窗口频带分解 → 按油门分桶累加(能量=幅度²) ----
    double loBands[4] = {0}, hiBands[4] = {0};   // [<30, 30-150, 150-300, 300+]
    NSInteger hiWindows = 0;
    NSUInteger nW = spectrum.spectrum.count;
    for (NSUInteger w = 0; w < nW; w++) {
        double thr = throttlePerWindow[w].doubleValue;
        BOOL hi = (thr >= bpPWM);
        if (hi) hiWindows++;
        NSArray<NSNumber *> *row = spectrum.spectrum[w];
        for (NSUInteger k = 0; k < nFreq && k < row.count; k++) {
            double hz = freqs[k].doubleValue;
            if (hz < 0) continue;
            double v = row[k].doubleValue;
            double pw = v * v;
            int band = (hz < 30) ? 0 : (hz < 150) ? 1 : (hz < 300) ? 2 : 3;
            if (hi) hiBands[band] += pw; else loBands[band] += pw;
        }
    }

    double loTotal = loBands[0] + loBands[1] + loBands[2] + loBands[3];
    double hiTotal = hiBands[0] + hiBands[1] + hiBands[2] + hiBands[3];
    r.loPidBandPct  = loTotal > 0 ? loBands[1] / loTotal * 100.0 : 0;
    r.hiPidBandPct  = hiTotal > 0 ? hiBands[1] / hiTotal * 100.0 : 0;
    r.loMechBandPct = loTotal > 0 ? loBands[2] / loTotal * 100.0 : 0;
    r.hiMechBandPct = hiTotal > 0 ? hiBands[2] / hiTotal * 100.0 : 0;

    r.totalWindows = (NSInteger)nW;
    r.hiThrottleWindows = hiWindows;

    // ---- 帧级: 油门突变计数(AG 前置条件) ----
    r.totalFrames = (NSInteger)throttleSeq.count;
    r.jumpFrames = [self jumpFramesWithThrottleSeq:throttleSeq jumpThreshold:kJumpThreshold];

    // ---- TPA 判读(组件① 频带定性) ----
    if (hiWindows < 10) {
        r.tpaVerdict = @"高油门窗口不足(<10),TPA 无法诊断";
    } else if (r.hiPidBandPct > kLesionBandPct) {
        r.tpaVerdict = [NSString stringWithFormat:@"⚠️ TPA 不足: 高油门 PID 频段能量 %.1f%% 超病灶线 %.0f%%,建议升 rate 或降 breakpoint",
                        r.hiPidBandPct, kLesionBandPct];
    } else {
        r.tpaVerdict = [NSString stringWithFormat:@"✅ TPA 保持现状: 高油门 PID 频段能量 %.1f%%,无高频振荡病灶", r.hiPidBandPct];
    }

    // ---- 机械判读 ----
    if (r.hiMechBandPct > kMechBandPct) {
        r.mechVerdict = [NSString stringWithFormat:@"⚠️ 150~300Hz 能量 %.1f%% 偏高: 疑机架共振/桨问题,调 TPA 无用,先查硬件", r.hiMechBandPct];
    } else {
        r.mechVerdict = [NSString stringWithFormat:@"✅ 机械频段干净(高油门 150~300Hz 仅 %.1f%%)", r.hiMechBandPct];
    }

    // ---- AG 判读(组件③ 场景计数) ----
    if (r.jumpFrames >= 5) {
        // v1: 场景已覆盖,下垂量化判据(需响应尾巴分析)留待 v2,先给场景确认
        r.agVerdict = [NSString stringWithFormat:@"AG 场景已覆盖(突变帧 %ld),下垂量化判据待 v2——当前可结合目视 punch 试验判断", (long)r.jumpFrames];
    } else {
        r.agVerdict = [NSString stringWithFormat:@"⚠️ AG 数据盲区: 油门突变帧仅 %ld(需≥5),请补飞科目: 悬停中猛推油→急收油 ×5", (long)r.jumpFrames];
    }

    // ---- 建议行(诊断卡) ----
    NSMutableArray<NSString *> *advice = [NSMutableArray array];
    [advice addObject:r.tpaVerdict];
    [advice addObject:r.mechVerdict];
    [advice addObject:r.agVerdict];
    [advice addObject:[NSString stringWithFormat:@"数据覆盖: 总窗口 %ld | 高油门窗口 %ld | 油门突变帧 %ld/%ld | 阈值为 v1 初值待多机型校准",
                       (long)r.totalWindows, (long)r.hiThrottleWindows, (long)r.jumpFrames, (long)r.totalFrames]];
    r.adviceLines = [advice copy];

    NSLog(@"📊 [频带诊断] 低油门PID带 %.1f%% / 高油门PID带 %.1f%% | 机械 高%.1f%% 低%.1f%% | 突变帧 %ld",
          r.loPidBandPct, r.hiPidBandPct, r.hiMechBandPct, r.loMechBandPct, r.jumpFrames);

    return r;
}

+ (NSInteger)jumpFramesWithThrottleSeq:(NSArray<NSNumber *> *)throttleSeq
                        jumpThreshold:(double)jumpThreshold {
    if (throttleSeq.count < 6) return 0;
    NSInteger count = 0;
    BOOL inJump = NO;   // 连续突变帧只计一次(同一动作)
    for (NSUInteger i = 5; i < throttleSeq.count; i++) {
        double d = fabs(throttleSeq[i].doubleValue - throttleSeq[i - 5].doubleValue);
        if (d > jumpThreshold) {
            if (!inJump) { count++; inJump = YES; }
        } else {
            inJump = NO;
        }
    }
    return count;
}

@end
