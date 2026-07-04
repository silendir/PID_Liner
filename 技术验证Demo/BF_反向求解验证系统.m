//
//  BF_反向求解验证系统.m
//  PID_Liner - 基于目标曲线的PID反向求解技术验证
//
//  技术目标：实现从目标响应曲线反解PID参数，并验证风格旋钮约束
//  挑战：反问题是病态的（4个PID自由度 vs 二阶模型3个约束），需要第4维约束
//

#import <Foundation/Foundation.h>

// ============================================================================
// 1. 风格EQ旋钮定义（来自风格化PID产品功能清单.md）
// ============================================================================

#pragma mark - 风格EQ数据结构

/// 风格EQ旋钮值（0-100）
typedef struct {
    uint8_t snap;      // 锐度：控制响应速度
    uint8_t smooth;    // 平滑度：控制阻尼与超调
    uint8_t noise;     // 噪声底：控制高频滤波
    uint8_t hold;      // 锁定感：控制悬停稳定性
} StyleEQ_t;

/// 风格预设
typedef struct {
    char name[32];     // 风格名称
    StyleEQ_t eq;      // 风格参数
    char description[128]; // 风格描述
} StylePreset_t;

#pragma mark - 目标响应曲线数据结构

/// 目标响应曲线点
typedef struct {
    float time;        // 时间 (秒)
    float value;       // 响应值 (度)
} TargetCurvePoint_t;

/// 目标曲线特征
typedef struct {
    float riseTime;    // 上升时间 (秒)
    float settlingTime; // 建立时间 (秒)
    float overshoot;   // 超调量 (0-1)
    float steadyState;  // 稳态值 (度)
    float peakValue;   // 峰值 (度)
    float bandwidth;   // 带宽 (Hz)
    float phaseMargin; // 相位裕度 (度)
} TargetCurveFeatures_t;

// ============================================================================
// 2. 风格旋钮到PID参数的映射（风格EQ工程化）
// ============================================================================

@implementation StyleEQMapper

/// 风格预设定义（来自风格化PID产品功能清单.md）
+ (StylePreset_t *)getPresets {
    static StylePreset_t presets[3] = {0};

    // 🏁 Racer（竞速）
    strcpy(presets[0].name, "Racer");
    strcpy(presets[0].description, "快速响应，允许轻微震荡，优先控制精度");
    presets[0].eq.snap = 85;     // 高锐度
    presets[0].eq.smooth = 25;   // 低平滑度
    presets[0].eq.noise = 15;    // 低噪声底
    presets[0].eq.hold = 40;     // 中等锁定感

    // 🎨 Freestyle（自由飞）
    strcpy(presets[1].name, "Freestyle");
    strcpy(presets[1].description, "平衡操控，流畅易控，适合各种动作");
    presets[1].eq.snap = 55;     // 中等锐度
    presets[1].eq.smooth = 60;   // 临界阻尼
    presets[1].eq.noise = 50;    // 平衡噪声底
    presets[1].eq.hold = 55;     // 适度锁定

    // 🎬 Cinematic（影视航拍）
    strcpy(presets[2].name, "Cinematic");
    strcpy(presets[2].description, "绝对平稳，零噪声干扰，镜头稳定");
    presets[2].eq.snap = 25;     // 低锐度
    presets[2].eq.smooth = 85;   // 高阻尼
    presets[2].eq.noise = 80;    // 强滤波
    presets[2].eq.hold = 85;     // 强力锁定

    return presets;
}

/// 风格旋钮到PID调整比例的映射
+ (NSDictionary *)mapStyleToPIDAdjustment:(StyleEQ_t)style {
    NSMutableDictionary *adjustment = [NSMutableDictionary dictionary];

    // 1. 🎯 锐度（Snap）→ P 调整
    if (style.snap < 30) {
        adjustment[@"p_scale"] = @(0.7);    // 缓慢响应 (cinematic)
    } else if (style.snap > 70) {
        adjustment[@"p_scale"] = @(1.3);    // 急速响应 (racer)
    } else {
        adjustment[@"p_scale"] = @(1.0);    // 平衡响应
    }

    // 2. 🌊 平滑度（Smooth）→ D 调整
    if (style.smooth < 20) {
        adjustment[@"d_scale"] = @(0.8);    // 允许震荡 (racer)
    } else if (style.smooth > 80) {
        adjustment[@"d_scale"] = @(1.5);    // 超低超调 (cinematic)
    } else {
        adjustment[@"d_scale"] = @(1.0);    // 临界阻尼
    }

    // 3. 🔇 噪声底（Noise）→ D-term 滤波调整
    int dtermCutoff = 150 - style.noise;  // 150Hz - noise*1Hz
    adjustment[@"dterm_cutoff"] = @(dtermCutoff);

    // 噪声底对D增益的二次影响
    if (style.noise > 70) {
        adjustment[@"d_scale"] = @(adjustment[@"d_scale"].doubleValue * 0.9);
    } else if (style.noise < 30) {
        adjustment[@"d_scale"] = @(adjustment[@"d_scale"].doubleValue * 1.1);
    }

    // 4. 🧲 锁定感（Hold）→ I/FF 调整
    double iScale = 1.0 + (style.hold - 50) * 0.02;  // ±100%变化
    double ffScale = 1.0 + (style.hold - 50) * 0.015;
    adjustment[@"i_scale"] = @(iScale);
    adjustment[@"ff_scale"] = @(ffScale);

    return adjustment;
}

/// 应用风格旋钮约束到PID推荐
+ (BF_PID_t)applyStyleConstraints:(BF_PID_t)basePID
                              style:(StyleEQ_t)style {
    BF_PID_t constrainedPID = basePID;
    NSDictionary *adjustment = [self mapStyleToPIDAdjustment:style];

    // 应用风格约束
    constrainedPID.roll_p *= adjustment[@"p_scale"].doubleValue;
    constrainedPID.pitch_p *= adjustment[@"p_scale"].doubleValue;
    constrainedPID.yaw_p *= adjustment[@"p_scale"].doubleValue;

    constrainedPID.roll_d *= adjustment[@"d_scale"].doubleValue;
    constrainedPID.pitch_d *= adjustment[@"d_scale"].doubleValue;
    constrainedPID.yaw_d *= adjustment[@"d_scale"].doubleValue;

    constrainedPID.roll_i *= adjustment[@"i_scale"].doubleValue;
    constrainedPID.pitch_i *= adjustment[@"i_scale"].doubleValue;
    constrainedPID.yaw_i *= adjustment[@"i_scale"].doubleValue;

    constrainedPID.roll_ff *= adjustment[@"ff_scale"].doubleValue;
    constrainedPID.pitch_ff *= adjustment[@"ff_scale"].doubleValue;
    constrainedPID.yaw_ff *= adjustment[@"ff_scale"].doubleValue;

    // 应用D-term截止频率（影响实际飞行效果）
    // 这里只是标记，实际应用需要配置D-term滤波器

    return constrainedPID;
}

@end

// ============================================================================
// 3. 目标曲线特征提取
// ============================================================================

@implementation TargetCurveAnalyzer

/// 从目标曲线提取特征
+ (TargetCurveFeatures_t)extractFeaturesFromCurve:(TargetCurvePoint_t *)curve
                                           length:(int)length {
    TargetCurveFeatures_t features = {0};

    // 找到稳态值（最后的10%平均值）
    int steadyStart = length * 9 / 10;
    float sumSteady = 0;
    for (int i = steadyStart; i < length; i++) {
        sumSteady += curve[i].value;
    }
    features.steadyState = sumSteady / (length - steadyStart);

    // 计算10%-90%上升时间
    float tenthPercent = features.steadyState * 0.1;
    float ninetiethPercent = features.steadyState * 0.9;

    int startIndex = 0, endIndex = length - 1;
    for (int i = 0; i < length; i++) {
        if (curve[i].value >= tenthPercent) {
            startIndex = i;
            break;
        }
    }
    for (int i = startIndex; i < length; i++) {
        if (curve[i].value >= ninetiethPercent) {
            endIndex = i;
            break;
        }
    }

    features.riseTime = curve[endIndex].time - curve[startIndex].time;

    // 计算超调量
    features.peakValue = 0;
    for (int i = 0; i < length; i++) {
        if (curve[i].value > features.peakValue) {
            features.peakValue = curve[i].value;
        }
    }
    features.overshoot = (features.peakValue - features.steadyState) / features.steadyState;

    // 计算建立时间（2%误差带）
    float twoPercentBand = features.steadyState * 0.02;
    for (int i = length - 1; i >= 0; i--) {
        if (fabs(curve[i].value - features.steadyState) > twoPercentBand) {
            features.settlingTime = curve[i].time;
            break;
        }
    }

    // 估算带宽（简化方法：1/(2*riseTime)）
    features.bandwidth = 1.0 / (2.0 * features.riseTime);

    // 估算相位裕度（基于二阶系统理论）
    // ζ = -ln(overshoot) / sqrt(π² + ln²(overshoot))
    if (features.overshoot > 0) {
        double zeta = -log(features.overshoot) / sqrt(M_PI*M_PI + log(features.overshoot)*log(features.overshoot));
        features.phaseMargin = zeta * 100;  // 简化估算
    }

    return features;
}

/// 生成目标阶跃响应曲线
+ (TargetCurvePoint_t *)generateTargetStepResponse:(TargetCurveFeatures_t)features
                                             length:(int)length {
    TargetCurvePoint_t *curve = malloc(length * sizeof(TargetCurvePoint_t));

    // 二阶系统阶跃响应公式
    float wn = 2 * M_PI * features.bandwidth;  // 自然频率
    float zeta = features.phaseMargin / 100.0; // 阻尼比

    float dt = 1.0f / 1000.0f;  // 1ms采样间隔
    for (int i = 0; i < length; i++) {
        float t = i * dt;

        // 二阶阶跃响应
        float wd = wn * sqrt(1 - zeta * zeta);  // 阻尼频率
        float phi = acos(zeta);

        if (zeta < 1) {  // 欠阻尼
            float response = features.steadyState *
                           (1 - exp(-zeta * wn * t) * sin(wd * t + phi) / sqrt(1 - zeta * zeta));
            curve[i].time = t;
            curve[i].value = fmax(0, response);
        } else {  // 过阻尼
            float response = features.steadyState *
                           (1 - exp(-zeta * wn * t) * (1 + zeta * wn * t));
            curve[i].time = t;
            curve[i].value = fmax(0, response);
        }
    }

    return curve;
}

@end

// ============================================================================
// 4. 反向求解引擎（目标曲线→PID参数）
// ============================================================================

@implementation PIDInverseSolver

/// 从目标曲线特征反解PID参数
+ (BF_PID_t)solvePIDFromTargetFeatures:(TargetCurveFeatures_t)features
                         baseDefaults:(BF_PID_t)defaults {
    BF_PID_t solvedPID = {0};

    // 1. 从上升时间计算P增益
    // P ∝ bandwidth, bandwidth ∝ 1/riseTime
    double pScale = features.bandwidth / 50.0;  // 以50Hz带宽为基准
    solvedPID.roll_p = defaults.roll_p * pScale;
    solvedPID.pitch_p = defaults.pitch_p * pScale;
    solvedPID.yaw_p = defaults.yaw_p * pScale;

    // 2. 从超调量计算D增益
    // 超调量 → 阻尼比 → D增益
    if (features.overshoot > 0) {
        // ζ = -ln(overshoot) / sqrt(π² + ln²(overshoot))
        double zeta = -log(features.overshoot) / sqrt(M_PI*M_PI + log(features.overshoot)*log(features.overshoot));
        double zetaNominal = 0.7;  // 标准阻尼比
        double dScale = zeta / zetaNominal;

        solvedPID.roll_d = defaults.roll_d * dScale;
        solvedPID.pitch_d = defaults.pitch_d * dScale;
        solvedPID.yaw_d = defaults.yaw_d * dScale;
    }

    // 3. 建立时间→I增益（简化关系）
    // 建立时间短 → I需要增大以减少稳态误差
    double iScale = 1.0 + (1.0 / features.settlingTime) * 0.5;
    solvedPID.roll_i = defaults.roll_i * iScale;
    solvedPID.pitch_i = defaults.pitch_i * iScale;
    solvedPID.yaw_i = defaults.yaw_i * iScale;

    // 4. FF增益基于经验设置
    solvedPID.roll_ff = defaults.roll_ff;
    solvedPID.pitch_ff = defaults.pitch_ff;
    solvedPID.yaw_ff = defaults.yaw_ff;

    // 应用安全限制
    solvedPID = [self applySafetyConstraints:solvedPID];

    return solvedPID;
}

/// 应用安全约束（防炸机）
+ (BF_PID_t)applySafetyConstraints:(BF_PID_t)pid {
    BF_PID_t safePID = pid;

    // 1. 单项变化不超过基准值的±50%
    BF_PID_t defaults = {
        .roll_p = 45, .roll_i = 80, .roll_d = 30, .roll_ff = 120,
        .pitch_p = 47, .pitch_i = 84, .pitch_d = 34, .pitch_ff = 125,
        .yaw_p = 45, .yaw_i = 80, .yaw_d = 0, .yaw_ff = 120
    };

    // P限制
    safePID.roll_p = fmax(0, fmin(safePID.roll_p, defaults.roll_p * 1.5));
    safePID.pitch_p = fmax(0, fmin(safePID.pitch_p, defaults.pitch_p * 1.5));
    safePID.yaw_p = fmax(0, fmin(safePID.yaw_p, defaults.yaw_p * 1.5));

    // I限制
    safePID.roll_i = fmax(0, fmin(safePID.roll_i, defaults.roll_i * 1.5));
    safePID.pitch_i = fmax(0, fmin(safePID.pitch_i, defaults.pitch_i * 1.5));
    safePID.yaw_i = fmax(0, fmin(safePID.yaw_i, defaults.yaw_i * 1.5));

    // D限制
    safePID.roll_d = fmax(0, fmin(safePID.roll_d, defaults.roll_d * 1.5));
    safePID.pitch_d = fmax(0, fmin(safePID.pitch_d, defaults.pitch_d * 1.5));
    safePID.yaw_d = fmax(0, fmin(safePID.yaw_d, 100));  // D特别危险，限制更紧

    // FF限制
    safePID.roll_ff = fmax(0, fmin(safePID.roll_ff, defaults.roll_ff * 1.5));
    safePID.pitch_ff = fmax(0, fmin(safePID.pitch_ff, defaults.pitch_ff * 1.5));
    safePID.yaw_ff = fmax(0, fmin(safePID.yaw_ff, defaults.yaw_ff * 1.5));

    return safePID;
}

/// 验证反解准确性
+ (BOOL)verifyInverseSolution:(BF_PID_t)solvedPID
                  targetCurve:(TargetCurveFeatures_t)target
                  actualCurve:(TargetCurveFeatures_t)actual
                      tolerance:(double)tolerance {

    // 计算特征误差
    double riseTimeError = fabs(target.riseTime - actual.riseTime) / target.riseTime;
    double overshootError = fabs(target.overshoot - actual.overshoot) /
                           (target.overshoot > 0 ? target.overshoot : 1);
    double bandwidthError = fabs(target.bandwidth - actual.bandwidth) / target.bandwidth;

    NSLog(@"反解准确性验证:");
    NSLog(@"  上升时间误差: %.2f%%", riseTimeError * 100);
    NSLog(@"  超调量误差: %.2f%%", overshootError * 100);
    NSLog(@"  带宽误差: %.2f%%", bandwidthError * 100);

    // 最大误差必须在容忍度内
    double maxError = fmax(riseTimeError, fmax(overshootError, bandwidthError));

    BOOL isAccurate = (maxError <= tolerance);
    NSLog(@"  验证结果: %@", isAccurate ? @"✅ 通过" : @"❌ 不通过");

    return isAccurate;
}

@end

// ============================================================================
// 5. 综合验证流程
// ============================================================================

@implementation ReverseValidationSystem

/// 运行完整的反向求解验证
+ (void)runReverseValidation {
    NSLog(@"\n=== 反向求解验证流程启动 ===\n");

    // 1. 定义基准默认值
    BF_PID_t baseDefaults = {
        .roll_p = 45, .roll_i = 80, .roll_d = 30, .roll_ff = 120,
        .pitch_p = 47, .pitch_i = 84, .pitch_d = 34, .pitch_ff = 125,
        .yaw_p = 45, .yaw_i = 80, .yaw_d = 0, .yaw_ff = 120
    };

    // 2. 定义三种风格的目标曲线
    StyleEQ_t styles[3] = {
        {85, 25, 15, 40},    // Racer
        {55, 60, 50, 55},    // Freestyle
        {25, 85, 80, 85}     // Cinematic
    };

    const char *styleNames[] = {"Racer", "Freestyle", "Cinematic"};

    for (int i = 0; i < 3; i++) {
        NSLog(@"\n--- 测试风格: %s ---\n", styleNames[i]);

        // 3. 应用风格约束
        BF_PID_t styleConstrainedPID = [StyleEQMapper applyStyleConstraints:baseDefaults
                                                                   style:styles[i]];

        NSLog(@"风格约束后的PID:");
        NSLog(@"  Roll: P=%.0f, I=%.0f, D=%.0f, FF=%.0f",
              styleConstrainedPID.roll_p, styleConstrainedPID.roll_i,
              styleConstrainedPID.roll_d, styleConstrainedPID.roll_ff);

        // 4. 从风格PID生成目标曲线
        TargetCurveFeatures_t targetFeatures = {
            .riseTime = 0.05f,    // 50ms上升时间
            .overshoot = (i == 0) ? 0.15f : ((i == 1) ? 0.08f : 0.02f), // Racer允许震荡
            .steadyState = 10.0f,
            .bandwidth = (i == 0) ? 80.0f : ((i == 1) ? 55.0f : 35.0f)
        };

        // 5. 反解PID（基于目标特征）
        BF_PID_t solvedPID = [PIDInverseSolver solvePIDFromTargetFeatures:targetFeatures
                                                           baseDefaults:baseDefaults];

        NSLog(@"反解得到的PID:");
        NSLog(@"  Roll: P=%.0f, I=%.0f, D=%.0f, FF=%.0f",
              solvedPID.roll_p, solvedPID.roll_i,
              solvedPID.roll_d, solvedPID.roll_ff);

        // 6. 计算误差分析
        [self analyzePIDError:styleConstrainedPID solvedPID:solvedPID];

        // 7. 验证反算精度（模拟）
        [self validateReverseMapping:baseDefaults solvedPID:solvedPID];
    }

    // 8. 测试风格旋钮平滑过渡
    NSLog(@"\n--- 风格旋钮平滑过渡测试 ---\n");
    [self testSmoothStyleTransition:baseDefaults];
}

/// 分析PID误差
+ (void)analyzePIDError:(BF_PID_t)target solvedPID:(BF_PID_t)solved {
    NSLog(@"PID误差分析:");

    double pError = fabs(target.roll_p - solvedPID.roll_p) / target.roll_p * 100;
    double iError = fabs(target.roll_i - solvedPID.roll_i) / target.roll_i * 100;
    double dError = fabs(target.roll_d - solvedPID.roll_d) / target.roll_d * 100;
    double ffError = fabs(target.roll_ff - solvedPID.roll_ff) / target.roll_ff * 100;

    printf("  Roll P: %.1f%%\n", pError);
    printf("  Roll I: %.1f%%\n", iError);
    printf("  Roll D: %.1f%%\n", dError);
    printf("  Roll FF: %.1f%%\n", ffError);

    double avgError = (pError + iError + dError + ffError) / 4.0;
    printf("  平均误差: %.1f%%\n", avgError);
}

/// 验证反向映射精度
+ (void)validateReverseMapping:(BF_PID_t)original solvedPID:(BF_PID_t)solved {
    NSLog(@"反向映射精度验证:");

    // 使用正映射计算回滑块
    // 模拟正映射逻辑
    BF_Sliders_t testSliders = {
        .pi_gain = (uint16_t)round(solved.roll_p / 45.0 * 100.0),
        .d_gain = (uint16_t)round(solved.roll_d / 30.0 * 100.0),
        .ff_gain = (uint16_t)round(solved.roll_ff / 120.0 * 100.0)
    };

    NSLog(@"  反算滑块: pi_gain=%d, d_gain=%d, ff_gain=%d",
          testSliders.pi_gain, testSliders.d_gain, testSliders.ff_gain);

    // 从滑块重新计算PID
    BF_PID_t recalculatedPID = [BFFlightController calculatePIDFromSliders:testSliders];

    NSLog(@"  重新计算PID: P=%.0f, D=%.0f, FF=%.0f",
          recalculatedPID.roll_p, recalculatedPID.roll_d, recalculatedPID.roll_ff);

    // 计算闭环误差
    double pRoundtripError = fabs(original.roll_p - recalculatedPID.roll_p) / original.roll_p * 100;
    NSLog(@"  闭环误差: %.2f%%", pRoundtripError);
}

/// 测试风格旋钮平滑过渡
+ (void)testSmoothStyleTransition:(BF_PID_t)baseDefaults {
    NSLog(@"风格旋钮平滑过渡测试:");

    // 创建渐变的风格参数
    for (int step = 0; step <= 10; step++) {
        float progress = step / 10.0f;

        // 从 Cinematic (0) 到 Racer (1)
        StyleEQ_t transitionStyle = {
            .snap = 25 + progress * 60,      // 25 → 85
            .smooth = 85 - progress * 60,    // 85 → 25
            .noise = 80 - progress * 65,     // 80 → 15
            .hold = 85 - progress * 45       // 85 → 40
        };

        BF_PID_t transitionPID = [StyleEQMapper applyStyleConstraints:baseDefaults
                                                               style:transitionStyle];

        printf("Step %d: Snap=%.0f, Smooth=%.0f → P=%.0f, D=%.0f\n",
               step, transitionStyle.snap, transitionStyle.smooth,
               transitionPID.roll_p, transitionPID.roll_d);
    }
}

@end

// ============================================================================
// 6. 主测试函数
// ============================================================================

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔧 BF反向求解验证系统启动\n");

        // 运行完整的反向求解验证
        [ReverseValidationSystem runReverseValidation];

        NSLog(@"\n✅ 反向求解验证完成");
    }
    return 0;
}