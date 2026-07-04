//
//  BFPIDToSecondOrderMapper.m
//  PID_Liner
//
//  PID → 二阶系统参数的解析映射实现
//  依据: 技术验证Demo/前向模型控制理论推导.md
//

#import "BFPIDToSecondOrderMapper.h"
#import <math.h>

#pragma mark - 物理约束常量

/// 阻尼比合理范围（穿越机闭环典型 0.3~1.2，留余量）
static const double kDampingMin = 0.05;   ///< 低于此值系统几乎发散
static const double kDampingMax = 3.0;    ///< 高于此值系统过阻尼（迟钝）

/// 自然频率合理范围（穿越机 30~100Hz 对应 rad/s）
static const double kOmegaMin = 2.0 * M_PI * 5.0;     ///< 5Hz 下限
static const double kOmegaMax = 2.0 * M_PI * 200.0;   ///< 200Hz 上限

/// 积分时间常数下限（防止 τ_I 过小导致数值不稳定）
static const double kIntegralTauMin = 0.001;  ///< 1ms

/// FF 瞬态系数范围
static const double kFFScaleMin = 0.0;
static const double kFFScaleMax = 2.0;

/// PID 最小正值（防止除零）
static const double kPIDEpsilon = 1e-6;

#pragma mark - BFForwardModelParams

@implementation BFForwardModelParams
@end

#pragma mark - BFPIDToSecondOrderMapper

@implementation BFPIDToSecondOrderMapper

#pragma mark - 单步映射（核心）

+ (nullable BFForwardModelParams *)mapFromBaseParams:(BFForwardModelParams *)baseParams
                                              oldPID:(PIDValues *)oldPID
                                              newPID:(PIDValues *)newPID {
    // 🔑 输入校验（CLAUDE.md: 错误处理 + 适配所有值类型）
    if (!baseParams || !oldPID || !newPID) {
        NSLog(@"⚠️ [BFForwardModelMapper] 输入参数为 nil");
        return nil;
    }

    // 基准 PID 不能为零（否则比例无意义）
    if (oldPID.p < kPIDEpsilon) {
        NSLog(@"⚠️ [BFForwardModelMapper] oldPID.p = %.4f 过小，无法计算比例", oldPID.p);
        return nil;
    }

    // 新 PID 不能为负（物理无意义）
    if (newPID.p < 0 || newPID.i < 0 || newPID.d < 0 || newPID.ff < 0) {
        NSLog(@"⚠️ [BFForwardModelMapper] newPID 含负值 P=%.1f I=%.1f D=%.1f FF=%.1f",
              newPID.p, newPID.i, newPID.d, newPID.ff);
        return nil;
    }

    // 基准二阶参数有效性
    if (baseParams.naturalFreq < kOmegaMin || baseParams.naturalFreq > kOmegaMax) {
        NSLog(@"⚠️ [BFForwardModelMapper] 基准 ωn=%.1f 超出范围 [%.1f, %.1f]",
              baseParams.naturalFreq, kOmegaMin, kOmegaMax);
        return nil;
    }

    BFForwardModelParams *result = [[BFForwardModelParams alloc] init];

    // ===== 1. P → ωn（开方关系）=====
    // 推导 §2.4: ωn/ωn₀ = √(Kp/Kp₀)
    double pRatio = newPID.p / oldPID.p;
    double omegaRatio = [self omegaRatioFromPRatio:pRatio];
    result.naturalFreq = [self clampOmega:baseParams.naturalFreq * omegaRatio];

    // ===== 2. P,D → ζ（D 正比，P 反开方修正）=====
    // 推导 §2.4: ζ/ζ₀ ≈ (Kd/Kd₀) · √(Kp₀/Kp)
    double dampingFromP = [self dampingRatioFromPRatio:pRatio];  // 1/√(pRatio)

    double dampingFromD = 1.0;  // D 不变时的默认值
    if (oldPID.d >= kPIDEpsilon) {
        double dRatio = newPID.d / oldPID.d;
        dampingFromD = [self dampingRatioFromDRatio:dRatio];  // dRatio
    } else if (newPID.d > kPIDEpsilon) {
        // 基准无 D，新增 D：ζ 显著上升（用一个保守的初值映射）
        dampingFromD = 1.0 + (newPID.d / oldPID.p) * 0.5;
    }

    result.dampingRatio = [self clampDamping:baseParams.dampingRatio * dampingFromP * dampingFromD];

    // ===== 3. K（稳态增益）保持不变 =====
    // 推导 §三: 二阶闭环 DC 增益恒为 1，P 不改变 K
    result.gain = baseParams.gain;

    // ===== 4. I → τ_I（积分时间常数）=====
    // 推导 §四: τ_I = Kp/Ki，影响稳态收敛速度
    if (newPID.i >= kPIDEpsilon) {
        result.integralTau = fmax(newPID.p / newPID.i, kIntegralTauMin);
    } else {
        result.integralTau = 0.0;  // 无 I 作用
    }

    // ===== 5. FF → 独立前向叠加系数 =====
    // 推导 §五: FF 不进 ωn/ζ/K，作为上升阶段瞬态叠加
    double ffScale = 0.0;
    if (oldPID.ff >= kPIDEpsilon && newPID.ff >= 0) {
        ffScale = newPID.ff / oldPID.ff - 1.0;  // 相对基准的变化量
    } else if (newPID.ff > 0) {
        ffScale = newPID.ff / 120.0;  // 基准用 BF 默认 FF=120 归一化
    }
    result.feedforwardScale = fmax(kFFScaleMin, fmin(ffScale, kFFScaleMax));

    return result;
}

#pragma mark - 预测曲线生成

+ (NSArray<NSNumber *> *)predictedCurveWithParams:(BFForwardModelParams *)params
                                           length:(NSInteger)length
                                         duration:(double)duration {
    // 🔑 输入校验
    if (!params || length < 2 || duration <= 0) {
        NSLog(@"⚠️ [predictedCurve] 输入非法 length=%ld duration=%.3f", (long)length, duration);
        return @[@0.0];
    }

    NSMutableArray<NSNumber *> *curve = [NSMutableArray arrayWithCapacity:length];
    double dt = duration / (double)(length - 1);

    // 二阶主参数（带下限保护）
    double K    = (fabs(params.gain) > kPIDEpsilon) ? params.gain : 1.0;
    double wn   = fmax(params.naturalFreq, kOmegaMin);
    double zeta = fmax(fmin(params.dampingRatio, kDampingMax), kDampingMin);

    // 阻尼频率与相位
    double zetaSq = zeta * zeta;
    double wd     = wn * sqrt(fabs(1.0 - zetaSq));

    // I 稳态收敛时间常数
    double tauI = params.integralTau;
    BOOL  hasI  = (tauI > kIntegralTauMin);

    // FF 前馈瞬态窗（集中在上升阶段 t ∈ [0, 3/wn]）
    double ffScale = params.feedforwardScale;
    double ffWindow = 3.0 / wn;  // FF 影响的时间窗

    for (NSInteger i = 0; i < length; i++) {
        double t = (double)i * dt;

        // ---- 二阶阶跃主响应 ----
        double mainResponse;
        if (zeta < 1.0) {
            // 欠阻尼: h(t) = K·[1 - e^(-ζωn·t)/√(1-ζ²) · sin(ωd·t + φ)]
            double sqrtTerm = sqrt(1.0 - zetaSq);
            double phi = atan2(sqrtTerm, zeta);
            mainResponse = K * (1.0 - exp(-zeta * wn * t) / sqrtTerm * sin(wd * t + phi));
        } else if (fabs(zeta - 1.0) < 1e-6) {
            // 临界阻尼: h(t) = K·[1 - (1 + ωn·t)·e^(-ωn·t)]
            mainResponse = K * (1.0 - (1.0 + wn * t) * exp(-wn * t));
        } else {
            // 过阻尼: 两实根叠加
            double s1 = wn * (-zeta + sqrt(zetaSq - 1.0));
            double s2 = wn * (-zeta - sqrt(zetaSq - 1.0));
            mainResponse = K * (1.0 - (s1 * exp(s2 * t) - s2 * exp(s1 * t)) / (s1 - s2));
        }

        // ---- I 稳态收敛修正（叠加慢指数）----
        // 推导 §4.2: Δsteady(t) = (1 - T(∞)) · (1 - e^(-t/τ_I))
        // 此处 T(∞)≈K，建模为对稳态偏差的缓慢消除
        if (hasI) {
            double steadyError = K - mainResponse;  // 当前与稳态的差
            double correction  = steadyError * (1.0 - exp(-t / tauI)) * 0.3;  // 系数 0.3 为工程权重
            mainResponse += correction;
        }

        // ---- FF 前馈瞬态叠加 ----
        // 推导 §5.2: 上升阶段注入额外响应
        if (ffScale > kPIDEpsilon) {
            double ffShape = exp(-t / ffWindow) * (t < ffWindow);  // 衰减窗
            mainResponse += K * ffScale * 0.3 * ffShape;  // FF 对峰值贡献系数 0.3
        }

        [curve addObject:@(mainResponse)];
    }

    return [curve copy];
}

#pragma mark - 比例关系（单元测试用）

/// P 变化 → ωn 比例: √(pRatio)
+ (double)omegaRatioFromPRatio:(double)pRatio {
    if (pRatio < kPIDEpsilon) return kPIDEpsilon;
    return sqrt(pRatio);
}

/// P 变化 → ζ 比例: 1/√(pRatio)
+ (double)dampingRatioFromPRatio:(double)pRatio {
    if (pRatio < kPIDEpsilon) return 1.0 / sqrt(kPIDEpsilon);
    return 1.0 / sqrt(pRatio);
}

/// D 变化 → ζ 比例: dRatio
+ (double)dampingRatioFromDRatio:(double)dRatio {
    if (dRatio < kPIDEpsilon) return kPIDEpsilon;
    return dRatio;
}

#pragma mark - 边界保护（私有）

/// 阻尼比钳位
+ (double)clampDamping:(double)zeta {
    return fmax(kDampingMin, fmin(zeta, kDampingMax));
}

/// 自然频率钳位
+ (double)clampOmega:(double)wn {
    return fmax(kOmegaMin, fmin(wn, kOmegaMax));
}

@end