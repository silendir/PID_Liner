//
//  PIDWienerDeconvolution.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  维纳反卷积算法 - PID分析的核心数学算法
//

#ifndef PIDWienerDeconvolution_h
#define PIDWienerDeconvolution_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 维纳反卷积结果
 */
@interface PIDWienerResult : NSObject

// 反卷积后的结果（二维数组：[窗口数][采样点数]）
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *data;

// 结果的维度
@property (nonatomic, assign) NSInteger rowCount;
@property (nonatomic, assign) NSInteger columnCount;

@end

/**
 * 维纳反卷积处理器
 * 对应Python PID-Analyzer中的wiener_deconvolution方法
 *
 * 数学原理：
 * 从系统的输入和输出信号中反推系统的冲激响应
 * 使用维纳滤波器在频域进行反卷积
 */
@interface PIDWienerDeconvolution : NSObject

/**
 * 采样间隔（秒）
 * 对应Python: self.dt
 */
@property (nonatomic, assign) double dt;

/**
 * 执行维纳反卷积
 * @param inputSignal 输入信号（PID环路输入），二维数组 [窗口数][采样点数]
 * @param outputSignal 输出信号（陀螺仪），二维数组 [窗口数][采样点数]
 * @param cutFreq 截止频率 (Hz)
 * @return 反卷积结果
 */
- (PIDWienerResult *)deconvolveWithInput:(NSArray<NSArray<NSNumber *> *> *)inputSignal
                                output:(NSArray<NSArray<NSNumber *> *> *)outputSignal
                                cutFreq:(double)cutFreq;

/**
 * 数据归一化到 [0, 1]
 * 对应Python: to_mask()
 * @param clipped 输入数据（一维数组）
 * @return 归一化后的数组
 */
- (NSArray<NSNumber *> *)normalizeToMask:(NSArray<NSNumber *> *)clipped;

/**
 * 高斯滤波（1D）
 * 对应Python: scipy.ndimage.filters.gaussian_filter1d
 * @param data 输入数据
 * @param sigma 高斯核标准差
 * @return 滤波后的数据
 */
- (NSArray<NSNumber *> *)gaussianFilter:(NSArray<NSNumber *> *)data sigma:(double)sigma;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDWienerDeconvolution_h */
