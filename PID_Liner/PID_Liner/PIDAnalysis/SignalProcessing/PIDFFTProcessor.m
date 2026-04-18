//
//  PIDFFTProcessor.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  FFT信号处理实现 - 使用Accelerate vDSP
//  🔧 修复: 正确处理vDSP的打包格式，对齐numpy FFT输出
//

#import "PIDFFTProcessor.h"
#import <Accelerate/Accelerate.h>

@implementation PIDFFTProcessor

#pragma mark - Public Methods

/**
 * vDSP打包格式说明 (n=8为例):
 * realp: [DC, f1r, f2r, f3r, Nyq,  0,   0,   0  ]
 * imagp: [0,  f1i, f2i, f3i, 0,   f3i, f2i, f1i]
 *
 * numpy标准格式:
 * [DC, f1r+f1i*i, f2r+f2i*i, f3r+f3i*i, Nyq, f3r-f3i*i, f2r-f2i*i, f1r-f1i*i]
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)fftWithReal:(NSArray<NSNumber *> *)realInput
                                                            imag:(nullable NSArray<NSNumber *> *)imagInput
                                                          length:(vDSP_Length)length {
    if (!realInput || length == 0) {
        return @{};
    }

    // 确保长度是2的幂次
    vDSP_Length n = [[self class] nextPowerOfTwo:length];

    // 准备输入数据
    float *inputReal = (float *)malloc(n * sizeof(float));
    float *inputImag = (float *)malloc(n * sizeof(float));

    for (vDSP_Length i = 0; i < length; i++) {
        inputReal[i] = [realInput[i] floatValue];
        inputImag[i] = imagInput ? [imagInput[i] floatValue] : 0.0f;
    }
    for (vDSP_Length i = length; i < n; i++) {
        inputReal[i] = 0.0f;
        inputImag[i] = 0.0f;
    }

    // 创建FFT setup
    vDSP_Length log2n = (vDSP_Length)log2(n);
    FFTSetup fftSetup = vDSP_create_fftsetup(log2n, FFT_RADIX2);

    // 创建split complex格式
    DSPSplitComplex inputComplex;
    inputComplex.realp = inputReal;
    inputComplex.imagp = inputImag;

    // 🔧 修复: 只执行FFT_FORWARD，不要执行FFT_INVERSE
    vDSP_fft_zrip(fftSetup, &inputComplex, 1, log2n, FFT_FORWARD);

    // 🔧 修复: 将vDSP打包格式转换为numpy标准格式
    // vDSP打包格式需要正确解包
    NSMutableArray<NSNumber *> *outputReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *outputImag = [NSMutableArray arrayWithCapacity:n];

    // DC分量
    [outputReal addObject:@(inputComplex.realp[0])];
    [outputImag addObject:@0.0f];

    // 正频率分量 f1 到 f(n/2-1)
    vDSP_Length halfN = n / 2;
    for (vDSP_Length i = 1; i < halfN; i++) {
        [outputReal addObject:@(inputComplex.realp[i])];
        [outputImag addObject:@(inputComplex.imagp[i])];
    }

    // Nyquist分量
    [outputReal addObject:@(inputComplex.imagp[0])];
    [outputImag addObject:@0.0f];

    // 负频率分量 f(-n/2+1) 到 f(-1)
    for (vDSP_Length i = halfN - 1; i > 0; i--) {
        [outputReal addObject:@(inputComplex.realp[i])];      // 实部相同
        [outputImag addObject:@(-inputComplex.imagp[i])];     // 虚部取反（共轭）
    }

    // 清理
    vDSP_destroy_fftsetup(fftSetup);
    free(inputReal);
    free(inputImag);

    return @{@"real": outputReal, @"imag": outputImag};
}

/**
 * IFFT - 逆傅里叶变换
 * 🔧 修复: 将numpy标准格式转换为vDSP打包格式，然后执行IFFT
 */
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)ifftWithReal:(NSArray<NSNumber *> *)realInput
                                                             imag:(NSArray<NSNumber *> *)imagInput
                                                           length:(vDSP_Length)length {
    if (!realInput || length == 0) {
        return @{};
    }
    
    vDSP_Length n = [[self class] nextPowerOfTwo:length];
    
    // 准备vDSP打包格式的输入
    float *packedReal = (float *)calloc(n, sizeof(float));
    float *packedImag = (float *)calloc(n, sizeof(float));
    
    // 将numpy标准格式转换为vDSP打包格式
    // numpy: [DC, f1, f2, ..., f(n/2-1), Nyq, f(-n/2+1), ..., f(-1)]
    // vDSP:   realp[0]=DC, imagp[0]=Nyq, realp[1]=f1r, imagp[1]=f1i, ...
    
    packedReal[0] = [realInput[0] floatValue];  // DC分量
    
    vDSP_Length halfN = n / 2;
    
    // 正频率分量
    for (vDSP_Length i = 1; i < halfN; i++) {
        if (i < realInput.count) {
            packedReal[i] = [realInput[i] floatValue];
            packedImag[i] = (imagInput && i < imagInput.count) ? [imagInput[i] floatValue] : 0.0f;
        }
    }
    
    // Nyquist分量
    if (halfN < realInput.count) {
        packedImag[0] = [realInput[halfN] floatValue];  // vDSP将Nyquist存在imagp[0]
    }
    
    // 负频率分量（共轭对称，用于vDSP的打包格式）
    for (vDSP_Length i = 1; i < halfN; i++) {
        vDSP_Length numpyIdx = n - i;  // 对应的负频率索引
        if (numpyIdx < realInput.count) {
            // 负频率是正频率的共轭，vDSP打包格式会自动处理
            // 这里不需要额外设置，vDSP会根据正频率计算
        }
    }
    
    // 创建FFT setup
    vDSP_Length log2n = (vDSP_Length)log2(n);
    FFTSetup fftSetup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
    
    DSPSplitComplex inputComplex;
    inputComplex.realp = packedReal;
    inputComplex.imagp = packedImag;
    
    // 执行IFFT
    vDSP_fft_zrip(fftSetup, &inputComplex, 1, log2n, FFT_INVERSE);

    // 🔥 关键修复: 缩放因子应该是 1/n，而不是 0.5/n
    // Python的np.fft.ifft使用默认norm='backward'，缩放因子为 1/n
    // 这修复了iOS输出约为Python一半的问题
    float scale = 1.0f / n;
    vDSP_vsmul(inputComplex.realp, 1, &scale, inputComplex.realp, 1, n);
    vDSP_vsmul(inputComplex.imagp, 1, &scale, inputComplex.imagp, 1, n);
    
    // 转换为输出（只取实部，因为IFFT结果应该是实数）
    NSMutableArray<NSNumber *> *outputReal = [NSMutableArray arrayWithCapacity:length];
    NSMutableArray<NSNumber *> *outputImag = [NSMutableArray arrayWithCapacity:length];
    
    for (vDSP_Length i = 0; i < length && i < n; i++) {
        [outputReal addObject:@(inputComplex.realp[i])];
        [outputImag addObject:@(inputComplex.imagp[i])];
    }
    
    vDSP_destroy_fftsetup(fftSetup);
    free(packedReal);
    free(packedImag);
    
    return @{@"real": outputReal, @"imag": outputImag};
}

- (NSArray<NSNumber *> *)realFFT:(NSArray<NSNumber *> *)input length:(vDSP_Length)length {
    // 对于实数输入，使用标准的复数FFT（虚部为0）
    // 实际上vDSP有专门的实数FFT，但这里使用复数版本简化实现
    NSDictionary *result = [self fftWithReal:input imag:nil length:length];
    return result[@"real"] ?: @[];
}

- (NSArray<NSNumber *> *)fftfreqWithLength:(vDSP_Length)length dt:(double)dt {
    // 对应numpy.fft.fftfreq
    // 生成频率数组: [0, 1, ...,   n/2-1, -n/2, ..., -1] / (d*t)
    NSMutableArray<NSNumber *> *freqs = [NSMutableArray arrayWithCapacity:length];

    vDSP_Length n = length;
    NSInteger halfN = (n + 1) / 2;

    // 正频率部分
    for (vDSP_Length i = 0; i < halfN; i++) {
        [freqs addObject:@(i / (dt * n))];
    }

    // 负频率部分
    for (vDSP_Length i = halfN; i < n; i++) {
        [freqs addObject:@((i - n) / (dt * n))];
    }

    return [freqs copy];
}

+ (vDSP_Length)nextPowerOfTwo:(vDSP_Length)n {
    // 计算下一个大于等于n的2的幂次
    vDSP_Length power = 1;
    while (power < n) {
        power *= 2;
    }
    return power;
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexMultiplyReal1:(NSArray<NSNumber *> *)real1
                                                                    imag1:(NSArray<NSNumber *> *)imag1
                                                                     real2:(NSArray<NSNumber *> *)real2
                                                                     imag2:(NSArray<NSNumber *> *)imag2 {
    if (!real1 || !real2 || real1.count != real2.count) {
        return @{};
    }

    vDSP_Length n = (vDSP_Length)real1.count;

    // 转换为C数组
    float *r1 = (float *)malloc(n * sizeof(float));
    float *i1 = (float *)malloc(n * sizeof(float));
    float *r2 = (float *)malloc(n * sizeof(float));
    float *i2 = (float *)malloc(n * sizeof(float));

    for (vDSP_Length j = 0; j < n; j++) {
        r1[j] = [real1[j] floatValue];
        i1[j] = imag1 ? [imag1[j] floatValue] : 0.0f;
        r2[j] = [real2[j] floatValue];
        i2[j] = imag2 ? [imag2[j] floatValue] : 0.0f;
    }

    // 结果数组
    float *resultReal = (float *)malloc(n * sizeof(float));
    float *resultImag = (float *)malloc(n * sizeof(float));

    // 复数乘法: (a + bi) * (c + di) = (ac - bd) + (ad + bc)i
    for (vDSP_Length j = 0; j < n; j++) {
        resultReal[j] = r1[j] * r2[j] - i1[j] * i2[j];
        resultImag[j] = r1[j] * i2[j] + i1[j] * r2[j];
    }

    // 转换为输出
    NSMutableArray<NSNumber *> *outReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *outImag = [NSMutableArray arrayWithCapacity:n];

    for (vDSP_Length j = 0; j < n; j++) {
        [outReal addObject:@(resultReal[j])];
        [outImag addObject:@(resultImag[j])];
    }

    free(r1); free(i1); free(r2); free(i2);
    free(resultReal); free(resultImag);

    return @{@"real": outReal, @"imag": outImag};
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexConjugateWithReal:(NSArray<NSNumber *> *)real
                                                                        imag:(NSArray<NSNumber *> *)imag {
    if (!real) {
        return @{};
    }

    vDSP_Length n = (vDSP_Length)real.count;

    // 共轭: (a + bi)* = a - bi
    NSMutableArray<NSNumber *> *conjReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *conjImag = [NSMutableArray arrayWithCapacity:n];

    for (vDSP_Length i = 0; i < n; i++) {
        [conjReal addObject:real[i]];
        if (imag && i < imag.count) {
            // 虚部取负
            [conjImag addObject:@(-[imag[i] floatValue])];
        } else {
            [conjImag addObject:@0.0f];
        }
    }

    return @{@"real": conjReal, @"imag": conjImag};
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)complexDivideNumerReal:(NSArray<NSNumber *> *)numerReal
                                                                 numerImag:(NSArray<NSNumber *> *)numerImag
                                                                 denomReal:(NSArray<NSNumber *> *)denomReal
                                                                 denomImag:(nullable NSArray<NSNumber *> *)denomImag {
    if (!numerReal || !denomReal || numerReal.count != denomReal.count) {
        return @{};
    }

    vDSP_Length n = (vDSP_Length)numerReal.count;

    NSMutableArray<NSNumber *> *resultReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *resultImag = [NSMutableArray arrayWithCapacity:n];

    // 如果分母是实数（没有虚部），简化计算
    if (!denomImag) {
        // (a + bi) / c = a/c + (b/c)i
        for (vDSP_Length i = 0; i < n; i++) {
            float a = [numerReal[i] floatValue];
            float b = numerImag ? [numerImag[i] floatValue] : 0.0f;
            float c = [denomReal[i] floatValue];

            // 避免除以0
            if (fabs(c) < 1e-9f) {
                [resultReal addObject:@0.0f];
                [resultImag addObject:@0.0f];
            } else {
                [resultReal addObject:@(a / c)];
                [resultImag addObject:@(b / c)];
            }
        }
    } else {
        // 完整复数除法: (a + bi) / (c + di) = ((ac + bd) + (bc - ad)i) / (c² + d²)
        for (vDSP_Length i = 0; i < n; i++) {
            float a = [numerReal[i] floatValue];
            float b = numerImag ? [numerImag[i] floatValue] : 0.0f;
            float c = [denomReal[i] floatValue];
            float d = [denomImag[i] floatValue];

            float denom = c * c + d * d;
            if (fabs(denom) < 1e-9f) {
                [resultReal addObject:@0.0f];
                [resultImag addObject:@0.0f];
            } else {
                [resultReal addObject:@((a * c + b * d) / denom)];
                [resultImag addObject:@((b * c - a * d) / denom)];
            }
        }
    }

    return @{@"real": resultReal, @"imag": resultImag};
}

@end
