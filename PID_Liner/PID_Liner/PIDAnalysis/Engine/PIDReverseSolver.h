//
//  PIDReverseSolver.h
//  PID_Liner
//
//  阶段3: 反向求解 (目标响应曲线 → PID 四参数)
//
//  方案 (技术验证Demo/反向求解方案设计.md, commit ce18196):
//    直接数值优化 forward(PID, mech) → targetCurve
//    不走 "fit二阶→反查PID" (4 PID vs 3 二阶维, 欠定)
//
//  forward 由特征方程解析:
//    τ_m·s² + (1 + K_plant·Kd·dScale)·s + K_plant·Kp = 0
//    → ωn = √(K_plant·Kp / τ_m)
//    → ζ  = (1 + K_plant·Kd·dScale) / (2·τ_m·ωn)
//    → τ_I = Kp/Ki   (I 稳态尾巴)
//    → FF  独立前向
//  曲线生成复用 BFPIDToSecondOrderMapper.predictedCurveWithParams (二阶骨架一致, 不重写)
//
//  优化器: Levenberg-Marquardt + 数值雅可比 (GN 在病态 JᵀJ 必崩, LM 阻尼治)
//
//  001.bbl 标定参考机械常数: kPlant≈87, tauM≈0.01, dScale≈0.0007
//

#import <Foundation/Foundation.h>
#import "PIDRecommendationEngine.h"  // PIDValues

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 机械常数 (反解时固定, 由标定给出)

/// 反解的机械常数容器 (plant 增益 / 电机时间常数 / D 等效系数)
/// 三个常数与 PID 在 forward 中耦合, 单条 BBL 标定解不开 (见 reverse-solve-design)
@interface BFMechConstants : NSObject

@property (nonatomic, assign) double kPlant;  ///< K_plant: plant 增益
@property (nonatomic, assign) double tauM;    ///< τ_m:   电机时间常数 (秒)
@property (nonatomic, assign) double dScale;  ///< D_scale: BF D 到二阶 Kd 的等效系数

+ (instancetype)withKPlant:(double)kPlant tauM:(double)tauM dScale:(double)dScale;

@end

#pragma mark - 反解结果

@interface PIDReverseSolveResult : NSObject

@property (nonatomic, strong, nullable) PIDValues *solvedPID;  ///< 反解 PID
@property (nonatomic, assign) double finalRMSE;                 ///< 收敛时 forward 拟合 RMSE
@property (nonatomic, assign) NSInteger iterations;             ///< LM 迭代次数
@property (nonatomic, assign) BOOL converged;                   ///< 是否达收敛阈值

@end

#pragma mark - fit 掩码 (哪些参数参与 LM 拟合)

typedef NS_OPTIONS(NSUInteger, PIDReverseFitMask) {
    PIDReverseFitP   = 1 << 0,
    PIDReverseFitI   = 1 << 1,
    PIDReverseFitD   = 1 << 2,
    PIDReverseFitFF  = 1 << 3,
    PIDReverseFitAll = PIDReverseFitP | PIDReverseFitI | PIDReverseFitD | PIDReverseFitFF,
};

#pragma mark - 反向求解器

@interface PIDReverseSolver : NSObject

/// 绝对 forward: PID + 机械常数 → 预测曲线 (合成 / 反解 / 标定共用同一函数)
+ (NSArray<NSNumber *> *)forwardCurveWithPID:(PIDValues *)pid
                               mechConstants:(BFMechConstants *)mech
                                       length:(NSInteger)length
                                     duration:(double)duration;

/// 反解: 目标曲线 → PID (LM 数值优化 forward)
///
/// @param target       目标响应曲线
/// @param initialGuess 起始 PID (LM 局部最优, 初值影响是否收敛到真解)
/// @param mech         机械常数 (反解全程固定)
/// @param fitMask      参与拟合的参数 (P/I/D/FF 任选); 未选的参数固定为 initialGuess 值
/// @param length       曲线点数 (须与 target 生成时一致)
/// @param duration     时间范围秒 (须与 target 生成时一致)
/// @return 反解结果; 输入非法或迭代未收敛返回 nil 或 converged=NO
- (nullable PIDReverseSolveResult *)solveFromTargetCurve:(NSArray<NSNumber *> *)target
                                            initialGuess:(PIDValues *)initialGuess
                                           mechConstants:(BFMechConstants *)mech
                                                  fitMask:(PIDReverseFitMask)fitMask
                                                   length:(NSInteger)length
                                                 duration:(double)duration;

@end

NS_ASSUME_NONNULL_END
