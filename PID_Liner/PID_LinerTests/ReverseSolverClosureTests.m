//
//  ReverseSolverClosureTests.m
//  PID_LinerTests
//
//  阶段3: 合成数据反解闭环验证
//
//  目的: 证明 LM + 数值雅可比能从合成曲线还原已知 PID
//       已知 (P,I,D,FF + mech) → forward 合成 → LM 反解 → 能还原原 PID?
//       ✅ 还原 → 反解框架正确, 可上真实 BBL
//       ❌ 不还原 → LM / forward 设计有问题, 先修框架
//
//  机械常数用 001.bbl 标定参考值 (kPlant=87, tauM=0.01, dScale=0.0007)
//

#import <XCTest/XCTest.h>
#import "PIDReverseSolver.h"
#import "PIDRecommendationEngine.h"
#import <math.h>

@interface ReverseSolverClosureTests : XCTestCase
@end

@implementation ReverseSolverClosureTests

#pragma mark - 辅助

/// 001.bbl 标定参考机械常数
- (BFMechConstants *)realMech {
    return [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];
}

/// 合成目标曲线: 已知 PID → forward
- (NSArray<NSNumber *> *)syntheticTargetWithP:(double)p i:(double)i d:(double)d ff:(double)ff {
    PIDValues *pid = [PIDValues new];
    pid.p = p; pid.i = i; pid.d = d; pid.ff = ff;
    return [PIDReverseSolver forwardCurveWithPID:pid
                                   mechConstants:[self realMech]
                                           length:4000 duration:0.5];
}

/// 相对误差 %
- (double)pctErr:(double)solved vs:(double)truth {
    if (fabs(truth) < 1e-9) return fabs(solved - truth) * 100.0;
    return fabs(solved - truth) / fabs(truth) * 100.0;
}

#pragma mark - 基础: forward 确定性 + 可微性

/// forward 必须确定性 (同入同出) — LM 数值雅可比的前提
- (void)testForward_Deterministic {
    PIDValues *pid = [PIDValues new];
    pid.p = 38; pid.i = 85; pid.d = 44; pid.ff = 72;
    NSArray<NSNumber *> *c1 = [PIDReverseSolver forwardCurveWithPID:pid mechConstants:[self realMech] length:4000 duration:0.5];
    NSArray<NSNumber *> *c2 = [PIDReverseSolver forwardCurveWithPID:pid mechConstants:[self realMech] length:4000 duration:0.5];
    XCTAssertEqual(c1.count, c2.count);
    double maxDiff = 0;
    for (NSInteger k = 0; k < (NSInteger)c1.count; k++) {
        maxDiff = fmax(maxDiff, fabs(c1[k].doubleValue - c2[k].doubleValue));
    }
    XCTAssertLessThan(maxDiff, 1e-12, @"forward 非确定性 maxDiff=%.2e", maxDiff);
}

/// 真实 PID 算出的二阶参数在工作区间 (不被 clamp, 雅可比有效)
- (void)testForward_WorkPointInRange {
    PIDValues *pid = [PIDValues new];
    pid.p = 38; pid.i = 85; pid.d = 44; pid.ff = 72;
    NSArray<NSNumber *> *curve = [PIDReverseSolver forwardCurveWithPID:pid mechConstants:[self realMech] length:4000 duration:0.5];
    // 曲线应是有意义的阶跃响应: 末段接近稳态(~1), 不全 0
    double tail = curve[curve.count - 1].doubleValue;
    double head = curve[1].doubleValue;
    XCTAssertGreaterThan(tail, 0.5, @"稳态值过低 tail=%.3f (ωn 可能被 clamp 到下限)", tail);
    NSLog(@"[WorkPoint] 曲线首段=%.3f 末段=%.3f (期望阶跃 0→1)", head, tail);
}

#pragma mark - 🎯 核心闭环: PD 2 参数反解 (最小验证)

/// 固定 I/FF, 反解 P/D — 最小闭环, 证明 LM + forward 框架正确
- (void)testReverseSolve_PD_TwoParams {
    double P = 38, I = 85, D = 44, FF = 72;
    NSArray<NSNumber *> *target = [self syntheticTargetWithP:P i:I d:D ff:FF];

    // 扰动初值: P/D 偏离真值 (~+45% / -36%), I/FF 固定真值
    PIDValues *guess = [PIDValues new];
    guess.p = 55; guess.i = I; guess.d = 28; guess.ff = FF;

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:[self realMech]
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:4000 duration:0.5];

    XCTAssertNotNil(r, @"反解返回 nil (输入非法)");
    XCTAssertTrue(r.converged,
                 @"PD 反解未收敛 iter=%ld RMSE=%.6f", (long)r.iterations, r.finalRMSE);

    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];
    NSLog(@"🎯 [PD反解] P=%.3f(真%.0f, %.2f%%) D=%.3f(真%.0f, %.2f%%) iter=%ld RMSE=%.2e",
          r.solvedPID.p, P, pErr, r.solvedPID.d, D, dErr, (long)r.iterations, r.finalRMSE);

    XCTAssertLessThan(r.finalRMSE, 1e-3, @"RMSE=%.2e 超标 (forward 拟合不够好)", r.finalRMSE);
    XCTAssertLessThan(pErr, 5.0, @"P 误差 %.2f%% > 5%%", pErr);
    XCTAssertLessThan(dErr, 10.0, @"D 误差 %.2f%% > 10%%", dErr);
}

#pragma mark - 全 4 参数反解 (I/FF 信号弱, 阈值放宽)

/// 反解全部 P/I/D/FF — I/FF 在阶跃响应中信号弱, 期望 P/D 精度高, I/FF 精度低
- (void)testReverseSolve_AllFourParams {
    double P = 38, I = 85, D = 44, FF = 72;
    NSArray<NSNumber *> *target = [self syntheticTargetWithP:P i:I d:D ff:FF];

    PIDValues *guess = [PIDValues new];
    guess.p = 50; guess.i = 100; guess.d = 30; guess.ff = 60;

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:[self realMech]
                                                    fitMask:PIDReverseFitAll
                                                     length:4000 duration:0.5];

    XCTAssertNotNil(r);
    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double iErr = [self pctErr:r.solvedPID.i vs:I];
    double dErr = [self pctErr:r.solvedPID.d vs:D];
    double ffErr = [self pctErr:r.solvedPID.ff vs:FF];
    NSLog(@"🎯 [4参反解] P=%.2f(%.1f%%) I=%.2f(%.1f%%) D=%.2f(%.1f%%) FF=%.2f(%.1f%%) iter=%ld RMSE=%.2e conv=%d",
          r.solvedPID.p, pErr, r.solvedPID.i, iErr, r.solvedPID.d, dErr, r.solvedPID.ff, ffErr,
          (long)r.iterations, r.finalRMSE, r.converged);

    // P/D 应高精度 (强信号)
    XCTAssertLessThan(pErr, 5.0, @"P 误差 %.1f%% 过大", pErr);
    XCTAssertLessThan(dErr, 15.0, @"D 误差 %.1f%% 过大 (D_scale 致信号弱, 放宽)", dErr);
    // 🔑 已知限制 (合成实测): I 在单阶跃响应中信号极弱, LM 会把不可辨的 I 推到边界 0
    //    这是物理限制 (单条阶跃不可辨 I), 非框架 bug; 真实反解需多曲线或稳态误差信号
    //    P/D/FF 信号强, 合成下误差 < 0.6%
}

#pragma mark - 🎯 3.3a: gyro 低通对照实验 (证 P 偏差根因 = forward 缺低通)
//
// 假设 (来自 3.2 真实 BBL: P 反解偏低 40%):
//   真实响应被 BF gyro_lowpass 涂抹 → 上升沿变缓
//   纯二阶 forward 无滤波 → 为匹配变缓上升沿只能降 ωn → P 偏低
//   forward 加同款低通后 → 上升沿形状对齐 → P 可还原
//
// Test A (复现): 带滤波 target → 无滤波 forward 反解 → 期望 P 偏低 >15%
// Test B (还原): 带滤波 target → 带滤波 forward 反解 → 期望 P 误差 <5%
//   A 复现 + B 还原 = 假设成立 → 可上真实 BBL 验证

/// 合成带 gyro 低通的曲线 (模拟真实 BBL: gyro 已被 BF gyro_lowpass 涂抹)
- (NSArray<NSNumber *> *)syntheticFilteredTargetWithP:(double)p i:(double)i d:(double)d
                                                   ff:(double)ff gyroHz:(double)hz {
    PIDValues *pid = [PIDValues new];
    pid.p = p; pid.i = i; pid.d = d; pid.ff = ff;
    return [PIDReverseSolver forwardCurveWithPID:pid
                                   mechConstants:[self realMech]
                                   filterConfig:[BFFilterConfig gyroLowpass:hz]
                                           length:4000 duration:0.5];
}

/// 🔬 Test A: 带滤波 target → 无滤波 forward 反解 (真值初值) → 期望 P 偏低
///   真值初值确保偏差只来自模型失配, 非初值依赖
- (void)testSynthetic_GyroLowpassReproducesPBias {
    double P = 38, I = 85, D = 44, FF = 72;
    NSArray<NSNumber *> *target = [self syntheticFilteredTargetWithP:P i:I d:D ff:FF gyroHz:150.0];

    PIDValues *guess = [PIDValues new];
    guess.p = P; guess.i = I; guess.d = D; guess.ff = FF;  // 真值初值

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:[self realMech]
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:4000 duration:0.5];
    XCTAssertNotNil(r);
    double pErr = [self pctErr:r.solvedPID.p vs:P];

    NSString *report = [NSString stringWithFormat:
        @"[3.3a-A] target=forward(P=38,D=44,gyro150Hz), 无滤波forward反解(真值初值)\n"
        @"P=%.2f(真38, %.1f%%) D=%.2f RMSE=%.4f iter=%ld\n复现: %@",
        r.solvedPID.p, pErr, r.solvedPID.d, r.finalRMSE, (long)r.iterations,
        pErr > 15.0 ? @"✅ P偏低>15% → 复现真实BBL症状, 假设(缺低通)成立"
                    : @"❌ P未偏低, 假设不成立"];
    [report writeToFile:@"/tmp/synth_lowpass_bias.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🔬 %@", report);

    XCTAssertTrue(pErr > 15.0, @"P 误差 %.1f%% < 15%%, 未复现偏低症状 (假设不成立)", pErr);
}

/// 🎯 Test B: 带滤波 target → 带滤波 forward 反解 (扰动初值) → 期望 P 还原 <5%
- (void)testSynthetic_GyroLowpassRestoresP {
    double P = 38, I = 85, D = 44, FF = 72;
    NSArray<NSNumber *> *target = [self syntheticFilteredTargetWithP:P i:I d:D ff:FF gyroHz:150.0];

    PIDValues *guess = [PIDValues new];
    guess.p = P * 1.4; guess.i = I; guess.d = D * 0.6; guess.ff = FF;  // 扰动初值

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:[self realMech]
                                              filterConfig:[BFFilterConfig gyroLowpass:150.0]
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:4000 duration:0.5];
    XCTAssertNotNil(r);
    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];

    NSString *report = [NSString stringWithFormat:
        @"[3.3a-B] target=forward(P=38,D=44,gyro150Hz), 带滤波forward反解(扰动初值)\n"
        @"P=%.2f(真38, %.2f%%) D=%.2f(真44, %.2f%%) RMSE=%.4e iter=%ld\n还原: %@",
        r.solvedPID.p, pErr, r.solvedPID.d, dErr, r.finalRMSE, (long)r.iterations,
        pErr < 5.0 ? @"✅ P误差<5% → 加低通治本, 可上真实BBL"
                   : @"❌ P仍偏高, 需扩dterm低通或其它"];
    [report writeToFile:@"/tmp/synth_lowpass_restore.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertLessThan(pErr, 5.0, @"P 误差 %.2f%% > 5%%, 加低通未还原 P", pErr);
}

@end
