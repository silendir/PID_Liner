//
//  BFPIDToSecondOrderMapperTests.m
//  PID_LinerTests
//
//  验证 BFPIDToSecondOrderMapper 的物理方向正确性
//  依据: 技术验证Demo/前向模型控制理论推导.md §七 数值验证
//
//  每个测试对应一条控制理论结论，对照 Oscar Liang 社区经验做 sanity check
//

#import <XCTest/XCTest.h>
#import "BFPIDToSecondOrderMapper.h"
#import "PIDRecommendationEngine.h"  // PIDValues

/// 浮点比较精度
static const double kAccuracy = 1e-4;

@interface BFPIDToSecondOrderMapperTests : XCTestCase

@property (nonatomic, strong) BFForwardModelParams *baseParams;  ///< 基准二阶参数
@property (nonatomic, strong) PIDValues *basePID;                ///< 基准 PID

@end

@implementation BFPIDToSecondOrderMapperTests

- (void)setUp {
    [super setUp];

    // 基准二阶参数（典型穿越机 50Hz 带宽，ζ=0.7）
    self.baseParams = [[BFForwardModelParams alloc] init];
    self.baseParams.gain = 1.0;
    self.baseParams.naturalFreq = 2.0 * M_PI * 50.0;  // ωn₀ = 314.16 rad/s
    self.baseParams.dampingRatio = 0.7;
    self.baseParams.integralTau = 0.5625;  // 45/80
    self.baseParams.feedforwardScale = 0.0;

    // 基准 PID（BF 默认值）
    self.basePID = [[PIDValues alloc] init];
    self.basePID.p = 45.0;
    self.basePID.i = 80.0;
    self.basePID.d = 30.0;
    self.basePID.ff = 120.0;
}

- (void)tearDown {
    [super tearDown];
}

#pragma mark - 辅助方法

- (PIDValues *)pidWithP:(double)p i:(double)i d:(double)d ff:(double)ff {
    PIDValues *v = [[PIDValues alloc] init];
    v.p = p; v.i = i; v.d = d; v.ff = ff;
    return v;
}

/// 相对误差判定（百分比）
- (BOOL)value:(double)actual relativeEquals:(double)expected tolerancePercent:(double)pct {
    if (fabs(expected) < 1e-9) return fabs(actual) < 1e-6;
    double relErr = fabs(actual - expected) / fabs(expected) * 100.0;
    return relErr <= pct;
}

#pragma mark - 测试1: P 翻倍 → 带宽↑ 阻尼↓（§7.2）

/// 🎯 核心验证: P 影响的是 ωn（开方关系），不是增益 K
/// 对照经验: "P 调高会震荡"（Oscar Liang）
- (void)testPDoubling_RaisesBandwidth_LowersDamping {
    PIDValues *doubledP = [self pidWithP:90.0 i:80.0 d:30.0 ff:120.0];  // P: 45→90

    BFForwardModelParams *result = [BFPIDToSecondOrderMapper
        mapFromBaseParams:self.baseParams oldPID:self.basePID newPID:doubledP];

    XCTAssertNotNil(result, @"P 翻倍映射不应返回 nil");

    // ωn 应为 ωn₀ · √2 ≈ 314.16 · 1.414 ≈ 444.3 rad/s
    double expectedOmega = self.baseParams.naturalFreq * sqrt(2.0);
    XCTAssertTrue([self value:result.naturalFreq relativeEquals:expectedOmega tolerancePercent:1.0],
                  @"P 翻倍: ωn 应为 √2 倍。预期=%.1f 实际=%.1f", expectedOmega, result.naturalFreq);

    // ζ 应为 ζ₀ / √2 ≈ 0.7 · 0.707 ≈ 0.495
    double expectedZeta = self.baseParams.dampingRatio / sqrt(2.0);
    XCTAssertTrue([self value:result.dampingRatio relativeEquals:expectedZeta tolerancePercent:1.0],
                  @"P 翻倍: ζ 应为 1/√2 倍。预期=%.3f 实际=%.3f", expectedZeta, result.dampingRatio);

    // 🔑 K 必须不变（这是修复缺陷①的硬验证）
    XCTAssertEqualWithAccuracy(result.gain, self.baseParams.gain, kAccuracy,
                              @"P 变化不应改变增益 K（缺陷①修复点）");

    // 转换为 Hz 直观验证
    double bwBaseHz = self.baseParams.naturalFreq / (2 * M_PI);
    double bwNewHz = result.naturalFreq / (2 * M_PI);
    NSLog(@"✅ P 翻倍: 带宽 %.0fHz → %.0fHz (↑), ζ %.2f → %.2f (↓), 符合'高P易震'",
          bwBaseHz, bwNewHz, self.baseParams.dampingRatio, result.dampingRatio);
}

#pragma mark - 测试2: D 翻倍 → 阻尼↑ 带宽不变（§7.3）

/// 🎯 核心验证: D 正比影响 ζ，且不影响 ωn
/// 对照经验: "加 D 压震荡"
- (void)testDDoubling_RaisesDamping_KeepsBandwidth {
    PIDValues *doubledD = [self pidWithP:45.0 i:80.0 d:60.0 ff:120.0];  // D: 30→60

    BFForwardModelParams *result = [BFPIDToSecondOrderMapper
        mapFromBaseParams:self.baseParams oldPID:self.basePID newPID:doubledD];

    XCTAssertNotNil(result);

    // ωn 应保持不变（D 不影响带宽）
    XCTAssertTrue([self value:result.naturalFreq relativeEquals:self.baseParams.naturalFreq tolerancePercent:1.0],
                  @"D 翻倍: ωn 应不变。基准=%.1f 实际=%.1f",
                  self.baseParams.naturalFreq, result.naturalFreq);

    // ζ 应为 ζ₀ · 2 = 1.4
    double expectedZeta = self.baseParams.dampingRatio * 2.0;
    XCTAssertTrue([self value:result.dampingRatio relativeEquals:expectedZeta tolerancePercent:1.0],
                  @"D 翻倍: ζ 应为 2 倍。预期=%.3f 实际=%.3f", expectedZeta, result.dampingRatio);

    NSLog(@"✅ D 翻倍: 带宽不变, ζ %.2f → %.2f (↑), 符合'加D压震'",
          self.baseParams.dampingRatio, result.dampingRatio);
}

#pragma mark - 测试3: I 翻倍 → τ_I 减半（§四）

/// 🎯 核心验证: I 项不再丢失，建模为积分时间常数
- (void)testIDoubling_HalvesIntegralTau {
    PIDValues *doubledI = [self pidWithP:45.0 i:160.0 d:30.0 ff:120.0];  // I: 80→160

    BFForwardModelParams *result = [BFPIDToSecondOrderMapper
        mapFromBaseParams:self.baseParams oldPID:self.basePID newPID:doubledI];

    XCTAssertNotNil(result);

    // τ_I = Kp/Ki = 45/160 = 0.28125（基准 45/80 = 0.5625，应减半）
    double expectedTauI = 45.0 / 160.0;
    XCTAssertTrue([self value:result.integralTau relativeEquals:expectedTauI tolerancePercent:1.0],
                  @"I 翻倍: τ_I 应减半。预期=%.4f 实际=%.4f", expectedTauI, result.integralTau);

    // 🔑 I 不应影响瞬态参数 ωn/ζ（缺陷②的正确处理）
    XCTAssertTrue([self value:result.naturalFreq relativeEquals:self.baseParams.naturalFreq tolerancePercent:0.1],
                  @"I 变化不应影响 ωn");
    XCTAssertTrue([self value:result.dampingRatio relativeEquals:self.baseParams.dampingRatio tolerancePercent:0.1],
                  @"I 变化不应影响 ζ");

    NSLog(@"✅ I 翻倍: τ_I %.3f → %.3f (减半), ωn/ζ 不变（I 不再丢失）",
          self.baseParams.integralTau, result.integralTau);
}

#pragma mark - 测试4: FF 变化 → 二阶参数全不变（§五）

/// 🎯 核心验证: FF 不进 ωn/ζ/K，作为独立前向通道
- (void)testFFChange_DoesNotAffectSecondOrderParams {
    PIDValues *doubledFF = [self pidWithP:45.0 i:80.0 d:30.0 ff:240.0];  // FF: 120→240

    BFForwardModelParams *result = [BFPIDToSecondOrderMapper
        mapFromBaseParams:self.baseParams oldPID:self.basePID newPID:doubledFF];

    XCTAssertNotNil(result);

    // 🔑 FF 翻倍时 ωn/ζ/K 全部不变（缺陷①的 FF 部分修复点）
    XCTAssertEqualWithAccuracy(result.naturalFreq, self.baseParams.naturalFreq, kAccuracy,
                              @"FF 不应影响 ωn");
    XCTAssertEqualWithAccuracy(result.dampingRatio, self.baseParams.dampingRatio, kAccuracy,
                              @"FF 不应影响 ζ");
    XCTAssertEqualWithAccuracy(result.gain, self.baseParams.gain, kAccuracy,
                              @"FF 不应影响 K");

    // feedforwardScale 应变化（相对基准）
    XCTAssertGreaterThan(result.feedforwardScale, 0.0, @"FF 增加，scale 应 > 0");

    NSLog(@"✅ FF 翻倍: ωn/ζ/K 全部不变, feedforwardScale=%.3f（独立前向通道）",
          result.feedforwardScale);
}

#pragma mark - 测试5: P/D 耦合验证（§2.4）

/// 🎯 验证 P 和 D 是耦合的：同时调 P 和 D 时，ζ 受双重影响
- (void)testPAndDAreCoupled {
    // P 翻倍 + D 翻倍
    PIDValues *both = [self pidWithP:90.0 i:80.0 d:60.0 ff:120.0];

    BFForwardModelParams *result = [BFPIDToSecondOrderMapper
        mapFromBaseParams:self.baseParams oldPID:self.basePID newPID:both];

    // ωn: √2 倍（P 主导）
    double expectedOmega = self.baseParams.naturalFreq * sqrt(2.0);
    XCTAssertTrue([self value:result.naturalFreq relativeEquals:expectedOmega tolerancePercent:1.0]);

    // ζ: (2/√2) = √2 倍（D 正比 × P 反开方）
    double expectedZeta = self.baseParams.dampingRatio * 2.0 / sqrt(2.0);
    XCTAssertTrue([self value:result.dampingRatio relativeEquals:expectedZeta tolerancePercent:1.0],
                  @"P+D 同时翻倍: ζ 应为 √2 倍。预期=%.3f 实际=%.3f", expectedZeta, result.dampingRatio);

    NSLog(@"✅ P+D 耦合验证: 同时翻倍时 ζ 为 √2 倍 (=%.3f), 耦合关系正确", result.dampingRatio);
}

#pragma mark - 测试6: 错误处理（CLAUDE.md 必须项）

- (void)testNilInput_ReturnsNil {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    XCTAssertNil([BFPIDToSecondOrderMapper mapFromBaseParams:nil
                                                       oldPID:self.basePID
                                                       newPID:self.basePID],
                 @"baseParams 为 nil 应返回 nil");
    XCTAssertNil([BFPIDToSecondOrderMapper mapFromBaseParams:self.baseParams
                                                       oldPID:nil
                                                       newPID:self.basePID],
                 @"oldPID 为 nil 应返回 nil");
#pragma clang diagnostic pop
}

- (void)testZeroOldP_ReturnsNil {
    PIDValues *zeroP = [self pidWithP:0.0 i:80.0 d:30.0 ff:120.0];
    XCTAssertNil([BFPIDToSecondOrderMapper mapFromBaseParams:self.baseParams
                                                       oldPID:zeroP
                                                       newPID:self.basePID],
                 @"oldP=0 应返回 nil（除零保护）");
}

- (void)testNegativeNewPID_ReturnsNil {
    PIDValues *negP = [self pidWithP:-10.0 i:80.0 d:30.0 ff:120.0];
    XCTAssertNil([BFPIDToSecondOrderMapper mapFromBaseParams:self.baseParams
                                                       oldPID:self.basePID
                                                       newPID:negP],
                 @"负 PID 应返回 nil（物理无意义）");
}

#pragma mark - 测试7: 预测曲线生成

- (void)testPredictedCurve_Generation {
    BFForwardModelParams *params = [[BFForwardModelParams alloc] init];
    params.gain = 1.0;
    params.naturalFreq = 2.0 * M_PI * 50.0;
    params.dampingRatio = 0.7;
    params.integralTau = 0.5;
    params.feedforwardScale = 0.1;

    NSArray<NSNumber *> *curve = [BFPIDToSecondOrderMapper
        predictedCurveWithParams:params length:400 duration:0.5];

    XCTAssertEqual(curve.count, (NSUInteger)400, @"曲线点数应为 400");
    XCTAssertGreaterThan([curve.lastObject doubleValue], 0.9,
                        @"稳态值应接近增益 1.0");
    XCTAssertLessThan([curve.lastObject doubleValue], 1.1,
                     @"稳态值不应超调过大");
}

- (void)testPredictedCurve_InvalidInput_ReturnsSafe {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    NSArray<NSNumber *> *bad = [BFPIDToSecondOrderMapper
        predictedCurveWithParams:nil length:0 duration:0.0];
#pragma clang diagnostic pop
    XCTAssertEqual(bad.count, (NSUInteger)1, @"非法输入应返回安全退化值");
}

#pragma mark - 测试8: 比例关系函数（§6.1）

- (void)testRatioFunctions {
    XCTAssertEqualWithAccuracy([BFPIDToSecondOrderMapper omegaRatioFromPRatio:4.0],
                               2.0, kAccuracy, @"√4 = 2");
    XCTAssertEqualWithAccuracy([BFPIDToSecondOrderMapper dampingRatioFromPRatio:4.0],
                               0.5, kAccuracy, @"1/√4 = 0.5");
    XCTAssertEqualWithAccuracy([BFPIDToSecondOrderMapper dampingRatioFromDRatio:3.0],
                               3.0, kAccuracy, @"D 正比 = 3");
}

@end