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
 * @param pGain PID的P增益值（从CSV头解析得到，固定值）
 * @return 堆叠数据对象
 */
+ (instancetype)stackFromData:(PIDCSVData *)data
                    axisIndex:(NSInteger)axisIndex
                  windowSize:(NSInteger)windowSize
                    overlap:(double)overlap
                       pGain:(double)pGain;

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
@property (nonatomic, assign) double sampleRate;      // 采样率 (Hz) - 🔥 新增：用于动态计算responseLen

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

/**
 * 生成Hanning窗函数
 * 对应Python: np.hanning(length)
 *
 * @param length 窗口长度
 * @return 窗函数数组
 */
+ (NSArray<NSNumber *> *)hanningWindowWithLength:(NSInteger)length;

#pragma mark - 特征提取

/**
 * 从阶跃响应曲线提取时域特征
 * 用于诊断和评分
 *
 * @param stepResponse 阶跃响应曲线（加权平均后的单条曲线）
 * @param sampleRate 采样率 (Hz)
 * @return 时域特征对象
 */
+ (PIDResponseFeatures *)extractFeaturesFromResponse:(NSArray<NSNumber *> *)stepResponse
                                          sampleRate:(double)sampleRate;

#pragma mark - 数据预处理

/**
 * 时间轴均匀化插值
 * 对应Python: equalize_data()
 *
 * 将不均匀采样的数据插值到均匀时间轴
 *
 * @param originalTime 原始时间数组（可能不均匀）
 * @param data 要插值的数据数组
 * @param targetSampleRate 目标采样率 (Hz)，0表示保持原始点数
 * @return 插值后的数据数组
 */
+ (NSArray<NSNumber *> *)equalizeDataWithTime:(NSArray<NSNumber *> *)originalTime
                                         data:(NSArray<NSNumber *> *)data
                              targetSampleRate:(double)targetSampleRate;

#pragma mark - 数据分离 (Mask)

/**
 * 计算低/高输入mask
 * 对应Python: low_high_mask(signal, threshold)
 *
 * 将窗口按最大输入值分为低输入组和/高输入组
 * low[i] = 1.0 if maxInArray[i] <= threshold, else 0.0
 * high[i] = 1.0 if maxInArray[i] > threshold, else 0.0
 *
 * 如果高输入窗口数 < 10，则high全设为0（数据太少，忽略）
 *
 * @param maxInArray 每个窗口的最大输入值 (max_in)
 * @param threshold 阈值（单位：°/s）
 * @return @{@"low": lowMask, @"high": highMask}
 */
+ (NSDictionary<NSString *, NSArray<NSNumber *> *> *)lowHighMask:(NSArray<NSNumber *> *)maxInArray
                                                      threshold:(double)threshold;

#pragma mark - 加权平均

/**
 * 加权模式平均 - 从多个响应中提取代表性曲线
 * 对应Python: weighted_mode_avr()
 *
 * 使用2D直方图统计响应分布，提取最可能的响应曲线
 *
 * @param stepResponse 阶跃响应矩阵 [窗口数][响应点数]
 * @param avgTime 每个窗口的平均时间（保留用于API兼容，实际未使用）
 * @param dataMask 数据mask (0或1的数组)，与windowCount长度相同
 *                 mask[i] = 1 表示保留第i个窗口的数据
 *                 mask[i] = 0 表示丢弃第i个窗口的数据
 * @param vertRange 响应值的垂直范围 [min, max]
 * @param vertBins 垂直方向分箱数量
 * @param sampleRate 实际采样率 (Hz)，用于计算正确的时间轴
 * @return 加权平均后的响应曲线
 */
+ (NSArray<NSNumber *> *)weightedModeAverageWithStepResponse:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                                   avgTime:(NSArray<NSNumber *> *)avgTime
                                                  dataMask:(NSArray<NSNumber *> *)dataMask
                                                vertRange:(NSArray<NSNumber *> *)vertRange
                                                 vertBins:(NSInteger)vertBins
                                              sampleRate:(double)sampleRate;

/**
 * 加权模式平均 - 兼容旧版本（全部窗口权重为1）
 * @deprecated 使用 dataMask 版本代替
 */
+ (NSArray<NSNumber *> *)weightedModeAverageWithStepResponse:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                                   avgTime:(NSArray<NSNumber *> *)avgTime
                                                  maxInput:(NSArray<NSNumber *> *)maxInput
                                                vertRange:(NSArray<NSNumber *> *)vertRange
                                                 vertBins:(NSInteger)vertBins;

#pragma mark - 辅助方法（Python算法对齐）

/**
 * 生成linspace序列，匹配Python的np.linspace
 * np.linspace(a, b, n) 返回 n 个点，从 a 到 b（包含两端）
 * @param start 起始值
 * @param end 结束值
 * @param count 点的数量
 * @return 均匀分布的数值数组
 */
+ (NSArray<NSNumber *> *)linspaceFrom:(double)start to:(double)end count:(NSInteger)count;

/**
 * 构建histogram2d，完全匹配Python的np.histogram2d
 *
 * @param times 展平的时间数组 [N]
 * @param values 展平的值数组 [N]
 * @param weights 展平的权重数组 [N]
 * @param timeMin 时间范围最小值
 * @param timeMax 时间范围最大值
 * @param valueMin 值范围最小值
 * @param valueMax 值范围最大值
 * @param timeBinsCount 时间箱数量
 * @param vertBinsCount 值箱数量
 * @return 转置后的hist2d [vertBins, timeBins]，需要调用者释放
 */
+ (float *)buildHistogram2D:(NSArray<NSNumber *> *)times
                     values:(NSArray<NSNumber *> *)values
                    weights:(NSArray<NSNumber *> *)weights
                   timeMin:(double)timeMin
                   timeMax:(double)timeMax
                  valueMin:(double)valueMin
                  valueMax:(double)valueMax
            timeBinsCount:(NSInteger)timeBins
            vertBinsCount:(NSInteger)vertBins;

#pragma mark - 响应质量过滤 (对应Python的resp_quality)

/**
 * 计算窗口响应与参考响应的平均绝对偏差
 * 对应Python: (np.abs(spec_sm - resp_sm[0]).mean(axis=1))
 *
 * @param windowResp 单个窗口的阶跃响应数据
 * @param referenceResp 参考响应（通常是初步计算的平均响应）
 * @return 平均绝对偏差
 */
+ (double)meanAbsoluteDeviation:(NSArray<NSNumber *> *)windowResp
                   fromReference:(NSArray<NSNumber *> *)referenceResp;

/**
 * 计算响应质量mask
 * 对应Python: resp_quality = -to_mask((abs(spec_sm - resp_sm[0]).mean(axis=1)).clip(0.5-1e-9, 0.5)) + 1
 *
 * 逻辑：
 * - 计算每个窗口与参考响应的平均偏差
 * - 偏差 <= 0.5: quality = 1.0 (保留)
 * - 偏差 > 0.5: quality = 0.0 (过滤)
 *
 * @param stepResponse 所有窗口的阶跃响应
 * @param referenceResp 参考响应（通常是初步计算的平均响应）
 * @return 质量mask数组，1.0表示保留，0.0表示过滤
 */
+ (NSArray<NSNumber *> *)calculateResponseQualityMask:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                     referenceResponse:(NSArray<NSNumber *> *)referenceResp;

/**
 * 组合两个mask（按元素相乘）
 * 对应Python: mask1 * mask2
 *
 * @param mask1 第一个mask
 * @param mask2 第二个mask
 * @return 组合后的mask
 */
+ (NSArray<NSNumber *> *)combineMasks:(NSArray<NSNumber *> *)mask1
                            withMask:(NSArray<NSNumber *> *)mask2;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDTraceAnalyzer_h */
