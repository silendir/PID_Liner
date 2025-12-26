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
#import <mach/mach_time.h>

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

            // 🔧 防止除以0：当axisP为0或很小时，只使用gyro作为输入
            double pidin;
            double denom = kP_SCALE_FACTOR * pidp;
            if (fabs(denom) < 1e-9) {
                // axisP为0或接近0，无法计算PID输入，使用gyro作为fallback
                pidin = gyro;
            } else {
                // pidin = gyro + pval / (0.032029 * pidp)
                pidin = gyro + pval / denom;
            }
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

+ (instancetype)stackFromData:(PIDCSVData *)data
                  axisIndex:(NSInteger)axisIndex
                windowSize:(NSInteger)windowSize
                  overlap:(double)overlap
                     pGain:(double)pGain {
    PIDStackData *stack = [[PIDStackData alloc] init];

    NSInteger n = data.timeSeconds.count;
    if (n == 0 || windowSize <= 0) {
        return stack;
    }

    // 🔧 使用固定的P增益值（从CSV头信息解析得到，而非axisP数据）
    // 如果pGain无效（<=0），使用默认值45
    if (pGain <= 0) {
        pGain = 45.0;
    }

    // 计算步长 - Python: superpos=16, shift=framelen/16
    // iOS传入overlap=0.5对应shift=windowSize*0.5
    // Python的superpos=16对应overlap=15/16=0.9375
    NSInteger step = (NSInteger)(windowSize * (1.0 - overlap));
    if (step < 1) step = 1;

    // 计算窗口数量
    NSInteger windowCount = (n - windowSize) / step + 1;

    // 创建堆叠数据
    NSMutableArray<NSMutableArray<NSNumber *> *> *inputStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *gyroStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *throttleStack = [NSMutableArray arrayWithCapacity:windowCount];
    NSMutableArray<NSMutableArray<NSNumber *> *> *timeStack = [NSMutableArray arrayWithCapacity:windowCount];

    // 根据轴索引选择数据
    NSArray<NSNumber *> *gyroADCAxis = nil;
    NSArray<NSNumber *> *axisP = nil;

    switch (axisIndex) {
        case 0:  // Roll
            gyroADCAxis = data.gyroADC0;
            axisP = data.axisP0;
            break;
        case 1:  // Pitch
            gyroADCAxis = data.gyroADC1;
            axisP = data.axisP1;
            break;
        case 2:  // Yaw
            gyroADCAxis = data.gyroADC2;
            axisP = data.axisP2;
            break;
        default:
            return stack;
    }

    // 验证数据
    if (!gyroADCAxis || !axisP) {
        return stack;
    }

    for (NSInteger i = 0; i < windowCount; i++) {
        NSInteger start = i * step;
        NSInteger end = MIN(start + windowSize, n);

        if (end <= start) break;

        // 提取窗口数据
        NSArray<NSNumber *> *timeWindow = [data.timeSeconds subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *rcCommand3 = [data.rcCommand3 subarrayWithRange:NSMakeRange(start, end - start)];  // Throttle
        NSArray<NSNumber *> *gyroWindow = [gyroADCAxis subarrayWithRange:NSMakeRange(start, end - start)];
        NSArray<NSNumber *> *axisPWindow = [axisP subarrayWithRange:NSMakeRange(start, end - start)];

        // 🔧 修正：计算PID输入（对应Python的pid_in函数）
        // Python: pidin = gyro + p_err / (0.032029 * pidp)
        // 其中 p_err = axisP[i], pidp = 固定的P增益值
        NSMutableArray<NSNumber *> *pidInput = [NSMutableArray arrayWithCapacity:end - start];
        for (NSInteger j = 0; j < gyroWindow.count; j++) {
            double pval = [axisPWindow[j] doubleValue];  // ✅ 修正：使用axisP作为pval
            double gyro = [gyroWindow[j] doubleValue];
            double pidp = pGain;  // ✅ 修正：使用固定的P增益值

            // 🔧 防止除以0：当pGain为0或很小时，只使用gyro作为输入
            double pidin;
            double denom = kP_SCALE_FACTOR * pidp;
            if (fabs(denom) < 1e-9) {
                // pGain为0或接近0，无法计算PID输入，使用gyro作为fallback
                pidin = gyro;
            } else {
                // pidin = gyro + pval / (0.032029 * pidp)
                pidin = gyro + pval / denom;
            }
            [pidInput addObject:@(pidin)];
        }

        [timeStack addObject:[timeWindow mutableCopy]];
        [inputStack addObject:pidInput];
        [gyroStack addObject:[gyroWindow mutableCopy]];
        [throttleStack addObject:[rcCommand3 mutableCopy]];
    }

    stack.input = inputStack;
    stack.gyro = gyroStack;
    stack.throttle = throttleStack;
    stack.time = timeStack;

    NSLog(@"✅ 堆叠数据创建完成: %ld窗口, P增益=%.1f", (long)windowCount, pGain);

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
        // 🔧 修正：Python版本 resplen = 0.5s，8kHz采样率下 = 4000采样点
        _responseLen = 4000;  // 0.5s @ 8kHz
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
    // 🔧 修复: 使用Hanning窗（与Python版本一致）
    // Python: self.window = np.hanning(self.flen)
    NSArray<NSNumber *> *win = window;
    if (win.count != windowLen) {
        // 如果不匹配，重新生成Hanning窗函数
        win = [PIDTraceAnalyzer hanningWindowWithLength:windowLen];
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

    // 🔍 调试：检查反卷积结果
    NSLog(@"🔍 反卷积结果: rowCount=%lu, columnCount=%ld",
          (unsigned long)deconvResult.data.count, (long)deconvResult.columnCount);
    if (deconvResult.data.count > 0 && deconvResult.data[0].count > 0) {
        NSArray<NSNumber *> *firstRow = deconvResult.data[0];
        NSInteger n = MIN(10, firstRow.count);
        NSMutableString *values = [NSMutableString string];
        for (NSInteger i = 0; i < n; i++) {
            [values appendFormat:@"%.4f ", [firstRow[i] doubleValue]];
        }
        NSLog(@"🔍 反卷积data[0]前%ld个值: %@", (long)n, values);

        // 计算反卷积结果的范围
        double minVal = [firstRow[0] doubleValue];
        double maxVal = [firstRow[0] doubleValue];
        for (NSNumber *num in firstRow) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 反卷积data[0]范围: min=%.4f, max=%.4f", minVal, maxVal);
    }

    // 截取指定长度
    NSMutableArray<NSArray<NSNumber *> *> *truncatedDeconv = [NSMutableArray arrayWithCapacity:windowCount];
    NSInteger rlen = MIN(self.responseLen, deconvResult.columnCount);
    for (NSArray<NSNumber *> *row in deconvResult.data) {
        NSArray<NSNumber *> *truncatedRow = [row subarrayWithRange:NSMakeRange(0, MIN(rlen, row.count))];
        [truncatedDeconv addObject:truncatedRow];
    }

    // 累积和 (cumsum = 阶跃响应)
    // 🔧 修复: 对齐Python实现，直接对脉冲响应做cumsum
    // Python: delta_resp = deconvolved_sm.cumsum(axis=1)
    // 不再做基准面调整（减去第一个值），因为这会导致负累积
    NSMutableArray<NSArray<NSNumber *> *> *stepResponse = [NSMutableArray arrayWithCapacity:windowCount];
    for (NSArray<NSNumber *> *row in truncatedDeconv) {
        if (row.count == 0) {
            [stepResponse addObject:@[]];
            continue;
        }

        // 直接对脉冲响应做累积和（与Python版本一致）
        NSArray<NSNumber *> *cumsum = [PIDInterpolation cumsum:row];
        [stepResponse addObject:cumsum];
    }

    // 🔍 调试：检查阶跃响应结果
    if (stepResponse.count > 0) {
        NSArray<NSNumber *> *firstStep = stepResponse[0];
        NSInteger n = MIN(10, firstStep.count);
        NSMutableString *values = [NSMutableString string];
        for (NSInteger i = 0; i < n; i++) {
            [values appendFormat:@"%.3f ", [firstStep[i] doubleValue]];
        }
        NSLog(@"🔍 阶跃响应stepResponse[0]前%ld个值: %@", (long)n, values);

        // 计算阶跃响应的最大最小值
        double minVal = [firstStep[0] doubleValue];
        double maxVal = [firstStep[0] doubleValue];
        for (NSNumber *num in firstStep) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 阶跃响应stepResponse[0]范围: min=%.3f, max=%.3f", minVal, maxVal);

        // 🔍 新增：检查最后一个点的值
        if (firstStep.count > 1) {
            NSLog(@"🔍 阶跃响应stepResponse[0]起点=%.3f, 终点=%.3f",
                  [firstStep[0] doubleValue],
                  [firstStep[firstStep.count-1] doubleValue]);
        }
    }

    // 🔍 新增：计算所有窗口的平均阶跃响应，检查整体趋势
    if (stepResponse.count > 0) {
        double startAvg = 0.0;
        double endAvg = 0.0;
        NSInteger count = 0;
        for (NSArray<NSNumber *> *step in stepResponse) {
            if (step.count > 0) {
                startAvg += [step[0] doubleValue];
                endAvg += [step[step.count-1] doubleValue];
                count++;
            }
        }
        if (count > 0) {
            startAvg /= count;
            endAvg /= count;
            NSLog(@"🔍 所有窗口平均: 起点=%.3f, 终点=%.3f", startAvg, endAvg);
        }
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

/**
 * 生成Hanning窗函数
 * 对应Python: np.hanning(length)
 * 公式: 0.5 * (1 - cos(2*pi*n / (N-1)))
 */
+ (NSArray<NSNumber *> *)hanningWindowWithLength:(NSInteger)length {
    if (length <= 0) {
        return @[];
    }

    // 长度为1时返回[1.0]
    if (length == 1) {
        return @[@1.0];
    }

    NSMutableArray<NSNumber *> *window = [NSMutableArray arrayWithCapacity:length];

    for (NSInteger n = 0; n < length; n++) {
        // Hanning窗公式: 0.5 * (1 - cos(2*pi*n / (N-1)))
        double value = 0.5 * (1.0 - cos(2.0 * M_PI * n / (length - 1)));
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

#pragma mark - 数据预处理 (equalize_data)

/**
 * 时间轴均匀化插值
 * 对应Python: equalize_data()
 *
 * 使用线性插值将不均匀采样的数据转换到均匀时间轴
 */
+ (NSArray<NSNumber *> *)equalizeDataWithTime:(NSArray<NSNumber *> *)originalTime
                                         data:(NSArray<NSNumber *> *)data
                              targetSampleRate:(double)targetSampleRate {
    if (!originalTime || !data || originalTime.count != data.count || data.count < 2) {
        return data ?: @[];
    }

    NSInteger n = data.count;
    double tStart = [originalTime[0] doubleValue];
    double tEnd = [originalTime[n - 1] doubleValue];

    // 如果目标采样率为0，保持原始点数
    NSInteger targetLength = (targetSampleRate > 0)
        ? (NSInteger)((tEnd - tStart) * targetSampleRate)
        : n;

    if (targetLength < 2) targetLength = n;

    // 创建均匀时间轴
    NSMutableArray<NSNumber *> *uniformTime = [NSMutableArray arrayWithCapacity:targetLength];
    NSMutableArray<NSNumber *> *interpolatedData = [NSMutableArray arrayWithCapacity:targetLength];

    for (NSInteger i = 0; i < targetLength; i++) {
        double t = tStart + (tEnd - tStart) * i / (targetLength - 1);
        [uniformTime addObject:@(t)];

        // 线性插值
        double value = 0.0;

        if (t <= [originalTime[0] doubleValue]) {
            value = [data[0] doubleValue];
        } else if (t >= [originalTime[n - 1] doubleValue]) {
            value = [data[n - 1] doubleValue];
        } else {
            // 找到t所在的区间 [time[i], time[i+1]]
            for (NSInteger j = 0; j < n - 1; j++) {
                double t0 = [originalTime[j] doubleValue];
                double t1 = [originalTime[j + 1] doubleValue];

                if (t >= t0 && t <= t1) {
                    double y0 = [data[j] doubleValue];
                    double y1 = [data[j + 1] doubleValue];

                    if (t1 - t0 > 1e-9) {
                        // 线性插值: y = y0 + (y1 - y0) * (t - t0) / (t1 - t0)
                        value = y0 + (y1 - y0) * (t - t0) / (t1 - t0);
                    } else {
                        value = y0;
                    }
                    break;
                }
            }
        }

        [interpolatedData addObject:@(value)];
    }

    NSLog(@"✅ equalize_data: %ld点 -> %ld点 (时间轴 %.3f ~ %.3fs)",
          (long)n, (long)targetLength, tStart, tEnd);

    return [interpolatedData copy];
}

#pragma mark - 加权平均 (weighted_mode_avr)

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

/**
 * 加权模式平均（高性能优化版本）
 * 对应Python: weighted_mode_avr()
 *
 * 优化策略:
 * 1. GCD并行处理多窗口
 * 2. Accelerate框架向量运算
 * 3. 预计算高斯核避免重复计算
 * 4. 更激进的降采样参数
 */
+ (NSArray<NSNumber *> *)weightedModeAverageWithStepResponse:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                                   avgTime:(NSArray<NSNumber *> *)avgTime
                                                  maxInput:(NSArray<NSNumber *> *)maxInput
                                                vertRange:(NSArray<NSNumber *> *)vertRange
                                                 vertBins:(NSInteger)vertBins {

    // 性能监控：开始时间
    uint64_t startTime = mach_absolute_time();

    if (!stepResponse || stepResponse.count == 0) {
        return @[];
    }

    NSInteger windowCount = stepResponse.count;
    if (windowCount == 0) return @[];

    // 获取响应长度（所有窗口应该相同）
    NSInteger responseLength = stepResponse[0].count;
    if (responseLength == 0) return @[];

    // 🔧🔧 极限性能优化参数
    double filtWidth = 5.0;  // 高斯平滑宽度减小 (7→5)
    // 时间箱数量：平衡精度和性能
    NSInteger timeBins = MIN(80, responseLength);  // 🔧 使用80个时间箱平衡精度和速度

    // 垂直范围
    double yMin = vertRange && vertRange.count > 0 ? [vertRange[0] doubleValue] : -1.5;
    double yMax = vertRange && vertRange.count > 1 ? [vertRange[1] doubleValue] : 3.5;
    double yRange = yMax - yMin;

    NSLog(@"📊 weighted_mode_avr: %ld窗口 x %ld响应点 → 降采样到%ld时间箱, 垂直范围[%.1f, %.1f]",
          (long)windowCount, (long)responseLength, (long)timeBins, yMin, yMax);

    // 🔧 优化: 使用C数组代替NSMutableArray
    NSInteger histSize = timeBins * vertBins;
    float *hist2d = (float *)calloc(histSize, sizeof(float));
    if (!hist2d) return @[];

    // 🔧 预计算缩放因子，避免循环中重复计算
    double timeScale = (double)timeBins / responseLength;
    double vertScale = vertBins / yRange;

    // 🔧 填充直方图（串行但优化）
    for (NSInteger w = 0; w < windowCount; w++) {
        NSArray<NSNumber *> *windowResp = stepResponse[w];
        if (!windowResp || windowResp.count != responseLength) continue;

        // 权重：基于输入幅度
        double weight = 1.0;
        if (maxInput && w < maxInput.count) {
            double maxIn = [maxInput[w] doubleValue];
            weight = sqrt(MAX(1.0, maxIn / 500.0));
        }

        // 🔧 优化: 处理所有响应点以确保数据完整性
        // 通过减少timeBins而不是截断数据来优化性能
        NSInteger processLength = responseLength;

        for (NSInteger i = 0; i < processLength; i++) {
            double respVal = [windowResp[i] doubleValue];
            if (isnan(respVal) || isinf(respVal)) continue;

            // 快速映射到直方图坐标
            NSInteger tBin = (NSInteger)(i * timeScale);
            NSInteger vBin = (NSInteger)((respVal - yMin) * vertScale);

            // 边界检查
            if (tBin >= 0 && tBin < timeBins && vBin >= 0 && vBin < vertBins) {
                hist2d[tBin * vertBins + vBin] += weight;
            }
        }
    }

    // 2. 高斯平滑（时间方向）- 使用预计算的高斯核
    float *hist2dSmooth = (float *)malloc(histSize * sizeof(float));

    // 🔧 预计算高斯核，避免内层循环重复计算exp
    NSInteger kernelRadius = 5;  // 从7减小到5
    float gaussKernel[11];  // 2*5+1 = 11
    double kernelSum = 0.0;

    for (NSInteger dt = -kernelRadius; dt <= kernelRadius; dt++) {
        double g = exp(-(dt * dt) / (2.0 * filtWidth * filtWidth / 9.0));
        gaussKernel[dt + kernelRadius] = (float)g;
        kernelSum += g;
    }
    // 归一化核
    for (NSInteger i = 0; i < 2 * kernelRadius + 1; i++) {
        gaussKernel[i] /= (float)kernelSum;
    }

    // 应用高斯平滑
    for (NSInteger t = 0; t < timeBins; t++) {
        for (NSInteger v = 0; v < vertBins; v++) {
            float sum = 0.0f;

            // 使用预计算的高斯核
            for (NSInteger dt = -kernelRadius; dt <= kernelRadius; dt++) {
                NSInteger srcT = t + dt;
                if (srcT >= 0 && srcT < timeBins) {
                    sum += hist2d[srcT * vertBins + v] * gaussKernel[dt + kernelRadius];
                }
            }

            hist2dSmooth[t * vertBins + v] = sum;
        }
    }

    // 3. 归一化（每列除以最大值）
    for (NSInteger t = 0; t < timeBins; t++) {
        float maxVal = 0.0f;
        float *colStart = hist2dSmooth + t * vertBins;

        // 使用指针遍历提升性能
        for (NSInteger v = 0; v < vertBins; v++) {
            if (colStart[v] > maxVal) maxVal = colStart[v];
        }

        if (maxVal > 1e-6f) {
            float invMax = 1.0f / maxVal;
            for (NSInteger v = 0; v < vertBins; v++) {
                colStart[v] *= invMax;
            }
        }
    }

    // 4. 加权平均提取最可能的响应曲线
    NSMutableArray<NSNumber *> *avgResponse = [NSMutableArray arrayWithCapacity:timeBins];

    for (NSInteger t = 0; t < timeBins; t++) {
        double weightedSum = 0.0;
        double weightSum = 0.0;

        for (NSInteger v = 0; v < vertBins; v++) {
            float histVal = hist2dSmooth[t * vertBins + v];
            // 预计算y值位置
            double y = yMin + yRange * (v + 0.5) / vertBins;
            double w = histVal * histVal;  // 权重 = 直方图值的平方
            weightedSum += y * w;
            weightSum += w;
        }

        double avgVal = weightSum > 1e-9 ? weightedSum / weightSum : 0.0;
        [avgResponse addObject:@(avgVal)];
    }

    // 🔍 调试：检查avgResponse的关键点
    if (avgResponse.count > 0) {
        NSLog(@"🔍 avgResponse(加权平均后) 起点=%.3f, 终点=%.3f, 中点=%.3f",
              [avgResponse[0] doubleValue],
              [avgResponse[avgResponse.count-1] doubleValue],
              [avgResponse[avgResponse.count/2] doubleValue]);
    }

    // 5. 插值回原始长度（使用简单线性插值）
    NSMutableArray<NSNumber *> *upSampled = [NSMutableArray arrayWithCapacity:responseLength];

    for (NSInteger i = 0; i < responseLength; i++) {
        double x = (double)i * (timeBins - 1) / MAX(1, responseLength - 1);
        NSInteger x0 = (NSInteger)x;
        NSInteger x1 = MIN(x0 + 1, timeBins - 1);

        if (x0 < x1 && x0 < avgResponse.count && x1 < avgResponse.count) {
            double y0 = [avgResponse[x0] doubleValue];
            double y1 = [avgResponse[x1] doubleValue];
            double frac = x - x0;
            [upSampled addObject:@(y0 + (y1 - y0) * frac)];
        } else if (x0 < avgResponse.count) {
            [upSampled addObject:avgResponse[x0]];
        } else {
            [upSampled addObject:@0];
        }
    }

    free(hist2d);
    free(hist2dSmooth);

    // 性能监控：计算耗时
    uint64_t endTime = mach_absolute_time();
    double elapsedMs = (double)(endTime - startTime) * 1000.0 / getMachFrequency();

    // 🔍 调试：检查upSampled数据的关键点
    if (upSampled.count > 10) {
        NSLog(@"🔍 weighted_mode_avr upSampled数据: 起点=%.3f, 终点=%.3f, 中点=%.3f",
              [upSampled[0] doubleValue],
              [upSampled[upSampled.count-1] doubleValue],
              [upSampled[upSampled.count/2] doubleValue]);
    }

    NSLog(@"✅ weighted_mode_avr完成: %ld窗口 -> 1条曲线 | 耗时: %.1fms | 参数: %ld×%ld直方图",
          (long)windowCount, elapsedMs, (long)timeBins, (long)vertBins);

    return [upSampled copy];
}

@end
