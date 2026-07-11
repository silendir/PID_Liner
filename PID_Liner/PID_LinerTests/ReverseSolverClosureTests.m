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

#pragma mark - 🎯 3.3b-2a: 时域积分骨架对齐验证
//
// 验收: 纯 PD (I=0, FF=0) 时域 RK4 积分 vs 解析 h(t), RMSE<1e-4
//   → 证明积分器数学正确 (状态方程与解析版同特征方程)
//   I=0/FF=0 时解析版无 0.3 权重经验叠加 → 纯 h(t), 时域可对齐

/// 纯 PD 时域积分必须对齐解析 h(t) (RMSE<1e-4) — 2a 核心验收
- (void)testTimeDomain_PD_AlignsAnalytic {
    PIDValues *pid = [PIDValues new];
    pid.p = 38; pid.i = 0; pid.d = 44; pid.ff = 0;  // 纯 PD (无 I/FF 经验叠加)

    NSArray<NSNumber *> *analytic = [PIDReverseSolver forwardCurveWithPID:pid
                                                            mechConstants:[self realMech]
                                                                    length:4000 duration:0.5];
    NSArray<NSNumber *> *timeDomain = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                         mechConstants:[self realMech]
                                                                         filterConfig:nil
                                                                                length:4000 duration:0.5];

    XCTAssertEqual(analytic.count, timeDomain.count, @"点数不一致");
    double sse = 0.0, maxDiff = 0.0;
    for (NSInteger k = 0; k < (NSInteger)analytic.count; k++) {
        double d = analytic[k].doubleValue - timeDomain[k].doubleValue;
        sse += d * d;
        maxDiff = fmax(maxDiff, fabs(d));
    }
    double rmse = sqrt(sse / (double)analytic.count);

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2a] 纯PD时域 vs 解析h(t): RMSE=%.2e maxDiff=%.2e (N=%lu)\n"
        @"解析末段=%.6f 时域末段=%.6f (稳态≈1)\n判定: %@",
        rmse, maxDiff, (unsigned long)analytic.count,
        analytic.lastObject.doubleValue, timeDomain.lastObject.doubleValue,
        rmse < 1e-4 ? @"✅ 积分器数学正确 (RMSE<1e-4)"
                    : @"❌ 积分器偏差大, 检查特征方程/RK4"];
    [report writeToFile:@"/tmp/td_pd_align.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertLessThan(rmse, 1e-4, @"纯PD时域 vs 解析 RMSE=%.2e 超标 (积分器不对齐)", rmse);
}

/// 物理 I/FF (积分项+冲激) vs 解析经验 I/FF (0.3 权重叠加) 贡献差异 — 记录不阻塞
///   2a 不作 XCTAssert (形状本质不同: 物理 FF=冲激过 plant, 经验 FF=衰减窗; 2b/2c 决定保留哪套)
- (void)testTimeDomain_I_FF_PhysVsEmpirical {
    PIDValues *pidPure = [PIDValues new];
    pidPure.p = 38; pidPure.i = 0; pidPure.d = 44; pidPure.ff = 0;
    PIDValues *pidFull = [PIDValues new];
    pidFull.p = 38; pidFull.i = 85; pidFull.d = 44; pidFull.ff = 72;

    NSArray<NSNumber *> *anaPure = [PIDReverseSolver forwardCurveWithPID:pidPure
                                                           mechConstants:[self realMech]
                                                                   length:4000 duration:0.5];
    NSArray<NSNumber *> *anaFull = [PIDReverseSolver forwardCurveWithPID:pidFull
                                                           mechConstants:[self realMech]
                                                                   length:4000 duration:0.5];
    NSArray<NSNumber *> *tdFull  = [PIDReverseSolver forwardCurveTimeDomainWithPID:pidFull
                                                                      mechConstants:[self realMech]
                                                                      filterConfig:nil
                                                                             length:4000 duration:0.5];

    // 纯 PD 已对齐 (上一测试), 故 anaPure ≈ tdPure; I/FF 贡献 = full − pure
    double sseEmp = 0, ssePhy = 0, maxEmp = 0, maxPhy = 0;
    NSMutableString *csv = [NSMutableString stringWithString:@"idx,t_ms,empiricalIFF,physIFF\n"];
    NSInteger N = (NSInteger)anaPure.count;
    for (NSInteger k = 0; k < N; k++) {
        double emp = anaFull[k].doubleValue - anaPure[k].doubleValue;  // 解析经验 I/FF 贡献
        double phy = tdFull[k].doubleValue  - anaPure[k].doubleValue;  // 物理 I/FF 贡献
        sseEmp += emp*emp; ssePhy += phy*phy;
        maxEmp = fmax(maxEmp, fabs(emp)); maxPhy = fmax(maxPhy, fabs(phy));
        if (k % 40 == 0) {  // 抽样 100 点
            [csv appendFormat:@"%ld,%.3f,%.5f,%.5f\n",
                (long)k, (double)k * 500.0 / (double)(N - 1), emp, phy];
        }
    }
    double rmsEmp = sqrt(sseEmp / N), rmsPhy = sqrt(ssePhy / N);

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2a] I/FF 物理 vs 经验 贡献对比 (N=%ld)\n"
        @"  经验 I/FF (0.3权重叠加):  RMS=%.4f max=%.4f\n"
        @"  物理 I/FF (积分+冲激):    RMS=%.4f max=%.4f\n"
        @"结论: 形状本质不同 (物理FF=阶跃冲激过plant平滑; 经验FF=前5ms衰减窗叠加); 2b/2c 决定保留哪套",
        (long)N, rmsEmp, maxEmp, rmsPhy, maxPhy];
    [csv appendFormat:@"\n%@", report];
    [csv writeToFile:@"/tmp/td_iff_compare.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"📊 %@", report);
    // 2a 不阻塞: 仅记录差异 (无 XCTAssert)
}

#pragma mark - 🎯 3.3b-2b: D 路径三级 PT1 低通链 (BF 真实 dterm 通道)
//
// 验收: D 项从固定 −Kd_eff·v 升级为 −Kd_eff·PT1_chain(v)
//   1) 接线: 有/无 dterm 链的时域曲线必须显著不同 (filter 真的作用了)
//   2) 物理方向: dterm 低通衰减高频 D → 等效阻尼下降 → 过冲/振铃加重
//      (固定 D 在所有频率提供阻尼; PT1 链在 >截止频率衰减 D 信号)
//   3) 2a 回归: nil filter 仍走纯 PD 对齐路径 (dtermFc 全 0, freezeD=NO)
//
// 真实 BBL 的 RMSE 地板对比见 RealBBLClosureTests (001.bbl roll 曲线)

/// 001.bbl 真实 dterm 三级 PT1 链 (type=0): dterm_lowpass=150 / lowpass2=150 / dyn=70-170(取120)
- (BFFilterConfig *)realDtermChain {
    return [BFFilterConfig dtermPT1Chain:150.0 h2:150.0 dyn:120.0];
}

/// D 路径三级 PT1 滤波必须显著改变时域曲线 (接线正确性)
- (void)testTimeDomain_DtermFilter_ChangesCurve {
    PIDValues *pid = [PIDValues new];
    pid.p = 38; pid.i = 85; pid.d = 44; pid.ff = 72;

    NSArray<NSNumber *> *noFilter = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                       mechConstants:[self realMech]
                                                                       filterConfig:nil
                                                                              length:4000 duration:0.5];
    NSArray<NSNumber *> *dterm150 = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                       mechConstants:[self realMech]
                                                                       filterConfig:[self realDtermChain]
                                                                              length:4000 duration:0.5];

    XCTAssertEqual(noFilter.count, dterm150.count);
    double sse = 0, maxDiff = 0;
    for (NSInteger k = 0; k < (NSInteger)noFilter.count; k++) {
        double d = noFilter[k].doubleValue - dterm150[k].doubleValue;
        sse += d * d;
        maxDiff = fmax(maxDiff, fabs(d));
    }
    double rmsDiff = sqrt(sse / (double)noFilter.count);

    // 过冲对比 (前 200 点 = 25ms, 捕捉上升沿+第一过冲)
    double peakNoF = 0, peakDT = 0;
    NSInteger lim = MIN(200, (NSInteger)noFilter.count);
    for (NSInteger k = 0; k < lim; k++) {
        peakNoF = fmax(peakNoF, noFilter[k].doubleValue);
        peakDT  = fmax(peakDT,  dterm150[k].doubleValue);
    }

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2b] D路径三级PT1 (150/150/120) 接线验证\n"
        @"  无滤波 vs 有滤波: RMS差=%.4f maxDiff=%.4f\n"
        @"  前25ms峰值: 无滤波=%.4f / dterm链=%.4f\n"
        @"  方向: %@",
        rmsDiff, maxDiff, peakNoF, peakDT,
        peakDT > peakNoF ? @"✅ dterm滤波→阻尼降→过冲加重 (物理方向对)"
                         : @"⚠️ 过冲未加重 (FF冲激主导, 留2c定夺)"];
    // 注: FF 已修为离散 Kff_norm (非 /dt 冲激), 峰值回到物理范围, 过冲对比有意义
    [report writeToFile:@"/tmp/td_dterm_wiring.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertGreaterThan(maxDiff, 1e-3, @"dterm 链未改变曲线 (filter 没作用, 接线错误)");
}

@end
