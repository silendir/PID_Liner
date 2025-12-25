//
//  PIDTraceAnalyzer.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID追踪分析器 - 对应Python PID-Analyzer的Trace类
//

#ifndef PIDTraceAnalyzer_h
#define PIDTraceAnalyzer_h

#import <Foundation/Foundation.h>
#import "PIDDataModels.h"

NS_ASSUME_NONNULL_BEGIN

@class PIDCSVData;
@class PIDWienerDeconvolution;
@class PIDFFTProcessor;

#pragma mark - 堆叠窗口数据

/**
 * 堆叠窗口数据
 * 对应Python中的stacks字典
 */
@interface PIDStackData : NSObject

// 输入信号（PID环路输入）
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *input;

// 输出信号（陀螺仪）
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *gyro;

// 油门
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *throttle;

// 时间
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *time;

// 窗口数量
@property (nonatomic, readonly) NSInteger windowCount;

// 每个窗口的长度
@property (nonatomic, readonly) NSInteger windowLength;

/**
 * 创建堆叠数据
 * @param data CSV数据
 * @param windowSize 窗口大小（样本点数）
 * @param overlap 重叠比例（0-1）
 * @return 堆叠数据对象
 */
+ (instancetype)stackFromData:(PIDCSVData *)data
                  windowSize:(NSInteger)windowSize
                    overlap:(double)overlap;

/**
 * 创建指定轴的堆叠数据
 * @param data CSV数据
 * @param axisIndex 轴索引 (0=Roll, 1=Pitch, 2=Yaw)
 * @param windowSize 窗口大小（样本点数）
 * @param overlap 重叠比例（0-1）
 * @return 堆叠数据对象
 */
+ (instancetype)stackFromData:(PIDCSVData *)data
                    axisIndex:(NSInteger)axisIndex
                  windowSize:(NSInteger)windowSize
                    overlap:(double)overlap;

@end

#pragma mark - 响应分析结果

/**
 * 阶跃响应分析结果
 * 对应Python stack_response()的返回值
 */
@interface PIDResponseResult : NSObject

// 响应曲线（累积和后的阶跃响应）
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *stepResponse;

// 平均时间
@property (nonatomic, strong) NSArray<NSNumber *> *avgTime;

// 平均输入幅度
@property (nonatomic, strong) NSArray<NSNumber *> *avgInput;

// 最大输入幅度
@property (nonatomic, strong) NSArray<NSNumber *> *maxInput;

// 最大油门
@property (nonatomic, strong) NSArray<NSNumber *> *maxThrottle;

@end

#pragma mark - 频谱分析结果

/**
 * 频谱分析结果
 * 对应Python spectrum()的返回值
 */
@interface PIDSpectrumResult : NSObject

// 频率数组 (Hz)
@property (nonatomic, strong) NSArray<NSNumber *> *frequencies;

// 频谱幅度 [频率窗口][频率点]
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *spectrum;

@end

#pragma mark - PID追踪分析器

/**
 * PID追踪分析器
 * 对应Python PID-Analyzer的Trace类
 *
 * 核心功能：
 * - 计算PID环路输入 (pid_in)
 * - 分析阶跃响应 (stack_response)
 * - 噪声频谱分析 (spectrum)
 */
@interface PIDTraceAnalyzer : NSObject

// 分析配置
@property (nonatomic, assign) double dt;              // 采样间隔 (秒)
@property (nonatomic, assign) double cutFreq;         // 截止频率 (Hz)
@property (nonatomic, assign) double pScale;          // P缩放因子 (Betaflight: 0.032029)
@property (nonatomic, assign) NSInteger responseLen; // 响应长度 (样本点数)

// 维纳反卷积处理器
@property (nonatomic, strong, readonly) PIDWienerDeconvolution *wienerDeconvolution;

// FFT处理器
@property (nonatomic, strong, readonly) PIDFFTProcessor *fftProcessor;

/**
 * 默认初始化
 */
- (instancetype)init;

/**
 * 使用指定参数初始化
 * @param sampleRate 采样率 (Hz)
 * @param cutFreq 截止频率 (Hz)
 */
- (instancetype)initWithSampleRate:(double)sampleRate
                           cutFreq:(double)cutFreq;

#pragma mark - PID环路输入计算

/**
 * 计算PID环路输入
 * 对应Python: pid_in(pval, gyro, pidp)
 * pidin = gyro + pval / (0.032029 * pidp)
 *
 * @param pval P项输出值
 * @param gyro 陀螺仪值
 * @param pidP PID的P参数
 * @return PID环路输入值
 */
- (double)pidInWithPVal:(double)pval
                    gyro:(double)gyro
                    pidP:(double)pidP;

/**
 * 批量计算PID环路输入
 * @param pvalArray P项值数组
 * @param gyroArray 陀螺仪值数组
 * @param pidP PID的P参数
 * @return PID输入数组
 */
- (NSArray<NSNumber *> *)pidInWithPValArray:(NSArray<NSNumber *> *)pvalArray
                                    gyroArray:(NSArray<NSNumber *> *)gyroArray
                                         pidP:(double)pidP;

#pragma mark - 响应分析

/**
 * 计算阶跃响应
 * 对应Python: stack_response(stacks, window)
 *
 * @param stacks 堆叠窗口数据
 * @param window 窗函数数组
 * @return 响应分析结果
 */
- (PIDResponseResult *)stackResponse:(PIDStackData *)stacks
                             window:(NSArray<NSNumber *> *)window;

/**
 * 生成Tukey窗函数
 * 对应Python: tukeywin(len, alpha=0.5)
 *
 * @param length 窗口长度
 * @param alpha Alpha参数 (0-1)
 * @return 窗函数数组
 */
- (NSArray<NSNumber *> *)tukeyWindowWithLength:(NSInteger)length
                                          alpha:(double)alpha;

#pragma mark - 频谱分析

/**
 * 计算噪声频谱
 * 对应Python: spectrum(time, traces)
 *
 * @param time 时间数组
 * @param traces 追踪数据 [窗口数][样本点数]
 * @return 频谱分析结果
 */
- (PIDSpectrumResult *)spectrumWithTime:(NSArray<NSNumber *> *)time
                                traces:(NSArray<NSArray<NSNumber *> *> *)traces;

/**
 * 生成Tukey窗函数
 * @param length 窗口长度
 * @param alpha Alpha参数
 * @return 窗函数数组
 */
+ (NSArray<NSNumber *> *)tukeyWindowWithLength:(NSInteger)length
                                          alpha:(double)alpha;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDTraceAnalyzer_h */
