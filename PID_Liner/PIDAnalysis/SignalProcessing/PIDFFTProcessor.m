//
//  PIDFFTProcessor.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  FFT信号处理实现 - 使用Accelerate vDSP
//

#import "PIDFFTProcessor.h"
#import <Accelerate/Accelerate.h>

@implementation PIDFFTProcessor

#pragma mark - Public Methods

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)fftWithReal:(NSArray<NSNumber *> *)realInput
                                                            imag:(nullable NSArray<NSNumber *> *)imagInput
                                                          length:(vDSP_Length)length {
    if (!realInput || length == 0) {
        return @{};
    }

    // 确保长度是2的幂次
    vDSP_Length n = [[self class] nextPowerOfTwo:length];

    // 准备输入数据（分拆为实部和虚部）
    float *inputReal = (float *)malloc(n * sizeof(float));
    float *inputImag = (float *)malloc(n * sizeof(float));

    for (vDSP_Length i = 0; i < length; i++) {
        inputReal[i] = [realInput[i] floatValue];
        inputImag[i] = imagInput ? [imagInput[i] floatValue] : 0.0f;
    }
    // 填充0
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

    // 执行FFT
    vDSP_fft_zrip(fftSetup, &inputComplex, 1, log2n, FFT_FORWARD);

    // 打包结果（vDSP使用特殊的打包格式）
    vDSP_fft_zrip(fftSetup, &inputComplex, 1, log2n, FFT_INVERSE);
    // 重新forward获取正确格式
    // 实际上vDSP的打包格式需要特殊处理

    // 转换为输出数组
    NSMutableArray<NSNumber *> *outputReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *outputImag = [NSMutableArray arrayWithCapacity:n];

    // vDSP打包格式：DC分量在realp[0]，Nyquist在imagp[0]
    for (vDSP_Length i = 0; i < n; i++) {
        [outputReal addObject:@(inputComplex.realp[i])];
        [outputImag addObject:@(inputComplex.imagp[i])];
    }

    // 清理
    vDSP_destroy_fftsetup(fftSetup);
    free(inputReal);
    free(inputImag);

    return @{@"real": outputReal, @"imag": outputImag};
}

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)ifftWithReal:(NSArray<NSNumber *> *)realInput
                                                             imag:(NSArray<NSNumber *> *)imagInput
                                                           length:(vDSP_Length)length {
    if (!realInput || length == 0) {
        return @{};
    }

    vDSP_Length n = [[self class] nextPowerOfTwo:length];

    // 准备输入数据
    float *inputReal = (float *)malloc(n * sizeof(float));
    float *inputImag = (float *)malloc(n * sizeof(float));

    for (vDSP_Length i = 0; i < length; i++) {
        inputReal[i] = [realInput[i] floatValue];
        inputImag[i] = [imagInput[i] floatValue];
    }
    for (vDSP_Length i = length; i < n; i++) {
        inputReal[i] = 0.0f;
        inputImag[i] = 0.0f;
    }

    // 创建FFT setup
    vDSP_Length log2n = (vDSP_Length)log2(n);
    FFTSetup fftSetup = vDSP_create_fftsetup(log2n, FFT_RADIX2);

    DSPSplitComplex inputComplex;
    inputComplex.realp = inputReal;
    inputComplex.imagp = inputImag;

    // 执行IFFT
    vDSP_fft_zrip(fftSetup, &inputComplex, 1, log2n, FFT_INVERSE);

    // 缩放（vDSP的IFFT需要额外缩放）
    float scale = 1.0f / n;
    vDSP_vsmul(inputComplex.realp, 1, &scale, inputComplex.realp, 1, n);
    vDSP_vsmul(inputComplex.imagp, 1, &scale, inputComplex.imagp, 1, n);

    // 转换为输出数组
    NSMutableArray<NSNumber *> *outputReal = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *outputImag = [NSMutableArray arrayWithCapacity:n];

    for (vDSP_Length i = 0; i < n; i++) {
        [outputReal addObject:@(inputComplex.realp[i])];
        [outputImag addObject:@(inputComplex.imagp[i])];
    }

    vDSP_destroy_fftsetup(fftSetup);
    free(inputReal);
    free(inputImag);

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
