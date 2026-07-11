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

#pragma mark - 滤波配置 (3.3a biquad / 3.3b PT1链: 模拟 BF gyro 低通对响应曲线的涂抹)

/// BF 信号链低通配置
/// 物理动机: 真实 BBL 记录的 gyro 已被 BF gyro 通道低通涂抹, 上升沿变缓;
///           纯二阶 forward 无滤波 → 为匹配变缓上升沿只能降 ωn → P 反解偏低 40%
///           forward 出纯二阶曲线后再过同一低通链, 即可消除该模型偏差
///
/// 两条路径 (forward 内 PT1链优先, 否则 biquad, 否则不滤):
///   - 3.3a biquad: 单级 RBJ cookbook (DC增益=1, 合成对照资产, 保留)
///   - 3.3b PT1链: BF 真实 gyro 通道 (type=0 PT1, 3级串联, 来自 BBL header)
///                 001.bbl 实测: gyro_lowpass=200 / lowpass2=250 / dyn=200-500
@interface BFFilterConfig : NSObject

@property (nonatomic, assign) double gyroLowpassHz;  ///< [3.3a biquad] gyro 低通截止 Hz; 0=跳过biquad
@property (nonatomic, assign) double dtermLowpassHz; ///< dterm 低通 (预留, 当前未作用于输出)
@property (nonatomic, assign) double q;              ///< [3.3a biquad] 品质因数; Butterworth=0.7071

@property (nonatomic, assign) double gyroPT1Hz;      ///< [3.3b PT1] gyro_lowpass 截止 Hz (001:200); 0=该级跳过
@property (nonatomic, assign) double gyroPT1_2Hz;    ///< [3.3b PT1] gyro_lowpass2 截止 Hz (001:250); 0=跳过
@property (nonatomic, assign) double gyroPT1DynHz;   ///< [3.3b PT1] gyro_lowpass_dyn 截止 Hz (001:200-500随油门, 取定值); 0=跳过

+ (instancetype)noFilter;                              ///< 无滤波 (向后兼容)
+ (instancetype)gyroLowpass:(double)hz;                ///< [3.3a] 单 biquad (Butterworth Q)
+ (instancetype)gyroPT1Chain:(double)h1 h2:(double)h2 dyn:(double)hdyn;  ///< [3.3b] BF真实gyro三级PT1链 (任一 0 跳过该级)

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

/// 带 gyro 低通的 forward (3.3a): 纯二阶阶跃 → biquad 低通 (模拟 BF gyro_lowpass 涂抹)
/// filter=nil 或 gyroLowpassHz=0 时退化为纯二阶 (等价上面的旧接口)
+ (NSArray<NSNumber *> *)forwardCurveWithPID:(PIDValues *)pid
                               mechConstants:(BFMechConstants *)mech
                               filterConfig:(nullable BFFilterConfig *)filter
                                       length:(NSInteger)length
                                     duration:(double)duration;

/// [3.3b-2a] 时域数值积分 forward (物理 PID 闭环, RK4 积分二阶 plant)
///
/// 与解析版 forwardCurveWithPID: 的关系 (验收见 ReverseSolverClosureTests):
///   - 纯 PD (pid.i=0 且 pid.ff=0) 时, 时域积分对齐解析 h(t) (RMSE<1e-4, 验证积分器数学)
///   - I/FF 用物理建模 (I=积分项+anti-windup, FF=阶跃冲激前馈过plant平滑),
///     与解析经验项 (0.3 权重叠加, 见 BFPIDToSecondOrderMapper.m:174-185) 形状不同, 差异记录不阻塞
///   - 2a 阶段: 不替换解析 forward, 反解仍用解析版; 时域版为 2b/2c (dterm 动态) 打基础
///
/// @param filter 可选 gyro 低通链 (与解析版同语义: PT1链 > biquad > 不滤); nil=不滤
+ (NSArray<NSNumber *> *)forwardCurveTimeDomainWithPID:(PIDValues *)pid
                                          mechConstants:(BFMechConstants *)mech
                                          filterConfig:(nullable BFFilterConfig *)filter
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

/// 带 gyro 低通的反解 (3.3a): LM 全程用带滤波 forward (target 与 forward 同滤波, 延迟自抵消)
- (nullable PIDReverseSolveResult *)solveFromTargetCurve:(NSArray<NSNumber *> *)target
                                            initialGuess:(PIDValues *)initialGuess
                                           mechConstants:(BFMechConstants *)mech
                                            filterConfig:(nullable BFFilterConfig *)filter
                                                  fitMask:(PIDReverseFitMask)fitMask
                                                   length:(NSInteger)length
                                                 duration:(double)duration;

@end

NS_ASSUME_NONNULL_END
