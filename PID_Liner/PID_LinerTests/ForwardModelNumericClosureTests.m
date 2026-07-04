//
//  ForwardModelNumericClosureTests.m
//  PID_LinerTests
//
//  阶段2.5a: 合成数据验证"拟合-回放"数值闭环
//
//  目的: 隔离 fitSecondOrderFromResponse 的数值精度
//       合成数据本身是二阶(已知 K/ωn/ζ)，拟合回去应当能还原
//       若合成数据 RMSE 就高 → 拟合方法有 bug(非二阶模型本身问题)
//       若合成数据 RMSE ≈ 0 → 工具正确，真实BBL的 RMSE 才反映模型精度
//

#import <XCTest/XCTest.h>
#import "PIDRecommendationEngine.h"
#import <math.h>

#pragma mark - 私有方法暴露（测试用 category）

/// 临时暴露 PIDRecommendationEngine 的私有拟合方法，供测试调用
@interface PIDRecommendationEngine (NumericClosureTestAccess)
- (void)fitSecondOrderFromResponse:(NSArray<NSNumber *> *)response
                              gain:(double *)outGain
                      naturalFreq:(double *)outWn
                     dampingRatio:(double *)outZeta;
@end

#pragma mark - 测试类

@interface ForwardModelNumericClosureTests : XCTestCase
@end

@implementation ForwardModelNumericClosureTests

#pragma mark - 辅助

/// 两曲线间 RMSE
- (double)rmseBetween:(NSArray<NSNumber *> *)a and:(NSArray<NSNumber *> *)b {
    NSInteger n = MIN(a.count, b.count);
    if (n == 0) return NAN;
    double sum = 0.0;
    for (NSInteger i = 0; i < n; i++) {
        double d = a[i].doubleValue - b[i].doubleValue;
        sum += d * d;
    }
    return sqrt(sum / (double)n);
}

/// 核心断言：生成合成二阶曲线 → 拟合 → 回放 → 对比参数 + RMSE
/// duration=0.5, length=4000 与 fitSecondOrderFromResponse 内部 dt 假设对齐
- (void)assertClosureForGain:(double)K
                naturalFreq:(double)wn
                    damping:(double)zeta
                       label:(NSString *)label {
    // 1. 生成合成曲线（已知 K/ωn/ζ）
    NSArray<NSNumber *> *synthetic = [PIDRecommendationEngine
        predictedCurveWithGain:K naturalFreq:wn dampingRatio:zeta length:4000 duration:0.5];

    // 2. 拟合
    double fitK = 0, fitWn = 0, fitZeta = 0;
    PIDRecommendationEngine *eng = [[PIDRecommendationEngine alloc] init];
    [eng fitSecondOrderFromResponse:synthetic
                               gain:&fitK
                       naturalFreq:&fitWn
                      dampingRatio:&fitZeta];

    // 3. 参数相对误差
    double kErr    = fabs(fitK - K) / K * 100.0;
    double wnErr   = wn   > 0 ? fabs(fitWn - wn) / wn * 100.0       : NAN;
    double zetaErr = zeta > 0 ? fabs(fitZeta - zeta) / zeta * 100.0 : NAN;

    // 4. 回放 RMSE
    NSArray<NSNumber *> *replayed = [PIDRecommendationEngine
        predictedCurveWithGain:fitK naturalFreq:fitWn dampingRatio:fitZeta length:4000 duration:0.5];
    double rmse = [self rmseBetween:synthetic and:replayed];

    NSLog(@"\n  [%@] K=%.3f→%.3f(%.1f%%) ωn=%.1f→%.1f(%.1f%%) ζ=%.3f→%.3f(%.1f%%) RMSE=%.4f",
          label, K, fitK, kErr, wn, fitWn, wnErr, zeta, fitZeta, zetaErr, rmse);

    // 5. 工具正确性断言：合成数据回放 RMSE 必须 < 0.05
    //    （否则 fitSecondOrder 拟合方法本身不达标，真实BBL更不行）
    XCTAssertLessThan(rmse, 0.05,
                      @"[%@] 合成数据回放 RMSE=%.4f 超标 → fitSecondOrder 拟合精度不足", label, rmse);
}

#pragma mark - 测试用例

/// 🎯 标准穿越机（ζ=0.7, 50Hz带宽）— 典型工作点
- (void)testStandardQuad_Closure {
    [self assertClosureForGain:1.0 naturalFreq:2 * M_PI * 50 damping:0.7 label:@"标准ζ=0.7,50Hz"];
}

/// 高超调（ζ=0.4，震荡明显）— 测 ζ 公式在高超调下的精度
- (void)testHighOvershoot_Closure {
    [self assertClosureForGain:1.0 naturalFreq:2 * M_PI * 50 damping:0.4 label:@"高超调ζ=0.4"];
}

/// 低超调（ζ=0.9，接近临界）— 测 ζ 公式在低超调下的鲁棒性
- (void)testLowOvershoot_Closure {
    [self assertClosureForGain:1.0 naturalFreq:2 * M_PI * 50 damping:0.9 label:@"低超调ζ=0.9"];
}

/// 高带宽（80Hz）— 测 ωn 经验公式 1.8/trise 在高带宽下的精度
- (void)testHighBandwidth_Closure {
    [self assertClosureForGain:1.0 naturalFreq:2 * M_PI * 80 damping:0.7 label:@"高带宽80Hz"];
}

@end