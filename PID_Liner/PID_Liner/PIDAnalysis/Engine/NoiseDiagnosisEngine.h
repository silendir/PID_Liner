//
//  NoiseDiagnosisEngine.h
//  PID_Liner
//
//  噪声频带诊断引擎(频带诊断v1) —— TPA/AG 调优需求识别
//
//  方法论: 分析文档/TPA-AG识别方法论-频带分析v1.md
//  六轮实测验证: 2026-10-19 吴飞行迭代 BBL(分析脚本 分析文档/脚本/黑盒频带分析/)
//
//  纯新增引擎: 只读输入(频谱+油门序列),不改任何现有类。判据阈值 v1 单案例初值,
//  诊断输出必须带"阈值待多机型校准"脚注。
//

#import <Foundation/Foundation.h>
#import "PIDTraceAnalyzer.h"

NS_ASSUME_NONNULL_BEGIN

/// 诊断结果(噪声图诊断卡的数据源)
@interface NoiseDiagnosisResult : NSObject

// ---- 频带能量占比(%, 高/低油门各一组) ----
@property (nonatomic, assign) double loPidBandPct;    // 低油门 30~150Hz (PID/D 工作区, TPA 管辖)
@property (nonatomic, assign) double hiPidBandPct;    // 高油门同上
@property (nonatomic, assign) double loMechBandPct;   // 低油门 150~300Hz (机械)
@property (nonatomic, assign) double hiMechBandPct;   // 高油门同上

// ---- 数据覆盖 ----
@property (nonatomic, assign) NSInteger totalWindows;    // 频谱窗口总数
@property (nonatomic, assign) NSInteger hiThrottleWindows; // 高油门(≥bp)窗口数
@property (nonatomic, assign) NSInteger jumpFrames;      // 油门突变帧数(|Δ油门(100ms)|>阈值)
@property (nonatomic, assign) NSInteger totalFrames;     // 总帧数
@property (nonatomic, assign) double bpPWM;              // TPA breakpoint (PWM)

// ---- 判读结论(人话,诊断卡直接显示) ----
@property (nonatomic, copy) NSString *tpaVerdict;    // TPA 三态: 不足/过度/保持现状
@property (nonatomic, copy) NSString *mechVerdict;   // 机械频段: 干净/异常
@property (nonatomic, copy) NSString *agVerdict;     // AG: 可诊断结论 或 数据盲区提示
/// 补飞科目引导等建议行(诊断卡逐行显示)
@property (nonatomic, strong) NSArray<NSString *> *adviceLines;

@end

@interface NoiseDiagnosisEngine : NSObject

/// 频带诊断主入口
/// @param spectrum 三轴之一的频谱结果(每 stacked 窗口一行)
/// @param throttlePerWindow 每窗口油门均值(PWM),与 spectrum.spectrum 一维对齐
/// @param throttleSeq 帧级油门序列(rcCommand[3] 全列,突变帧计数用)
/// @param bpPWM TPA breakpoint(PWM 原值,如 1350)
+ (NoiseDiagnosisResult *)diagnoseWithSpectrum:(PIDSpectrumResult *)spectrum
                             throttlePerWindow:(NSArray<NSNumber *> *)throttlePerWindow
                                   throttleSeq:(NSArray<NSNumber *> *)throttleSeq
                                         bpPWM:(double)bpPWM;

/// 油门突变帧计数(独立入口,无频谱时也可用)
/// 帧判据: |thr[i] - thr[i-5]| > jumpThreshold (约100ms窗口)
+ (NSInteger)jumpFramesWithThrottleSeq:(NSArray<NSNumber *> *)throttleSeq
                        jumpThreshold:(double)jumpThreshold;

@end

NS_ASSUME_NONNULL_END
