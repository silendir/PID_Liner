//
//  BFPIDToSecondOrderMapper.h
//  PID_Liner
//
//  PID → 二阶系统参数的解析映射器（基于控制理论推导）
//  依据: 技术验证Demo/前向模型控制理论推导.md
//
//  修复 PIDRecommendationEngine 的 3 个映射错误:
//    ① P 应影响 ωn（开方关系），而非增益 K
//    ② D 应正比影响 ζ（同时被 P 开方修正），而非 sqrt 关系
//    ③ FF 不进 ωn，作为独立前向通道叠加
//    ④ 补回 I 项（积分时间常数 τ_I = Kp/Ki，影响稳态收敛）
//
//  设计原则（遵循项目 CLAUDE.md）:
//    - 纯函数风格: 输入不可变模型 → 输出新模型
//    - 不硬编码: 映射关系全部来自特征方程解析推导
//    - 健壮性: 全部输入做边界保护
//

#import <Foundation/Foundation.h>
#import "PIDRecommendationEngine.h"  // PIDValues 数据模型（复用，不重定义）

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 二阶系统参数模型（不可变）

/// 二阶系统参数 + I/FF 附加项（映射输出）
/// 数学依据: 前向模型控制理论推导.md §六
@interface BFForwardModelParams : NSObject

// 二阶主参数（决定瞬态形状）
@property (nonatomic, assign) double gain;             ///< K (稳态增益，二阶闭环 DC 增益≈1)
@property (nonatomic, assign) double naturalFreq;      ///< ωn (rad/s，自然频率)
@property (nonatomic, assign) double dampingRatio;     ///< ζ (阻尼比)

// I 项附加（决定稳态尾巴收敛速度）
@property (nonatomic, assign) double integralTau;      ///< τ_I = Kp/Ki (秒)；0 表示无 I 作用

// FF 项附加（决定上升阶段跟手度）
@property (nonatomic, assign) double feedforwardScale; ///< FF 瞬态叠加系数 [0,1]

@end

#pragma mark - 映射器

/// PID(P,I,D,FF) → 二阶系统参数的解析映射
///
/// 核心映射公式（推导见控制理论推导.md §2.3, §6.1）:
///   ωn = ωn₀ · √(Kp/Kp₀)
///   ζ  = (ζ₀ · Kd/Kd₀) / √(Kp/Kp₀)
///   τ_I = Kp/Ki
///   FF  = 独立前向叠加
@interface BFPIDToSecondOrderMapper : NSObject

#pragma mark - 单步映射

/// 根据 PID 变化，从基准二阶参数计算新的前向模型参数
/// @param baseParams  基准二阶参数（从实测曲线 fitSecondOrderFromResponse 拟合得到）
/// @param oldPID      基准 PID（对应 baseParams）
/// @param newPID      目标 PID
/// @return 新的前向模型参数（用于生成预测曲线）；输入非法返回 nil
+ (nullable BFForwardModelParams *)mapFromBaseParams:(BFForwardModelParams *)baseParams
                                              oldPID:(PIDValues *)oldPID
                                              newPID:(PIDValues *)newPID;

#pragma mark - 预测曲线生成

/// 根据前向模型参数生成预测阶跃响应曲线
/// 包含: 二阶主响应 + I 稳态收敛修正 + FF 前馈瞬态叠加
/// @param params    前向模型参数
/// @param length    曲线点数
/// @param duration  时间范围 (秒)
+ (NSArray<NSNumber *> *)predictedCurveWithParams:(BFForwardModelParams *)params
                                           length:(NSInteger)length
                                         duration:(double)duration;

#pragma mark - 比例关系（供单元测试验证物理方向）

/// P 变化对 ωn 的比例因子: √(pRatio)
+ (double)omegaRatioFromPRatio:(double)pRatio;

/// P 变化对 ζ 的比例因子: 1/√(pRatio)
+ (double)dampingRatioFromPRatio:(double)pRatio;

/// D 变化对 ζ 的比例因子: dRatio
+ (double)dampingRatioFromDRatio:(double)dRatio;

@end

NS_ASSUME_NONNULL_END