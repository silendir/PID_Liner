//
//  PIDFFTProcessor.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  FFT信号处理 - 使用Accelerate vDSP框架
//

#ifndef PIDFFTProcessor_h
#define PIDFFTProcessor_h

#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>  // 用于vDSP_Length等类型

NS_ASSUME_NONNULL_BEGIN

/**
 * FFT处理器
 * 使用Apple Accelerate框架的vDSP进行高性能FFT计算
 * 对应Python: numpy.fft
 */
@interface PIDFFTProcessor : NSObject

/**
 * 执行一维复数FFT
 * @param realInput 实部输入数组
 * @param imagInput 虚部输入数组（可以为nil，表示虚部全为0）
 * @param length 输入长度（必须是2的幂次）
 * @return 包含FFT结果的字典 @{@"real": 实部数组, @"imag": 虚部数组}
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)fftWithReal:(NSArray<NSNumber *> *)realInput
                                                            imag:(nullable NSArray<NSNumber *> *)imagInput
                                                          length:(vDSP_Length)length;

/**
 * 执行一维复数IFFT（逆FFT）
 * @param realInput 频域实部输入
 * @param imagInput 频域虚部输入
 * @param length 输入长度（必须是2的幂次）
 * @return 包含IFFT结果的字典 @{@"real": 实部数组, @"imag": 虚部数组}
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)ifftWithReal:(NSArray<NSNumber *> *)realInput
                                                             imag:(NSArray<NSNumber *> *)imagInput
                                                           length:(vDSP_Length)length;

/**
 * 执行实数FFT（更高效的版本，当输入只有实数时使用）
 * @param input 实数输入数组
 * @param length 输入长度（必须是2的幂次）
 * @return FFT结果的实部（频域）
 */
- (NSArray<NSNumber *> *)realFFT:(NSArray<NSNumber *> *)input length:(vDSP_Length)length;

/**
 * 生成FFT频率数组
 * 对应Python: numpy.fft.fftfreq
 * @param length FFT长度
 * @param dt 采样间隔（秒）
 * @return 频率数组（Hz）
 */
- (NSArray<NSNumber *> *)fftfreqWithLength:(vDSP_Length)length
                                         dt:(double)dt;

/**
 * 计算下一个大于等于n的2的幂次
 * 用于FFT padding
 * @param n 输入值
 * @return 2的幂次值
 */
+ (vDSP_Length)nextPowerOfTwo:(vDSP_Length)n;

/**
 * 复数乘法（逐元素）
 * 对应Python: a * b (复数数组)
 * @param real1 第一个复数的实部
 * @param imag1 第一个复数的虚部
 * @param real2 第二个复数的实部
 * @param imag2 第二个复数的虚部
 * @return @{@"real": 结果实部, @"imag": 结果虚部}
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexMultiplyReal1:(NSArray<NSNumber *> *)real1
                                                                    imag1:(NSArray<NSNumber *> *)imag1
                                                                     real2:(NSArray<NSNumber *> *)real2
                                                                     imag2:(NSArray<NSNumber *> *)imag2;

/**
 * 复数共轭
 * 对应Python: np.conj()
 * @param real 输入实部
 * @param imag 输入虚部
 * @return @{@"real": 共轭后实部, @"imag": 共轭后虚部}
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexConjugateWithReal:(NSArray<NSNumber *> *)real
                                                                        imag:(NSArray<NSNumber *> *)imag;

/**
 * 复数除法（逐元素，支持实数分母）
 * 用于计算 G * Hcon / (H * Hcon + 1./sn)
 * @param numerReal 分子实部
 * @param numerImag 分子虚部
 * @param denomReal 分母实部
 * @param denomImag 分母虚部（可以为nil，表示实数分母）
 * @return @{@"real": 结果实部, @"imag": 结果虚部}
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexDivideNumerReal:(NSArray<NSNumber *> *)numerReal
                                                                 numerImag:(NSArray<NSNumber *> *)numerImag
                                                                 denomReal:(NSArray<NSNumber *> *)denomReal
                                                                 denomImag:(nullable NSArray<NSNumber *> *)denomImag;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDFFTProcessor_h */
