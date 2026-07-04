//
//  后台验证Demo.m
//  PID_Liner 技术验证 - 纯后台无UI
//
//  模拟 BetaFlight 滑块调整 PID → 生成预测曲线 → 验证映射关系
//

#import <Foundation/Foundation.h>

// ============================================================================
// 1. BF 滑块体系数学模型（来自 BF Chirp AutoTune 技术重点.md）
// ============================================================================

/// BF 默认 PID 值（黄金默认值）
static const NSDictionary *kBFPIDDefaults = @{
    @"roll":  @{@"P": @45, @"I": @80, @"D": @30, @"FF": @120},
    @"pitch": @{@"P": @47, @"I": @84, @"D": @34, @"FF": @125},
    @"yaw":   @{@"P": @45, @"I": @80, @"D": @0,   @"FF": @120}
};

/// 滑块到 PID 的正映射计算
@implementation BFPIDSliderMapper

+ (NSDictionary *)pidFromSliders:(NSDictionary *)sliders {
    // 从 BF Chirp AutoTune 技术重点.md §2.3.2
    double master = [sliders[@"master"] doubleValue] / 100.0;
    double piGain = [sliders[@"pi_gain"] doubleValue] / 100.0;
    double dGain = [sliders[@"d_gain"] doubleValue] / 100.0;
    double ffGain = [sliders[@"ff_gain"] doubleValue] / 100.0;
    double iGain = [sliders[@"i_gain"] doubleValue] / 100.0;
    double pitchPiGain = [sliders[@"pitch_pi_gain"] doubleValue] / 100.0;
    double rollPitchRatio = [sliders[@"roll_pitch_ratio"] doubleValue] / 100.0;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // Roll 轴计算
    NSMutableDictionary *roll = [NSMutableDictionary dictionary];
    roll[@"P"] = @(45 * master * piGain);
    roll[@"I"] = @(80 * master * piGain * iGain);
    roll[@"D"] = @(30 * master * dGain);
    roll[@"FF"] = @(120 * master * piGain * ffGain);
    result[@"roll"] = roll;

    // Pitch 轴（特殊处理）
    NSMutableDictionary *pitch = [NSMutableDictionary dictionary];
    pitch[@"P"] = @(47 * master * piGain * pitchPiGain);
    pitch[@"I"] = @(84 * master * piGain * iGain * pitchPiGain);
    pitch[@"D"] = @(34 * master * dGain * rollPitchRatio);
    pitch[@"FF"] = @(125 * master * pitchPiGain * ffGain);
    result[@"pitch"] = pitch;

    // Yaw 轴
    NSMutableDictionary *yaw = [NSMutableDictionary dictionary];
    yaw[@"P"] = @(45 * master * piGain);
    yaw[@"I"] = @(80 * master * piGain * iGain);
    yaw[@"D"] = @(0);  // Yaw D 默认为0
    yaw[@"FF"] = @(120 * master * piGain * ffGain);
    result[@"yaw"] = yaw;

    return result;
}

+ (NSDictionary *)slidersFromPID:(NSDictionary *)pid {
    // 反向映射：从 PID 真值反算滑块（默认 master=100）
    // 公式来自 BF Chirp AutoTune 技术重点.md §2.3.3
    NSMutableDictionary *pidValues = [pid mutableCopy];
    NSMutableDictionary *roll = [pidValues[@"roll"] mutableCopy];
    NSMutableDictionary *pitch = [pidValues[@"pitch"] mutableCopy];

    NSMutableDictionary *sliders = [NSMutableDictionary dictionary];

    // P/I 共享 pi_gain
    double piGain = [roll[@"P"] doubleValue] / 45.0;
    sliders[@"pi_gain"] = @(piGain * 100);

    // I 的额外乘数
    double iGain = [roll[@"I"] doubleValue] / 80.0 / (piGain);
    sliders[@"i_gain"] = @(iGain * 100);

    // D 独立
    sliders[@"d_gain"] = @([roll[@"D"] doubleValue] / 30.0 * 100);

    // FF 独立
    sliders[@"ff_gain"] = @([roll[@"FF"] doubleValue] / 120.0 * 100);

    // Pitch 专用
    sliders[@"pitch_pi_gain"] = @([pitch[@"P"] doubleValue] / 47.0 / piGain * 100);
    sliders[@"roll_pitch_ratio"] = @([pitch[@"D"] doubleValue] / 34.0 / [sliders[@"d_gain"] doubleValue] * 100);

    return sliders;
}

@end

// ============================================================================
// 2. 风格 EQ 映射模型（来自风格化PID产品功能清单.md）
// ============================================================================

@implementation StyleEQMapper

/// 风格旋钮到 PID 调整的映射
+ (NSDictionary *)pidAdjustmentFromStyle:(NSDictionary *)style {
    // 来自风格化PID产品功能清单.md 🎛️ 部分
    double snap = [style[@"snap"] doubleValue];      // 0-100
    double smooth = [style[@"smooth"] doubleValue];  // 0-100
    double noise = [style[@"noise"] doubleValue];    // 0-100
    double hold = [style[@"hold"] doubleValue];     // 0-100

    NSMutableDictionary *adjustment = [NSMutableDictionary dictionary];

    // 1. 锐度（Snap）→ P 调整
    if (snap < 30) {
        adjustment[@"p_scale"] = @0.7;    // 缓慢响应
    } else if (snap > 70) {
        adjustment[@"p_scale"] = @1.3;    // 急速响应
    } else {
        adjustment[@"p_scale"] = @1.0;    // 平衡响应
    }

    // 2. 平滑度（Smooth）→ D 调整
    if (smooth < 20) {
        adjustment[@"d_scale"] = @0.8;    // 允许震荡
    } else if (smooth > 80) {
        adjustment[@"d_scale"] = @1.5;    // 超低超调
    } else {
        adjustment[@"d_scale"] = @1.0;    // 临界阻尼
    }

    // 3. 噪声底（Noise）→ D-term 滤波调整
    adjustment[@"dterm_cutoff"] = @(150 - noise);  // 150Hz - noise*1Hz
    if (noise > 70) {
        adjustment[@"d_scale"] = [adjustment[@"d_scale"] doubleValue] * 0.9;
    } else if (noise < 30) {
        adjustment[@"d_scale"] = [adjustment[@"d_scale"] doubleValue] * 1.1;
    }

    // 4. 锁定感（Hold）→ I/FF 调整
    adjustment[@"i_scale"] = @(1.0 + (hold - 50) * 0.02);  // ±100%
    adjustment[@"ff_scale"] = @(1.0 + (hold - 50) * 0.015);

    return adjustment;
}

/// 风格旋钮到 BF 滑块的映射
+ (NSDictionary *)slidersFromStyle:(NSDictionary *)style {
    NSDictionary *pidAdjustment = [self pidAdjustmentFromStyle:style];

    // 当前 PID 值
    NSDictionary *currentPID = [BFPIDSliderMapper pidFromSliders:@{
        @"master": @100,
        @"pi_gain": @100,
        @"d_gain": @100,
        @"ff_gain": @100,
        @"i_gain": @100,
        @"pitch_pi_gain": @100,
        @"roll_pitch_ratio": @100
    }];

    // 计算新的 PID 值
    NSMutableDictionary *newPID = [NSMutableDictionary dictionary];
    for (NSString *axis in currentPID.allKeys) {
        NSMutableDictionary *axisPID = [currentPID[axis] mutableCopy];
        for (NSString *param in axisPID.allKeys) {
            double originalValue = [axisPID[param] doubleValue];
            double scaledValue = originalValue;

            if ([param isEqualToString:@"P"] || [param isEqualToString:@"I"] || [param isEqualToString:@"FF"]) {
                scaledValue *= [pidAdjustment[@"p_scale"] doubleValue];  // P/I/FF 共享 scale
            } else if ([param isEqualToString:@"D"]) {
                scaledValue *= [pidAdjustment[@"d_scale"] doubleValue];
            }

            axisPID[param] = @(scaledValue);
        }
        newPID[axis] = axisPID;
    }

    // 从新的 PID 反算滑块
    return [BFPIDSliderMapper slidersFromPID:newPID];
}

@end

// ============================================================================
// 3. 二阶系统模型（来自 AI进击计划.md）
// ============================================================================

@implementation PIDSystemModel

- (instancetype)initWithResponse:(NSArray *)response sampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        // 简化的二阶系统参数提取
        // 从实测响应拟合 ωn, ζ, K
        double riseTime = [self riseTimeFromResponse:response];
        double overshoot = [self overshootFromResponse:response];
        double settlingTime = [self settlingTimeFromResponse:response];

        self.naturalFrequency = 1.8 / riseTime;  // ωn ≈ 1.8 / rise_time
        self.dampingRatio = -log(overshoot) / sqrt(M_PI * M_PI + log(overshoot) * log(overshoot));
        self.gain = [response.lastObject doubleValue];  // 稳态值
        self.riseTime = riseTime * 1000;  // 转换为毫秒
        self.overshoot = overshoot;
        self.settlingTime = settlingTime * 1000;
    }
    return self;
}

- (double)riseTimeFromResponse:(NSArray *)response {
    // 10% → 90% 上升时间
    double tenth = [response[10] doubleValue] * 0.1;
    double ninetieth = [response[10] doubleValue] * 0.9;

    NSInteger startIndex = 0;
    NSInteger endIndex = response.count - 1;

    for (int i = 0; i < response.count; i++) {
        if ([response[i] doubleValue] >= tenth) {
            startIndex = i;
            break;
        }
    }

    for (int i = startIndex; i < response.count; i++) {
        if ([response[i] doubleValue] >= ninetieth) {
            endIndex = i;
            break;
        }
    }

    return (endIndex - startIndex) / 1000.0;  // 假设 1000Hz 采样
}

- (double)overshootFromResponse:(NSArray *)response {
    double max = [self maxFromArray:response];
    double steady = [response.lastObject doubleValue];
    return (max - steady) / steady;
}

- (double)settlingTimeFromResponse:(NSArray *)response {
    double steady = [response.lastObject doubleValue];
    double twoPercent = steady * 0.02;

    for (int i = response.count - 1; i >= 0; i--) {
        if (fabs([response[i] doubleValue] - steady) > twoPercent) {
            return (response.count - i) / 1000.0;
        }
    }
    return 0;
}

- (double)maxFromArray:(NSArray *)array {
    double max = 0;
    for (NSNumber *num in array) {
        max = fmax(max, [num doubleValue]);
    }
    return max;
}

@end

// ============================================================================
// 4. 预测曲线引擎
// ============================================================================

@implementation PIDPredictiveEngine

/// 根据参数变化预测新响应曲线
+ (NSArray *)predictResponseWithCurrentPID:(NSDictionary *)currentPID
                                newPID:(NSDictionary *)newPID
                              oldModel:(PIDSystemModel *)model
                            sampleRate:(double)sampleRate {

    NSMutableDictionary *newModel = [NSMutableDictionary dictionaryWithDictionary:model];

    // 根据 PID 变化修正传递函数参数
    // 来自 AI进击计划.md Phase 1 预测曲线部分
    NSDictionary *rollPID = currentPID[@"roll"];
    NSDictionary *newRollPID = newPID[@"roll"];

    // P 变化 → 修正增益 K
    double pRatio = [newRollPID[@"P"] doubleValue] / [rollPID[@"P"] doubleValue];
    newModel[@"gain"] = @(model.gain * pRatio);

    // D 变化 → 修正阻尼比 ζ
    double dRatio = [newRollPID[@"D"] doubleValue] / [rollPID[@"D"] doubleValue];
    newModel[@"dampingRatio"] = @(model.dampingRatio * sqrt(dRatio));

    // I 变化 → 修正低频特性
    double iRatio = [newRollPID[@"I"] doubleValue] / [rollPID[@"I"] doubleValue];
    double iOvershootCorrection = 1 + 0.1 * (iRatio - 1);
    newModel[@"dampingRatio"] = @(newModel[@"dampingRatio"] doubleValue * iOvershootCorrection);

    // 生成预测响应曲线
    int pointCount = 400;  // 400ms
    NSMutableArray *predicted = [NSMutableArray array];

    for (int i = 0; i < pointCount; i++) {
        double t = i / sampleRate;
        double wn = newModel[@"naturalFrequency"] doubleValue;
        double zeta = newModel[@"dampingRatio"] doubleValue;
        double K = newModel[@"gain"] doubleValue;

        // 二阶阶跃响应公式
        double wd = wn * sqrt(1 - zeta * zeta);
        double phi = acos(zeta);

        if (zeta < 1) {  // 欠阻尼
            double response = K * (1 - exp(-zeta * wn * t) * sin(wd * t + phi) / sqrt(1 - zeta * zeta));
            [predicted addObject:@(fmax(0, response))];
        } else {  // 临界阻尼或过阻尼
            double response = K * (1 - exp(-zeta * wn * t) * (1 + zeta * wn * t));
            [predicted addObject:@(fmax(0, response))];
        }
    }

    return predicted;
}

/// 计算预测与实际的匹配度
+ (double)calculateRMSE:(NSArray *)predicted actual:(NSArray *)actual {
    double sum = 0;
    NSInteger minLength = MIN(predicted.count, actual.count);

    for (int i = 0; i < minLength; i++) {
        double diff = [predicted[i] doubleValue] - [actual[i] doubleValue];
        sum += diff * diff;
    }

    return sqrt(sum / minLength);
}

@end

// ============================================================================
// 5. 模拟测试场景
// ============================================================================

@implementation VerificationDemo

/// 模拟 BF 滑块调整流程
+ (void)simulateBFSliderAdjustment {
    NSLog(@"\n🔧 模拟 BetaFlight 滑块调整流程\n");

    // 1. 初始状态（默认滑块值）
    NSDictionary *initialSliders = @{
        @"master": @100,
        @"pi_gain": @100,
        @"d_gain": @100,
        @"ff_gain": @100,
        @"i_gain": @100,
        @"pitch_pi_gain": @100,
        @"roll_pitch_ratio": @100
    };

    NSLog(@"初始滑块值: %@", initialSliders);

    // 2. 转换为 PID 值
    NSDictionary *initialPID = [BFPIDSliderMapper pidFromSliders:initialSliders];
    NSLog(@"\n初始 PID 值:");
    NSLog(@"Roll P=%.0f I=%.0f D=%.0f FF=%.0f",
          [initialPID[@"roll"][@"P"] doubleValue],
          [initialPID[@"roll"][@"I"] doubleValue],
          [initialPID[@"roll"][@"D"] doubleValue],
          [initialPID[@"roll"][@"FF"] doubleValue]);

    // 3. 模拟滑块调整（激进配置）
    NSDictionary *adjustedSliders = @{
        @"master": @110,
        @"pi_gain": @120,  // P/I 都增加
        @"d_gain": @110,
        @"ff_gain": @130,  // FF 增加
        @"i_gain": @100,
        @"pitch_pi_gain": @115,
        @"roll_pitch_ratio": @105
    };

    NSLog(@"\n调整后滑块值: %@", adjustedSliders);

    // 4. 转换为新 PID 值
    NSDictionary *adjustedPID = [BFPIDSliderMapper pidFromSliders:adjustedSliders];
    NSLog(@"\n调整后 PID 值:");
    NSLog(@"Roll P=%.0f I=%.0f D=%.0f FF=%.0f",
          [adjustedPID[@"roll"][@"P"] doubleValue],
          [adjustedPID[@"roll"][@"I"] doubleValue],
          [adjustedPID[@"roll"][@"D"] doubleValue],
          [adjustedPID[@"roll"][@"FF"] doubleValue]);

    // 5. 对比变化
    NSLog(@"\nPID 变化分析:");
    NSDictionary *rollPID = initialPID[@"roll"];
    NSDictionary *rollAdjusted = adjustedPID[@"roll"];

    for (NSString *param in rollPID.allKeys) {
        double original = [rollPID[param] doubleValue];
        double new = [rollAdjusted[param] doubleValue];
        double change = (new - original) / original * 100;
        NSLog(@"%@: %.0f → %.0f (%+.1f%%)", param, original, new, change);
    }

    // 6. 反向验证：从 PID 反算滑块
    NSDictionary *calculatedSliders = [BFPIDSliderMapper slidersFromPID:adjustedPID];
    NSLog(@"\n从 PID 反算的滑块值:");
    NSLog(@"pi_gain: %.0f (实际: 120)", [calculatedSliders[@"pi_gain"] doubleValue]);
    NSLog(@"d_gain: %.0f (实际: 110)", [calculatedSliders[@"d_gain"] doubleValue]);
    NSLog(@"ff_gain: %.0f (实际: 130)", [calculatedSliders[@"ff_gain"] doubleValue]);

    // 计算误差
    double piError = fabs([calculatedSliders[@"pi_gain"] doubleValue] - 120) / 120 * 100;
    double dError = fabs([calculatedSliders[@"d_gain"] doubleValue] - 110) / 110 * 100;
    NSLog(@"\n反算误差:");
    NSLog(@"pi_gain 误差: %.1f%%", piError);
    NSLog(@"d_gain 误差: %.1f%%", dError);
}

/// 模拟风格 EQ 调整流程
+ (void)simulateStyleEQAdjustment {
    NSLog(@"\n🎨 模拟风格 EQ 调整流程\n");

    // 1. 初始风格（平衡）
    NSDictionary *initialStyle = @{
        @"snap": @50,
        @"smooth": @50,
        @"noise": @50,
        @"hold": @50
    };

    NSLog(@"初始风格: %@", initialStyle);

    // 2. 转换为 PID 调整
    NSDictionary *pidAdjustment = [StyleEQMapper pidAdjustmentFromStyle:initialStyle];
    NSLog(@"\n初始 PID 调整比例:");
    NSLog(@"P scale: %.2f", [pidAdjustment[@"p_scale"] doubleValue]);
    NSLog(@"D scale: %.2f", [pidAdjustment[@"d_scale"] doubleValue]);
    NSLog(@"I scale: %.2f", [pidAdjustment[@"i_scale"] doubleValue]);
    NSLog(@"FF scale: %.2f", [pidAdjustment[@"ff_scale"] doubleValue]);

    // 3. 调整到 Racer 风格
    NSDictionary *racerStyle = @{
        @"snap": @85,    // 高锐度
        @"smooth": @25,  // 低平滑度（允许震荡）
        @"noise": @15,   // 低噪声底（保留高频）
        @"hold": @40     // 中等锁定感
    };

    NSLog(@"\nRacer 风格: %@", racerStyle);

    // 4. 转换为新的 PID 调整
    NSDictionary *racerAdjustment = [StyleEQMapper pidAdjustmentFromStyle:racerStyle];
    NSLog(@"\nRacer PID 调整比例:");
    NSLog(@"P scale: %.2f (响应更快)", [racerAdjustment[@"p_scale"] doubleValue]);
    NSLog(@"D scale: %.2f (允许震荡)", [racerAdjustment[@"d_scale"] doubleValue]);
    NSLog(@"D-term cutoff: %.0f Hz", [racerAdjustment[@"dterm_cutoff"] doubleValue]);
    NSLog(@"I scale: %.2f (悬停略降)", [racerAdjustment[@"i_scale"] doubleValue]);
    NSLog(@"FF scale: %.2f", [racerAdjustment[@"ff_scale"] doubleValue]);

    // 5. 转换为 BF 滑块
    NSDictionary *racerSliders = [StyleEQMapper slidersFromStyle:racerStyle];
    NSLog(@"\nRacer 对应的 BF 滑块值:");
    NSLog(@"pi_gain: %.0f", [racerSliders[@"pi_gain"] doubleValue]);
    NSLog(@"d_gain: %.0f", [racerSliders[@"d_gain"] doubleValue]);
    NSLog(@"ff_gain: %.0f", [racerSliders[@"ff_gain"] doubleValue]);
    NSLog(@"i_gain: %.0f", [racerSliders[@"i_gain"] doubleValue]);
}

/// 模拟曲线预测流程
+ (void)simulateCurvePrediction {
    NSLog(@"\n📊 模拟曲线预测流程\n");

    // 1. 模拟实测响应曲线
    int sampleRate = 1000;  // 1000Hz
    NSMutableArray *measuredResponse = [NSMutableArray array];

    // 生成带噪声的实测响应（二阶系统 + 噪声）
    double wn = 2 * M_PI * 50;  // 50Hz 自然频率
    double zeta = 0.6;  // 阻尼比
    double K = 1.0;  // 增益

    for (int i = 0; i < 400; i++) {
        double t = i / sampleRate;

        // 二阶阶跃响应
        double wd = wn * sqrt(1 - zeta * zeta);
        double phi = acos(zeta);
        double response = K * (1 - exp(-zeta * wn * t) * sin(wd * t + phi) / sqrt(1 - zeta * zeta));

        // 添加噪声
        double noise = (rand() % 100 - 50) / 5000.0;
        response += noise;

        [measuredResponse addObject:@(fmax(0, response))];
    }

    NSLog(@"生成实测响应曲线: %ld 个点", (long)measuredResponse.count);

    // 2. 提取系统模型
    PIDSystemModel *model = [[PIDSystemModel alloc] initWithResponse:measuredResponse sampleRate:sampleRate];
    NSLog(@"\n实测响应系统参数:");
    NSLog(@"自然频率: %.1f Hz", model.naturalFrequency / (2 * M_PI));
    NSLog(@"阻尼比: %.2f", model.dampingRatio);
    NSLog(@"超调量: %.1f%%", model.overshoot * 100);
    NSLog(@"上升时间: %.0f ms", model.riseTime);

    // 3. 初始 PID
    NSDictionary *initialPID = @{
        @"roll": @{@"P": @45, @"I": @80, @"D": @30, @"FF": @80}
    };

    // 4. 新 PID（激进调整）
    NSDictionary *newPID = @{
        @"roll": @{@"P": @60, @"I": @80, @"D": @25, @"FF": @100}
    };

    NSLog(@"\nPID 变化: Roll P 45→60 (+33.3%%), D 30→25 (-16.7%%)");

    // 5. 生成预测曲线
    NSArray *predictedResponse = [PIDPredictiveEngine predictResponseWithCurrentPID:initialPID
                                                                             newPID:newPID
                                                                           oldModel:model
                                                                         sampleRate:sampleRate];

    NSLog(@"预测曲线生成完成: %ld 个点", (long)predictedResponse.count);

    // 6. 计算匹配度
    double rmse = [PIDPredictiveEngine calculateRMSE:predictedResponse actual:measuredResponse];
    NSLog(@"\n预测 vs 实际 RMSE: %.4f", rmse);

    if (rmse < 0.05) {
        NSLog(@"✅ 预测精度良好 (RMSE < 0.05)");
    } else {
        NSLog(@"⚠️ 预测精度不足 (RMSE >= 0.05)，需要改进模型");
    }

    // 7. 模拟风格调整后的预测
    NSDictionary *racerStyle = @{
        @"snap": @85,
        @"smooth": @25,
        @"noise": @15,
        @"hold": @40
    };

    NSDictionary *racerSliders = [StyleEQMapper slidersFromStyle:racerStyle];
    NSDictionary *racerPID = [BFPIDSliderMapper pidFromSliders:racerSliders];

    NSArray *racerPredicted = [PIDPredictiveEngine predictResponseWithCurrentPID:initialPID
                                                                          newPID:racerPID
                                                                        oldModel:model
                                                                      sampleRate:sampleRate];

    double racerRMSE = [PIDPredictiveEngine calculateRMSE:racerPredicted actual:measuredResponse];
    NSLog(@"\nRacer 风格预测 RMSE: %.4f", racerRMSE);

    if (racerRMSE < rmse) {
        NSLog(@"✅ Racer 风格预测更准确");
    } else {
        NSLog(@"⚠️ Racer 风格预测不如默认准确，需要调整映射逻辑");
    }
}

/// 主测试函数
+ (void)runAllTests {
    NSLog(@"🚀 PID_Liner 技术验证 Demo 开始\n");

    // 1. BF 滑块调整验证
    [self simulateBFSliderAdjustment];

    // 2. 风格 EQ 验证
    [self simulateStyleEQAdjustment];

    // 3. 曲线预测验证
    [self simulateCurvePrediction];

    NSLog(@"\n✅ 技术验证 Demo 完成");
}

@end

// ============================================================================
// 7. 主函数
// ============================================================================

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [VerificationDemo runAllTests];
    }
    return 0;
}