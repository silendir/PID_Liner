//
//  PIDTraceAnalyzer.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID追踪分析器实现 - 对应Python PID-Analyzer的Trace类
//

#import "PIDTraceAnalyzer.h"
#import "PIDWienerDeconvolution.h"
#import "PIDFFTProcessor.h"
#import "PIDInterpolation.h"

// Betaflight P缩放因子
static const double kP_SCALE_FACTOR = 0.032029;

@implementation PIDStackData

- (NSInteger)windowCount {
    return self.input.count;
}

- (NSInteger)windowLength {
    return self.windowCount > 0 ? self.input[0].count : 0;
}

+ (instancetype)stackFromData:(PIDCSVData *)data
                  windowSize:(NSInteger)windowSize
                    overlap:(double)overlap {
    PIDStackData *stack = [[PIDStackData alloc] init];

    NSInteger n = data.timeSeconds.count;
    if (n == 0 || windowSize <= 0) {
        return stack;
    }

    // 计算步长
    NSInteger step = (NSInteger)(windowSize * (1.0 - overlap));
    if (step < 1) step = 1;

    // 计算窗口数量
    NSInteger windowCount = (n - windowSize) / step + 1;

    // 创建堆叠数据
    NSMutableArray<NSMutableArray<NSNumber *> *> *inputStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *gyroStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *throttleStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *timeStack = [NSMutableArray arrayWithCapacity:windowCount];

    for (NSInteger i = 0; i < windowCount; i++) {
        NSInteger start = i * step;
        NSInteger end = MIN(start + windowSize, n);

        // 提取窗口数据
        NSArray<NSNumber *> *timeWindow = [data.timeSeconds subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *rcCommand0 = [data.rcCommand0 subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *rcCommand3 = [data.rcCommand3 subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *gyro0 = [data.gyroADC0 subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *axisP0 = [data.axisP0 subarrayWithRange:NSMakeRange(start, end - start)];

        // 计算PID输入（使用rcCommand[0]作为输入）
        NSMutableArray<NSNumber *> *pidInput = [NSMutableArray arrayWithCapacity:end - start];
        for (NSInteger j = 0; j < rcCommand0.count; j++) {
            double pval = [rcCommand0[j] doubleValue];
            double gyro = [gyro0[j] doubleValue];
            double pidp = [axisP0[j] doubleValue];
            // pidin = gyro + pval / (0.032029 * pidp)
            double pidin = gyro + pval / (kP_SCALE_FACTOR * pidp);
            [pidInput addObject:@(pidin)];
        }

        [timeStack addObject:[timeWindow mutableCopy]];
        [inputStack addObject:pidInput];
        [gyroStack addObject:[gyro0 mutableCopy]];
        [throttleStack addObject:[rcCommand3 mutableCopy]];
    }

    stack.input = inputStack;
    stack.gyro = gyroStack;
    stack.throttle = throttleStack;
    stack.time = timeStack;

    return stack;
}

@end

@implementation PIDResponseResult

@end

@implementation PIDSpectrumResult

@end

#pragma mark - PIDTraceAnalyzer Implementation

@interface PIDTraceAnalyzer ()

@property (nonatomic, strong) PIDWienerDeconvolution *wienerDeconvolution;
@property (nonatomic, strong) PIDFFTProcessor *fftProcessor;

@end

@implementation PIDTraceAnalyzer

- (instancetype)init {
    return [self initWithSampleRate:8000.0 cutFreq:150.0];
}

- (instancetype)initWithSampleRate:(double)sampleRate
                           cutFreq:(double)cutFreq {
    self = [super init];
    if (self) {
        _dt = 1.0 / sampleRate;
        _cutFreq = cutFreq;
        _pScale = kP_SCALE_FACTOR;
        _responseLen = 400;  // 默认响应长度
        _wienerDeconvolution = [[PIDWienerDeconvolution alloc] init];
        _wienerDeconvolution.dt = _dt;
        _fftProcessor = [[PIDFFTProcessor alloc] init];
    }
    return self;
}

#pragma mark - PID环路输入计算

/**
 * 计算PID环路输入
 * pidin = gyro + pval / (0.032029 * pidp)
 */
- (double)pidInWithPVal:(double)pval
                    gyro:(double)gyro
                    pidP:(double)pidP {
    if (fabs(pidP) < 1e-9) {
        return gyro;  // 避免除以0
    }
    return gyro + pval / (kP_SCALE_FACTOR * pidP);
}

/**
 * 批量计算PID环路输入
 */
- (NSArray<NSNumber *> *)pidInWithPValArray:(NSArray<NSNumber *> *)pvalArray
                                    gyroArray:(NSArray<NSNumber *> *)gyroArray
                                         pidP:(double)pidP {
    if (!pvalArray || !gyroArray || pvalArray.count != gyroArray.count) {
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:pvalArray.count];

    for (NSInteger i = 0; i < pvalArray.count; i++) {
        double pval = [pvalArray[i] doubleValue];
        double gyro = [gyroArray[i] doubleValue];
        double pidin = [self pidInWithPVal:pval gyro:gyro pidP:pidP];
        [result addObject:@(pidin)];
    }

    return [result copy];
}

#pragma mark - 响应分析

/**
 * 计算阶跃响应
 * 对应Python: stack_response(stacks, window)
 */
- (PIDResponseResult *)stackResponse:(PIDStackData *)stacks
                             window:(NSArray<NSNumber *> *)window {
    if (!stacks || !window || stacks.windowCount == 0) {
        return [[PIDResponseResult alloc] init];
    }

    NSInteger windowCount = stacks.windowCount;
    NSInteger windowLen = stacks.windowLength;

    // 确保窗函数长度匹配
    NSArray<NSNumber *> *win = window;
    if (win.count != windowLen) {
        // 如果不匹配，重新生成窗函数
        win = [PIDTraceAnalyzer tukeyWindowWithLength:windowLen alpha:0.5];
    }

    // 应用窗函数
    NSMutableArray<NSArray<NSNumber *> *> *inp = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSArray<NSNumber *> *> *outp = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSArray<NSNumber *> *> *thr = [NSMutableArray arrayWithCapacity:windowCount];

    for (NSInteger i = 0; i < windowCount; i++) {
        [inp addObject:[self multiplyArray:stacks.input[i] by:win]];
        [outp addObject:[self multiplyArray:stacks.gyro[i] by:win]];
        [thr addObject:[self multiplyArray:stacks.throttle[i] by:win]];
    }

    // 维纳反卷积
    PIDWienerResult *deconvResult = [self.wienerDeconvolution deconvolveWithInput:inp
                                                                       output:outp
                                                                       cutFreq:self.cutFreq];

    // 截取指定长度
    NSMutableArray<NSArray<NSNumber *> *> *truncatedDeconv = [NSMutableArray arrayWithCapacity:windowCount];
    NSInteger rlen = MIN(self.responseLen, deconvResult.columnCount);
    for (NSArray<NSNumber *> *row in deconvResult.data) {
        NSArray<NSNumber *> *truncatedRow = [row subarrayWithRange:NSMakeRange(0, MIN(rlen, row.count))];
        [truncatedDeconv addObject:truncatedRow];
    }

    // 累积和 (cumsum = 阶跃响应)
    NSMutableArray<NSArray<NSNumber *> *> *stepResponse = [NSMutableArray arrayWithCapacity:windowCount];
    for (NSArray<NSNumber *> *row in truncatedDeconv) {
        [stepResponse addObject:[PIDInterpolation cumsum:row]];
    }

    // 计算统计量
    NSMutableArray<NSNumber *> *maxThr = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSNumber *> *avgIn = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSNumber *> *maxIn = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSNumber *> *avgT = [NSMutableArray arrayWithCapacity:windowCount];

    for (NSInteger i = 0; i < windowCount; i++) {
        // 最大油门
        double maxTh = [self maxAbsInArray:thr[i]];
        [maxThr addObject:@(maxTh)];

        // 平均/最大输入
        [avgIn addObject:@([self meanAbs:inp[i]])];
        [maxIn addObject:@([self maxAbsInArray:inp[i]])];

        // 平均时间
        [avgT addObject:@([self meanOfArray:stacks.time[i]])];
    }

    // 构建结果
    PIDResponseResult *result = [[PIDResponseResult alloc] init];
    result.stepResponse = stepResponse;
    result.avgTime = avgT;
    result.avgInput = avgIn;
    result.maxInput = maxIn;
    result.maxThrottle = maxThr;

    NSLog(@"✅ 响应分析完成: %ld窗口", (long)windowCount);

    return result;
}

#pragma mark - 频谱分析

/**
 * 计算噪声频谱
 * 对应Python: spectrum(time, traces)
 */
- (PIDSpectrumResult *)spectrumWithTime:(NSArray<NSNumber *> *)time
                                traces:(NSArray<NSArray<NSNumber *> *> *)traces {
    if (!time || !traces || traces.count == 0) {
        return [[PIDSpectrumResult alloc] init];
    }

    NSInteger traceLen = traces[0].count;

    // Padding到1024的倍数
    NSInteger pad = 1024 - (traceLen % 1024);
    NSInteger paddedLen = traceLen + pad;

    // Padding数据
    NSMutableArray<NSArray<NSNumber *> *> *paddedTraces = [NSMutableArray arrayWithCapacity:traces.count];
    for (NSArray<NSNumber *> *trace in traces) {
        NSMutableArray<NSNumber *> *padded = [trace mutableCopy];
        while (padded.count < paddedLen) {
            [padded addObject:@0.0f];
        }
        [paddedTraces addObject:[padded copy]];
    }

    // 计算频谱（使用实数FFT）
    NSMutableArray<NSArray<NSNumber *> *> *spectrum = [NSMutableArray arrayWithCapacity:traces.count];

    for (NSArray<NSNumber *> *paddedTrace in paddedTraces) {
        NSArray<NSNumber *> *spec = [self.fftProcessor realFFT:paddedTrace length:paddedLen];

        // 只取前一半（实数FFT的对称性）
        NSInteger halfLen = (spec.count + 1) / 2;
        NSArray<NSNumber *> *halfSpec = [spec subarrayWithRange:NSMakeRange(0, halfLen)];
        [spectrum addObject:halfSpec];
    }

    // 频率数组
    double dt = [time[1] doubleValue] - [time[0] doubleValue];
    NSArray<NSNumber *> *freqs = [self.fftProcessor fftfreqWithLength:paddedLen dt:dt];

    // 只取前一半（实数FFT的频率范围）
    NSInteger halfFreqLen = (freqs.count + 1) / 2;
    NSArray<NSNumber *> *halfFreqs = [freqs subarrayWithRange:NSMakeRange(0, halfFreqLen)];

    PIDSpectrumResult *result = [[PIDSpectrumResult alloc] init];
    result.frequencies = halfFreqs;
    result.spectrum = spectrum;

    NSLog(@"✅ 频谱分析完成: %lu追踪, %lu频率点",
          (unsigned long)spectrum.count, (unsigned long)halfFreqs.count);

    return result;
}

#pragma mark - 窗函数

/**
 * 生成Tukey窗函数
 * 对应Python: tukeywin(len, alpha=0.5)
 */
- (NSArray<NSNumber *> *)tukeyWindowWithLength:(NSInteger)length
                                          alpha:(double)alpha {
    return [PIDTraceAnalyzer tukeyWindowWithLength:length alpha:alpha];
}

/**
 * 生成Tukey窗函数（静态方法）
 * 对应Python: tukeywin(len, alpha=0.5)
 *
 * Tukey窗是一个余弦锥度窗，定义为：
 * - 0 ≤ n < α*N/2: 0.5 * (1 + cos(π*(2n/(αN) - 1)))
 * - α*N/2 ≤ n ≤ N/2: 1
 * - N/2 < n ≤ (1-α/2)*N: 0.5 * (1 + cos(π*(2n/(αN) - 1 - 2/α)))
 */
+ (NSArray<NSNumber *> *)tukeyWindowWithLength:(NSInteger)length
                                          alpha:(double)alpha {
    NSMutableArray<NSNumber *> *window = [NSMutableArray arrayWithCapacity:length];

    double alphaN = alpha * length;
    double limit1 = alphaN / 2.0;
    double limit2 = length * (1.0 - alpha / 2.0);

    for (NSInteger n = 0; n < length; n++) {
        double value = 0.0;

        if (n < limit1) {
            // 左侧余弦锥度
            if (limit1 > 0) {
                value = 0.5 * (1.0 + cos(M_PI * (2.0 * n / alphaN - 1.0)));
            }
        } else if (n < (length / 2.0)) {
            // 中间平坦区域
            value = 1.0;
        } else if (n <= limit2) {
            // 右侧余弦锥度
            value = 0.5 * (1.0 + cos(M_PI * (2.0 * n / alphaN - 1.0 - 2.0 / alpha)));
        }

        [window addObject:@(value)];
    }

    return [window copy];
}

#pragma mark - Helper Methods

/**
 * 数组逐元素乘法
 */
- (NSArray<NSNumber *> *)multiplyArray:(NSArray<NSNumber *> *)array by:(NSArray<NSNumber *> *)factor {
    if (!array || !factor || array.count != factor.count) {
        return array ?: @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:array.count];

    for (NSInteger i = 0; i < array.count; i++) {
        double a = [array[i] doubleValue];
        double f = [factor[i] doubleValue];
        [result addObject:@(a * f)];
    }

    return [result copy];
}

/**
 * 计算数组绝对值的最大值
 */
- (double)maxAbsInArray:(NSArray<NSNumber *> *)array {
    if (!array || array.count == 0) {
        return 0.0;
    }

    double maxVal = 0.0;
    for (NSNumber *num in array) {
        double absVal = fabs([num doubleValue]);
        if (absVal > maxVal) {
            maxVal = absVal;
        }
    }

    return maxVal;
}

/**
 * 计算数组绝对值的平均
 */
- (double)meanAbs:(NSArray<NSNumber *> *)array {
    if (!array || array.count == 0) {
        return 0.0;
    }

    double sum = 0.0;
    for (NSNumber *num in array) {
        sum += fabs([num doubleValue]);
    }

    return sum / array.count;
}

/**
 * 计算数组的平均值
 */
- (double)meanOfArray:(NSArray<NSNumber *> *)array {
    if (!array || array.count == 0) {
        return 0.0;
    }

    double sum = 0.0;
    for (NSNumber *num in array) {
        sum += [num doubleValue];
    }

    return sum / array.count;
}

@end
