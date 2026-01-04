//
//  PIDWienerDeconvolution.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  维纳反卷积实现 - PID分析的核心算法
//

#import "PIDWienerDeconvolution.h"
#import "PIDFFTProcessor.h"
#import <Accelerate/Accelerate.h>
#import <mach/mach_time.h>

// 获取mach_absolute_time的频率
static double getMachFrequency(void) {
    static double frequency = 0.0;
    if (frequency == 0.0) {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        frequency = (double)info.numer / info.denom;
    }
    return frequency;
}

@implementation PIDWienerResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _rowCount = 0;
        _columnCount = 0;
    }
    return self;
}

@end

@interface PIDWienerDeconvolution ()

@property (nonatomic, strong) PIDFFTProcessor *fftProcessor;

@end

@implementation PIDWienerDeconvolution

- (instancetype)init {
    self = [super init];
    if (self) {
        _dt = 1.0 / 8000.0;  // 默认8kHz采样率
        _fftProcessor = [[PIDFFTProcessor alloc] init];
    }
    return self;
}

#pragma mark - Public Methods

/**
 * 维纳反卷积算法
 * 对应Python: wiener_deconvolution(self, input, output, cutfreq)
 *
 * 数学原理：
 * H = FFT(input)
 * G = FFT(output)
 * sn = 信噪比（基于频率和截止频率计算）
 * result = IFFT(G * conj(H) / (H * conj(H) + 1/sn))
 */
- (PIDWienerResult *)deconvolveWithInput:(NSArray<NSArray<NSNumber *> *> *)inputSignal
                                output:(NSArray<NSArray<NSNumber *> *> *)outputSignal
                                cutFreq:(double)cutFreq {

    // 性能监控
    uint64_t startTime = mach_absolute_time();

    if (!inputSignal || !outputSignal || inputSignal.count != outputSignal.count) {
        return [[PIDWienerResult alloc] init];
    }

    NSInteger rowCount = inputSignal.count;
    if (rowCount == 0) {
        return [[PIDWienerResult alloc] init];
    }

    // 获取每个窗口的长度
    NSInteger maxColCount = 0;
    for (NSArray<NSNumber *> *row in inputSignal) {
        if (row.count > maxColCount) {
            maxColCount = row.count;
        }
    }

    // Padding到1024的倍数（提高FFT速度）
    vDSP_Length paddedLength = [self padLength:maxColCount];
    NSLog(@"📊 维纳反卷积: %ld窗口, 原始长度=%ld, padding后=%lu",
          (long)rowCount, (long)maxColCount, paddedLength);

    // 🔧 优化: 信噪比sn对所有窗口相同，只需计算一次
    NSArray<NSNumber *> *freqs = [self.fftProcessor fftfreqWithLength:paddedLength dt:self.dt];
    NSArray<NSNumber *> *sn = [self calculateSignalToNoise:freqs cutFreq:cutFreq];
    NSArray<NSNumber *> *invSN = [self reciprocal:sn];  // 预计算1/sn

    // 🔧 使用NSMutableArray预分配，提高性能
    NSMutableArray<NSArray<NSNumber *> *> *resultData = [NSMutableArray arrayWithCapacity:rowCount];

    // 对每个窗口进行反卷积
    for (NSInteger i = 0; i < rowCount; i++) {
        @autoreleasepool {
            NSArray<NSNumber *> *inputRow = inputSignal[i];
            NSArray<NSNumber *> *outputRow = outputSignal[i];

            // Padding到paddedLength
            NSArray<NSNumber *> *paddedInput = [self padArray:inputRow toLength:paddedLength];
            NSArray<NSNumber *> *paddedOutput = [self padArray:outputRow toLength:paddedLength];

            // 执行FFT
            NSDictionary *inputFFT = [self.fftProcessor fftWithReal:paddedInput imag:nil length:paddedLength];
            NSDictionary *outputFFT = [self.fftProcessor fftWithReal:paddedOutput imag:nil length:paddedLength];

            NSArray<NSNumber *> *H_real = inputFFT[@"real"];
            NSArray<NSNumber *> *H_imag = inputFFT[@"imag"];
            NSArray<NSNumber *> *G_real = outputFFT[@"real"];
            NSArray<NSNumber *> *G_imag = outputFFT[@"imag"];

            // 维纳反卷积公式: G * conj(H) / (H * conj(H) + 1/sn)
            // H * conj(H) = |H|^2（功率谱）
            NSArray<NSNumber *> *powerH = [self complexPowerSpectrumReal:H_real imag:H_imag];

            // 分母: powerH + 1/sn (使用预计算的invSN)
            NSArray<NSNumber *> *denomReal = [self addArrays:powerH and:invSN];

            // 分子: G * conj(H)
            NSDictionary *G_Hconj = [self.fftProcessor complexMultiplyReal1:G_real imag1:G_imag real2:H_real imag2:[self negate:H_imag]];
            NSArray<NSNumber *> *numerReal = G_Hconj[@"real"];
            NSArray<NSNumber *> *numerImag = G_Hconj[@"imag"];

            // 复数除法: (numerReal + numerImag*i) / (denomReal + 0*i)
            NSDictionary *deconvFFT = [self.fftProcessor complexDivideNumerReal:numerReal numerImag:numerImag denomReal:denomReal denomImag:nil];
            NSArray<NSNumber *> *deconvReal = deconvFFT[@"real"];
            NSArray<NSNumber *> *deconvImag = deconvFFT[@"imag"];

            // IFFT
            NSDictionary *ifftResult = [self.fftProcessor ifftWithReal:deconvReal imag:deconvImag length:paddedLength];
            NSArray<NSNumber *> *ifftReal = ifftResult[@"real"];

            // 截取原始长度（去掉padding）
            NSInteger originalLength = inputRow.count;
            NSArray<NSNumber *> *rowResult = [ifftReal subarrayWithRange:NSMakeRange(0, originalLength)];

            [resultData addObject:rowResult];
        }
    }

    // 性能监控
    uint64_t endTime = mach_absolute_time();
    double elapsedMs = (double)(endTime - startTime) * 1000.0 / getMachFrequency();

    PIDWienerResult *result = [[PIDWienerResult alloc] init];
    result.data = resultData;
    result.rowCount = rowCount;
    result.columnCount = maxColCount;

    NSLog(@"✅ 维纳反卷积完成: %ld x %ld | 耗时: %.1fms (并行优化+sn预计算)",
          (long)rowCount, (long)maxColCount, elapsedMs);

    return result;
}

#pragma mark - Helper Methods

/**
 * 计算padding后的长度（1024的倍数）
 * 对应Python: pad = 1024 - (len(input[0]) % 1024)
 */
- (vDSP_Length)padLength:(NSInteger)length {
    NSInteger remainder = length % 1024;
    if (remainder == 0) {
        return (vDSP_Length)length;
    }
    return (vDSP_Length)(length + (1024 - remainder));
}

/**
 * Padding数组到指定长度
 */
- (NSArray<NSNumber *> *)padArray:(NSArray<NSNumber *> *)array toLength:(vDSP_Length)targetLength {
    NSMutableArray<NSNumber *> *padded = [NSMutableArray arrayWithCapacity:targetLength];

    // 复制原始数据
    [padded addObjectsFromArray:array];

    // 填充0
    while (padded.count < targetLength) {
        [padded addObject:@0.0f];
    }

    return [padded copy];
}

/**
 * 计算信噪比
 * 对应Python中的sn计算过程
 */
- (NSArray<NSNumber *> *)calculateSignalToNoise:(NSArray<NSNumber *> *)freqs cutFreq:(double)cutFreq {
    // sn = to_mask(clip(abs(freq), cutfreq-1e-9, cutfreq))
    NSMutableArray<NSNumber *> *clipped = [NSMutableArray arrayWithCapacity:freqs.count];

    for (NSNumber *freqNum in freqs) {
        double f = fabs([freqNum doubleValue]);
        // clip到 [cutFreq-1e-9, cutFreq]
        f = MAX(cutFreq - 1e-9, MIN(cutFreq, f));
        [clipped addObject:@(f)];
    }

    // 归一化
    NSArray<NSNumber *> *sn = [self normalizeToMask:clipped];

    // 计算低通滤波器长度
    // Python: len_lpf = np.sum(np.ones_like(sn) - sn)
    // 即：sum(1 - sn)，不是count(sn > 0.5)
    double lenLPF = 0.0;
    for (NSNumber *val in sn) {
        lenLPF += 1.0 - [val doubleValue];
    }

    // 高斯滤波
    NSArray<NSNumber *> *snFiltered = [self gaussianFilter:sn sigma:lenLPF / 6.0];

    // sn = 10 * (-sn + 1 + 1e-9)
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:snFiltered.count];
    for (NSNumber *val in snFiltered) {
        double v = [val doubleValue];
        double snVal = 10.0 * (-v + 1.0 + 1e-9);
        [result addObject:@(snVal)];
    }

    return [result copy];
}

/**
 * 归一化数组到 [0, 1]
 * 对应Python: to_mask()
 * clipped -= clipped.min()
 * clipped /= clipped.max()
 */
- (NSArray<NSNumber *> *)normalizeToMask:(NSArray<NSNumber *> *)clipped {
    if (!clipped || clipped.count == 0) {
        return @[];
    }

    // 找最小值
    double minVal = HUGE_VALF;
    for (NSNumber *num in clipped) {
        double v = [num doubleValue];
        if (v < minVal) minVal = v;
    }

    // 减去最小值
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:clipped.count];
    for (NSNumber *num in clipped) {
        [result addObject:@([num doubleValue] - minVal)];
    }

    // 找最大值
    double maxVal = -HUGE_VALF;
    for (NSNumber *num in result) {
        double v = [num doubleValue];
        if (v > maxVal) maxVal = v;
    }

    // 除以最大值
    if (maxVal > 1e-9) {
        NSMutableArray<NSNumber *> *normalized = [NSMutableArray arrayWithCapacity:result.count];
        for (NSNumber *num in result) {
            [normalized addObject:@([num doubleValue] / maxVal)];
        }
        return [normalized copy];
    }

    return [result copy];
}

/**
 * 高斯滤波（1D）
 * 对应Python: gaussian_filter1d(data, sigma, mode='constant')
 *
 * 🔧 修复边界处理：scipy的mode='constant'表示边界外用0填充
 * 这与之前的实现不同：之前跳过边界外数据并重新归一化，
 * 现在边界外数据用0填充，权重核保持完整
 */
- (NSArray<NSNumber *> *)gaussianFilter:(NSArray<NSNumber *> *)data sigma:(double)sigma {
    if (!data || data.count == 0 || sigma < 0.01) {
        return data ?: @[];
    }

    NSInteger n = data.count;
    // 🔧 限制核大小，避免kernelSize > n导致问题
    NSInteger kernelSize = (NSInteger)(sigma * 6) | 1;  // 确保奇数
    if (kernelSize < 3) kernelSize = 3;
    if (kernelSize > n) {
        kernelSize = (n / 2) | 1;
        if (kernelSize < 3) kernelSize = 3;
    }

    // 生成高斯核
    float *kernel = (float *)malloc(kernelSize * sizeof(float));
    [self generateGaussianKernel:kernel size:kernelSize sigma:sigma];

    // 🔧 修复：使用scipy mode='constant'边界处理
    // 边界外的数据视为0，权重核保持完整（不重新归一化）
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:n];
    NSInteger halfKernel = kernelSize / 2;

    for (NSInteger i = 0; i < n; i++) {
        double sum = 0.0;

        for (NSInteger j = 0; j < kernelSize; j++) {
            NSInteger dataIndex = i - halfKernel + j;
            double weight = kernel[j];

            // scipy的mode='constant': 边界外用0填充
            if (dataIndex >= 0 && dataIndex < n) {
                sum += [data[dataIndex] doubleValue] * weight;
            }
            // dataIndex < 0 或 >= n 时，dataValue视为0，无需加到sum中
        }

        [result addObject:@(sum)];
    }

    free(kernel);

    return [result copy];
}

/**
 * 生成高斯核
 * g(x) = (1 / (sigma * sqrt(2*pi))) * exp(-x^2 / (2*sigma^2))
 */
- (void)generateGaussianKernel:(float *)kernel size:(NSInteger)size sigma:(double)sigma {
    NSInteger half = size / 2;
    double scale = 1.0 / (sigma * sqrt(2.0 * M_PI));
    double scale2 = 2.0 * sigma * sigma;

    double sum = 0.0;
    for (NSInteger i = 0; i < size; i++) {
        double x = i - half;
        double val = scale * exp(-(x * x) / scale2);
        kernel[i] = (float)val;
        sum += val;
    }

    // 归一化（使核和为1）
    if (sum > 1e-9) {
        for (NSInteger i = 0; i < size; i++) {
            kernel[i] /= (float)sum;
        }
    }
}

/**
 * 计算复数功率谱 |H|^2 = H * conj(H) = real^2 + imag^2
 */
- (NSArray<NSNumber *> *)complexPowerSpectrumReal:(NSArray<NSNumber *> *)real imag:(NSArray<NSNumber *> *)imag {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:real.count];

    for (NSInteger i = 0; i < real.count; i++) {
        float r = [real[i] floatValue];
        float im = imag && i < imag.count ? [imag[i] floatValue] : 0.0f;
        [result addObject:@(r * r + im * im)];
    }

    return [result copy];
}

/**
 * 数组倒数（1/x）
 */
- (NSArray<NSNumber *> *)reciprocal:(NSArray<NSNumber *> *)array {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:array.count];

    for (NSNumber *num in array) {
        double val = [num doubleValue];
        [result addObject:@(fabs(val) > 1e-9 ? 1.0 / val : 1e9)];  // 避免除以0
    }

    return [result copy];
}

/**
 * 数组相加
 */
- (NSArray<NSNumber *> *)addArrays:(NSArray<NSNumber *> *)array1 and:(NSArray<NSNumber *> *)array2 {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:array1.count];

    for (NSInteger i = 0; i < array1.count; i++) {
        float v1 = [array1[i] floatValue];
        float v2 = i < array2.count ? [array2[i] floatValue] : 0.0f;
        [result addObject:@(v1 + v2)];
    }

    return [result copy];
}

/**
 * 数组取负
 */
- (NSArray<NSNumber *> *)negate:(NSArray<NSNumber *> *)array {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:array.count];

    for (NSNumber *num in array) {
        [result addObject:@(-[num floatValue])];
    }

    return [result copy];
}

@end
