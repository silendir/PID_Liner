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

        // 🔍 调试：检查第一个窗口的axisP和gyro原始值范围
        if (i == 0 && axisIndex == 0) {  // 只在Roll轴的第一个窗口打印
            double pMin = [axisPWindow[0] doubleValue], pMax = pMin;
            double gMin = [gyroWindow[0] doubleValue], gMax = gMin;
            for (NSNumber *num in axisPWindow) {
                double v = [num doubleValue];
                if (v < pMin) pMin = v; if (v > pMax) pMax = v;
            }
            for (NSNumber *num in gyroWindow) {
                double v = [num doubleValue];
                if (v < gMin) gMin = v; if (v > gMax) gMax = v;
            }
            NSLog(@"🔍 [原始数据窗口0] axisP范围: [%.1f, %.1f], gyro范围: [%.1f, %.1f], pGain=%.1f", pMin, pMax, gMin, gMax, pGain);
        }

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
    return [self initWithSampleRate:8000.0 cutFreq:25.0];  // 🔥 修复：Python使用cutfreq=25，不是150
}

- (instancetype)initWithSampleRate:(double)sampleRate
                           cutFreq:(double)cutFreq {
    self = [super init];
    if (self) {
        // 🔥 关键修复：存储实际采样率用于时间轴计算
        _sampleRate = sampleRate;
        _dt = 1.0 / sampleRate;
        _cutFreq = cutFreq;
        _pScale = kP_SCALE_FACTOR;

        // 🔥 关键：responseLen 保持固定值 4000
        // - windowSize 固定为 8000（在 PIDAnalysisViewController 中）
        // - 反卷积返回 windowSize/2 = 4000 列
        // - responseLen 应该匹配反卷积结果，固定为 4000
        // - 物理时间由 weightedModeAverage 中的 sampleRate 参数计算
        _responseLen = 4000;  // 固定值，对应 windowSize=8000

        _wienerDeconvolution = [[PIDWienerDeconvolution alloc] init];
        _wienerDeconvolution.dt = _dt;
        _fftProcessor = [[PIDFFTProcessor alloc] init];

        NSLog(@"🔍 [PIDTraceAnalyzer初始化] sampleRate=%.2fHz, dt=%.6f秒, responseLen=%ld (固定值)",
              _sampleRate, _dt, (long)_responseLen);
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

    // 🔍 调试：检查cumsum之前的值
    if (truncatedDeconv.count > 0 && truncatedDeconv[0].count > 0) {
        NSArray<NSNumber *> *firstRow = truncatedDeconv[0];
        double minVal = [firstRow[0] doubleValue], maxVal = minVal;
        for (NSNumber *num in firstRow) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 [cumsum之前] 反卷积结果范围: [%.3f, %.3f]", minVal, maxVal);
    }

    for (NSArray<NSNumber *> *row in truncatedDeconv) {
        if (row.count == 0) {
            [stepResponse addObject:@[]];
            continue;
        }

        // 直接对脉冲响应做累积和（与Python版本一致）
        NSArray<NSNumber *> *cumsum = [PIDInterpolation cumsum:row];
        [stepResponse addObject:cumsum];

        // 🔍 调试：打印第一个窗口的cumsum结果
        if (stepResponse.count == 1) {
            NSMutableString *s = [NSMutableString string];
            NSInteger n = MIN(20, cumsum.count);
            for (NSInteger i = 0; i < n; i++) {
                [s appendFormat:@"%.3f ", [cumsum[i] doubleValue]];
            }
            NSLog(@"🔍 [cumsum结果] 窗口0前%ld个值: %@", (long)n, s);
            NSLog(@"🔍 [cumsum结果] 窗口0: 起点=%.3f, 终点=%.3f, 跨度=%.3f",
                  [cumsum[0] doubleValue],
                  [cumsum[cumsum.count-1] doubleValue],
                  [cumsum[cumsum.count-1] doubleValue] - [cumsum[0] doubleValue]);
        }
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

    // 🔍 调试：打印maxInput的范围，帮助诊断low_high_mask问题
    if (maxIn.count > 0) {
        double minVal = [maxIn[0] doubleValue];
        double maxVal = [maxIn[0] doubleValue];
        for (NSNumber *num in maxIn) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 [关键] maxInput范围: [%.2f, %.2f]，阈值500将分类: low≤500, high>500", minVal, maxVal);

        // 统计有多少窗口超过500
        NSInteger highCount = 0;
        for (NSNumber *num in maxIn) {
            if ([num doubleValue] > 500.0) {
                highCount++;
            }
        }
        NSLog(@"🔍 [关键] maxInput > 500 的窗口数: %ld / %lu", (long)highCount, (unsigned long)maxIn.count);
    }

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

#pragma mark - 数据分离 (Mask)

/**
 * 计算低/高输入mask
 * 对应Python: low_high_mask(signal, threshold)
 *
 * @param maxInArray 每个窗口的最大输入值 (max_in)
 * @param threshold 阈值（单位：°/s）
 * @return @{@"low": lowMask, @"high": highMask}
 */
+ (NSDictionary<NSString *, NSArray<NSNumber *> *> *)lowHighMask:(NSArray<NSNumber *> *)maxInArray
                                                      threshold:(double)threshold {
    if (!maxInArray || maxInArray.count == 0) {
        return @{@"low": @[], @"high": @[]};
    }

    // 🔍 调试：打印maxInArray的实际值
    NSMutableString *valuesStr = [NSMutableString string];
    NSInteger printCount = MIN(10, maxInArray.count);
    for (NSInteger i = 0; i < printCount; i++) {
        [valuesStr appendFormat:@"%.1f ", [maxInArray[i] doubleValue]];
    }
    if (maxInArray.count > 10) {
        [valuesStr appendString:@"..."];
    }
    NSLog(@"🔍 low_high_mask(threshold=%.0f): maxInArray值 = [%@]", threshold, valuesStr);

    NSMutableArray<NSNumber *> *lowMask = [NSMutableArray arrayWithCapacity:maxInArray.count];
    NSMutableArray<NSNumber *> *highMask = [NSMutableArray arrayWithCapacity:maxInArray.count];

    NSInteger highCount = 0;

    for (NSNumber *maxInNum in maxInArray) {
        double maxIn = [maxInNum doubleValue];

        // low: 小于等于阈值 → 1
        // high: 大于阈值 → 1
        if (maxIn <= threshold) {
            [lowMask addObject:@1.0];
            [highMask addObject:@0.0];
        } else {
            [lowMask addObject:@0.0];
            [highMask addObject:@1.0];
            highCount++;
        }
    }

    // 如果高输入数据太少（<10个窗口），忽略
    // 对应Python: if high.sum() < 10: high *= 0.
    if (highCount < 10) {
        for (NSInteger i = 0; i < highMask.count; i++) {
            highMask[i] = @0.0;
        }
        NSLog(@"⚠️ low_high_mask: 高输入窗口数(%ld) < 10，忽略高输入数据", (long)highCount);
    } else {
        NSLog(@"✅ low_high_mask(threshold=%.0f): 低输入=%ld窗口, 高输入=%ld窗口",
              threshold, (long)(maxInArray.count - highCount), (long)highCount);
    }

    return @{@"low": [lowMask copy], @"high": [highMask copy]};
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
 * 加权模式平均 - 完全对齐Python算法
 * 对应Python: weighted_mode_avr()
 *
 * 🔥 关键修复：
 * 1. 使用物理时间轴（0-0.5秒）代替数组索引
 * 2. 展平所有数据后再构建histogram2d
 * 3. 完全匹配Python的np.histogram2d行为
 *
 * Python代码参考:
 *   times = np.repeat(np.array([self.time_resp]), len(values), axis=0)
 *   hist2d = np.histogram2d(
 *       times.flatten(),
 *       values.flatten(),
 *       range=[[self.time_resp[0], self.time_resp[-1]], vertrange],
 *       bins=[len(times[0]), vertbins],
 *       weights=weights.flatten()
 *   )[0].transpose()
 */
+ (NSArray<NSNumber *> *)weightedModeAverageWithStepResponse:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                                   avgTime:(NSArray<NSNumber *> *)avgTime
                                                  dataMask:(NSArray<NSNumber *> *)dataMask
                                                vertRange:(NSArray<NSNumber *> *)vertRange
                                                 vertBins:(NSInteger)vertBins
                                              sampleRate:(double)sampleRate {

    // 性能监控：开始时间
    uint64_t startTime = mach_absolute_time();

    // ========== 1. 参数验证 ==========
    if (!stepResponse || stepResponse.count == 0) {
        return @[];
    }

    NSInteger windowCount = stepResponse.count;
    NSInteger responseLen = stepResponse[0].count;  // rlen = 4000

    if (responseLen == 0) return @[];

    // ========== 2. 范围参数 ==========
    double yMin = [vertRange[0] doubleValue];
    double yMax = [vertRange[1] doubleValue];

    // ========== 3. 生成time_resp（匹配Python） ==========
    // Python: self.time_resp = self.time[0:self.rlen] - self.time[0]
    // Python的self.time是通过linspace生成的，所以我们也需要使用linspace
    // Python: newtime = np.linspace(time[0], time[-1], len(time), dtype=np.float64)
    //       self.time_resp = self.time[0:rlen] - self.time[0]

    // 🔥 关键修复：使用实际采样率计算时间轴
    // Python: self.rlen = self.stepcalc(self.time, Trace.resplen)  # resplen = 0.5秒
    // 也就是说 rlen = 0.5 * sampleRate
    // 所以 time_resp 应该是 0 到 0.5 秒，包含 rlen 个点
    // 但实际 responseLen 可能不等于 0.5 * sampleRate（因为数据截断）
    // 所以我们用 responseLen 个点来表示 0.5 秒的时间（与Python保持一致）

    // 🔥 关键修复：使用实际采样率计算正确的时间间隔
    // dt = 1 / sampleRate，这是每个采样点之间的实际时间间隔
    double dt = 1.0 / sampleRate;

    // timeResp 的长度应该等于 responseLen
    // 时间从 0 开始，每个点间隔 dt
    // 但注意：Python的time_resp是取前rlen个点，rlen = stepcalc(time, resplen)
    // 如果数据长度不足rlen，则取实际长度
    // 所以 timeResp 的终点是 (responseLen - 1) * dt

    NSMutableArray<NSNumber *> *timeResp = [NSMutableArray arrayWithCapacity:responseLen];
    for (NSInteger i = 0; i < responseLen; i++) {
        // 使用实际采样间隔：t = i * dt
        double t = i * dt;
        [timeResp addObject:@(t)];
    }

    double timeMin = [timeResp[0] doubleValue];      // 0.0
    double timeMax = [timeResp[responseLen - 1] doubleValue];  // 0.5（精确）

    NSLog(@"🔍 [Python对齐] time_resp: 起点=%.6f, 终点=%.6f, 长度=%ld",
          timeMin, timeMax, (long)timeResp.count);

    // ========== 4. 展平数据（匹配Python的flatten） ==========
    // Python: times.flatten(), values.flatten(), weights.flatten()

    // 先计算展平后需要的容量
    NSInteger validWindowCount = 0;
    for (NSInteger w = 0; w < windowCount; w++) {
        double weight = 1.0;
        if (dataMask && w < dataMask.count) {
            weight = [dataMask[w] doubleValue];
        }
        if (weight > 0.5) {
            validWindowCount++;
        }
    }

    NSInteger totalPoints = validWindowCount * responseLen;

    NSMutableArray<NSNumber *> *flatTimes = [NSMutableArray arrayWithCapacity:totalPoints];
    NSMutableArray<NSNumber *> *flatValues = [NSMutableArray arrayWithCapacity:totalPoints];
    NSMutableArray<NSNumber *> *flatWeights = [NSMutableArray arrayWithCapacity:totalPoints];

    for (NSInteger w = 0; w < windowCount; w++) {
        NSArray<NSNumber *> *windowResp = stepResponse[w];
        if (!windowResp || windowResp.count != responseLen) continue;

        // 获取该窗口的权重
        double weight = 1.0;
        if (dataMask && w < dataMask.count) {
            weight = [dataMask[w] doubleValue];
        }

        // 如果weight为0，跳过此窗口
        if (weight < 0.5) continue;

        // 展平该窗口的数据
        for (NSInteger i = 0; i < responseLen; i++) {
            [flatTimes addObject:timeResp[i]];      // 使用物理时间，不是索引
            [flatValues addObject:windowResp[i]];
            [flatWeights addObject:@(weight)];
        }
    }

    NSLog(@"🔍 [Python对齐] 展平后数据点数: %lu (windowCount=%ld, responseLen=%ld)",
          (unsigned long)flatTimes.count, (long)windowCount, (long)responseLen);

    // ========== 5. 构建histogram2d（使用新的辅助方法） ==========
    NSInteger timeBins = responseLen;
    float *hist2d = [self buildHistogram2D:flatTimes
                                    values:flatValues
                                   weights:flatWeights
                                  timeMin:timeMin
                                  timeMax:timeMax
                                 valueMin:yMin
                                 valueMax:yMax
                           timeBinsCount:timeBins
                           vertBinsCount:vertBins];

    if (!hist2d) {
        NSLog(@"❌ histogram2d构建失败");
        return @[];
    }

    NSLog(@"🔍 [Python对齐] hist2d构建完成: shape=[%ld, %ld]",
          (long)vertBins, (long)timeBins);

    // ========== 6. 高斯平滑（垂直方向，axis=0） ==========
    // Python: gaussian_filter1d(hist2d, filt_width=7, axis=0, mode='constant')
    // 在scipy的gaussian_filter1d中，第二个参数是sigma，不是某种"宽度"
    // 所以 filt_width=7 意味着 sigma=7
    double filtWidth = 7.0;
    double sigma = filtWidth;  // 🔥 关键修复：sigma直接使用filtWidth，不是filtWidth/3

    NSInteger histSize = vertBins * timeBins;
    float *hist2dSmooth = (float *)malloc(histSize * sizeof(float));

    // 预计算高斯核
    // 核半径应该覆盖足够大的范围，通常 ±4σ 可以覆盖99.99%的高斯分布
    // scipy的gaussian_filter1d使用 truncate=4.0（默认值）
    NSInteger kernelRadius = (NSInteger)ceil(4.0 * sigma);
    NSInteger kernelSize = 2 * kernelRadius + 1;
    float *gaussKernel = (float *)malloc(kernelSize * sizeof(float));
    double kernelSum = 0.0;

    for (NSInteger dv = -kernelRadius; dv <= kernelRadius; dv++) {
        // 高斯公式: exp(-x² / (2σ²))
        double g = exp(-(dv * dv) / (2.0 * sigma * sigma));
        gaussKernel[dv + kernelRadius] = (float)g;
        kernelSum += g;
    }
    // 归一化核
    for (NSInteger i = 0; i < kernelSize; i++) {
        gaussKernel[i] /= (float)kernelSum;
    }

    // 🔥 关键修复：应用高斯平滑（沿垂直方向，axis=0）
    // 完全匹配scipy的gaussian_filter1d(hist2d, sigma, axis=0, mode='constant')
    // mode='constant' 表示边界外填充0（不跳过，而是使用0值）
    for (NSInteger t = 0; t < timeBins; t++) {
        for (NSInteger v = 0; v < vertBins; v++) {
            float sum = 0.0f;

            for (NSInteger dv = -kernelRadius; dv <= kernelRadius; dv++) {
                NSInteger srcV = v + dv;
                // 🔑 关键：与scipy的mode='constant'一致，边界外视为0值
                // 不需要if检查，因为0值对sum没有影响，但需要正确访问hist2d
                if (srcV >= 0 && srcV < vertBins) {
                    sum += hist2d[srcV * timeBins + t] * gaussKernel[dv + kernelRadius];
                }
                // else: 越界部分视为0（mode='constant'），不添加到sum中
            }

            hist2dSmooth[v * timeBins + t] = sum;
        }
    }

    free(gaussKernel);
    free(hist2d);

    // ========== 7. 归一化（每列除以最大值） ==========
    // Python: hist2d_sm /= np.max(hist2d_sm, 0)
    for (NSInteger t = 0; t < timeBins; t++) {
        float maxVal = 0.0f;

        // 找每列的最大值
        for (NSInteger v = 0; v < vertBins; v++) {
            float val = hist2dSmooth[v * timeBins + t];
            if (val > maxVal) maxVal = val;
        }

        // 归一化
        if (maxVal > 1e-6f) {
            float invMax = 1.0f / maxVal;
            for (NSInteger v = 0; v < vertBins; v++) {
                hist2dSmooth[v * timeBins + t] *= invMax;
            }
        }
    }

    // ========== 8. 生成resp_y（匹配Python的linspace） ==========
    // Python: resp_y = np.linspace(vertrange[0], vertrange[-1], vertbins, dtype=np.float64)
    NSArray<NSNumber *> *respY = [self linspaceFrom:yMin to:yMax count:vertBins];

    NSLog(@"🔍 [Python对齐] resp_y: 起点=%.6f, 终点=%.6f, 长度=%lu",
          [respY[0] doubleValue],
          [respY[respY.count - 1] doubleValue],
          (unsigned long)respY.count);

    // 🔍 调试：分析hist2d的分布特征 - 检查前10个和关键降采样点
    NSLog(@"🔍 [Hist2D分析] 检查关键时间点的hist2d分布:");

    // 检查点：前10个 + 降采样关键位置 (40, 80, 120, ...)
    NSInteger checkPoints[] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 40, 80, 120, 160, 200, 400, 800, 1200, 1600, 2000, 3000, 3999};
    NSInteger numCheckPoints = sizeof(checkPoints) / sizeof(checkPoints[0]);

    for (NSInteger idx = 0; idx < numCheckPoints; idx++) {
        NSInteger t = checkPoints[idx];
        if (t >= timeBins) continue;

        // 找每列的峰值位置（加权平均）
        float weightedPos = 0.0f;
        float totalWeight = 0.0f;
        float maxHistVal = 0.0f;
        NSInteger maxBin = 0;

        for (NSInteger v = 0; v < vertBins; v++) {
            float histVal = hist2dSmooth[v * timeBins + t];
            if (histVal > maxHistVal) {
                maxHistVal = histVal;
                maxBin = v;
            }
            double y = [respY[v] doubleValue];
            float w = histVal * histVal;
            weightedPos += y * w;
            totalWeight += w;
        }
        double avgPos = totalWeight > 1e-9f ? weightedPos / totalWeight : 0.0;

        // 检查是否有多个峰值（双峰分布会导致振荡）
        float secondMaxVal = 0.0f;
        NSInteger secondMaxBin = -1;
        for (NSInteger v = 0; v < vertBins; v++) {
            float histVal = hist2dSmooth[v * timeBins + t];
            if (histVal > secondMaxVal && v != maxBin) {
                secondMaxVal = histVal;
                secondMaxBin = v;
            }
        }

        NSLog(@"  t[%4ld]: 加权平均=%.6f, maxHist=%.4f@bin%ld, 2ndMax=%.4f@bin%ld, ratio=%.2f",
              (long)t, avgPos, maxHistVal, (long)maxBin, secondMaxVal, (long)secondMaxBin,
              maxHistVal > 0 ? secondMaxVal / maxHistVal : 0);
    }

    // ========== 9. 加权平均（使用平方权重） ==========
    // Python: avr = np.average(pixelpos, 0, weights=hist2d_sm * hist2d_sm)
    // pixelpos = np.repeat(resp_y.reshape(len(resp_y), 1), len(times[0]), axis=1)

    NSMutableArray<NSNumber *> *avgResponse = [NSMutableArray arrayWithCapacity:timeBins];

    for (NSInteger t = 0; t < timeBins; t++) {
        double weightedSum = 0.0;
        double weightSum = 0.0;

        for (NSInteger v = 0; v < vertBins; v++) {
            float histVal = hist2dSmooth[v * timeBins + t];
            double y = [respY[v] doubleValue];
            double w = histVal * histVal;  // 平方权重

            weightedSum += y * w;
            weightSum += w;
        }

        double avgVal = weightSum > 1e-9 ? weightedSum / weightSum : 0.0;
        [avgResponse addObject:@(avgVal)];
    }

    free(hist2dSmooth);

    // ========== 10. 输出验证日志 ==========
    if (avgResponse.count > 0) {
        double firstVal = [avgResponse[0] doubleValue];
        double lastVal = [avgResponse[avgResponse.count - 1] doubleValue];

        // 找最大最小值
        double minVal = firstVal;
        double maxVal = firstVal;
        for (NSInteger i = 1; i < avgResponse.count; i++) {
            double v = [avgResponse[i] doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }

        NSLog(@"📊 [最终结果] avgResponse统计:");
        NSLog(@"  起点: %.6f (Python参考: ~0.8-1.0)", firstVal);
        NSLog(@"  终点: %.6f (Python参考: ~1.3-1.5)", lastVal);
        NSLog(@"  最小值: %.6f", minVal);
        NSLog(@"  最大值: %.6f", maxVal);

        // 打印前5个和后5个值
        NSLog(@"📊 [最终结果] 前5个值:");
        for (NSInteger i = 0; i < MIN(5, avgResponse.count); i++) {
            NSLog(@"  [%ld] = %.6f", (long)i, [avgResponse[i] doubleValue]);
        }
        NSLog(@"📊 [最终结果] 后5个值:");
        for (NSInteger i = MAX(0, avgResponse.count - 5); i < avgResponse.count; i++) {
            NSLog(@"  [%ld] = %.6f", (long)i, [avgResponse[i] doubleValue]);
        }

        // 🔍 新增：检查降采样位置的数据（匹配PIDAnalysisViewController的降采样逻辑）
        NSLog(@"🔍 [降采样检查] 降采样到100点时的采样位置:");
        NSInteger displayPoints = 100;
        for (NSInteger i = 0; i < MIN(10, displayPoints); i++) {
            NSInteger srcIndex = (i * avgResponse.count) / displayPoints;
            double val = [avgResponse[srcIndex] doubleValue];
            NSLog(@"  display[%ld] = avgResponse[%ld] = %.6f", (long)i, (long)srcIndex, val);
        }
    }

    // 性能监控
    uint64_t endTime = mach_absolute_time();
    double elapsedMs = (double)(endTime - startTime) * 1000.0 / getMachFrequency();

    NSLog(@"✅ weighted_mode_avr完成: %ld窗口 -> 1条曲线 | 耗时: %.1fms",
          (long)windowCount, elapsedMs);

    return [avgResponse copy];
}

/**
 * 加权模式平均 - 兼容旧版本（全部窗口权重为1）
 * @deprecated 使用 dataMask 版本代替
 */
+ (NSArray<NSNumber *> *)weightedModeAverageWithStepResponse:(NSArray<NSArray<NSNumber *> *> *)stepResponse
                                                   avgTime:(NSArray<NSNumber *> *)avgTime
                                                  maxInput:(NSArray<NSNumber *> *)maxInput
                                                vertRange:(NSArray<NSNumber *> *)vertRange
                                                 vertBins:(NSInteger)vertBins {
    // 旧版本：不使用mask，所有窗口权重为1
    // 传入 nil 作为 dataMask
    // 🔥 兼容性修复：旧版本默认使用 8kHz 采样率
    return [self weightedModeAverageWithStepResponse:stepResponse
                                             avgTime:avgTime
                                            dataMask:nil  // 不使用mask，保留所有窗口
                                          vertRange:vertRange
                                           vertBins:vertBins
                                        sampleRate:8000.0];  // 默认8kHz
}

#pragma mark - 辅助方法（Python算法对齐）

/**
 * 生成linspace序列，匹配Python的np.linspace
 * np.linspace(a, b, n) 返回 n 个点，从 a 到 b（包含两端）
 */
+ (NSArray<NSNumber *> *)linspaceFrom:(double)start to:(double)end count:(NSInteger)count {
    if (count < 1) return @[];
    if (count == 1) return @[@(start)];

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger i = 0; i < count; i++) {
        // np.linspace: 从 a 到 b 均匀分布 n 个点
        double value = start + (end - start) * i / (count - 1);
        [result addObject:@(value)];
    }
    return [result copy];
}

/**
 * 构建histogram2d，完全匹配Python的np.histogram2d
 *
 * Python代码:
 *   hist2d = np.histogram2d(
 *       times.flatten(),
 *       values.flatten(),
 *       range=[[time_min, time_max], [value_min, value_max]],
 *       bins=[time_bins, vert_bins],
 *       weights=weights.flatten()
 *   )[0].transpose()  # 转置为 [vertbins, timebins]
 *
 * 返回: 转置后的hist2d [vertBins, timeBins]，需要调用者释放
 */
+ (float *)buildHistogram2D:(NSArray<NSNumber *> *)times
                     values:(NSArray<NSNumber *> *)values
                    weights:(NSArray<NSNumber *> *)weights
                   timeMin:(double)timeMin
                   timeMax:(double)timeMax
                  valueMin:(double)valueMin
                  valueMax:(double)valueMax
            timeBinsCount:(NSInteger)timeBins
            vertBinsCount:(NSInteger)vertBins {

    // 1. 分配内存：先按 [timebins, vertbins] 存储，然后转置
    NSInteger histSize = timeBins * vertBins;
    float *hist2d = (float *)calloc(histSize, sizeof(float));
    if (!hist2d) return nil;

    // 2. 🔥 关键修复：添加小的epsilon以处理浮点精度问题
    // numpy的histogram2d使用半开区间 [a, b)，但最后一个bin会包含最大值
    // 为了避免浮点精度导致边界值被错误分配，稍微扩大range上限
    double epsilon = 1e-9;
    double timeMaxEffective = timeMax + epsilon * (timeMax - timeMin);
    double valueMaxEffective = valueMax + epsilon * (valueMax - valueMin);

    double timeSpan = timeMaxEffective - timeMin;
    double vertSpan = valueMaxEffective - valueMin;

    // 避免除零
    if (timeSpan <= 0) timeSpan = 1.0;
    if (vertSpan <= 0) vertSpan = 1.0;

    // 3. 填充hist2d
    // numpy的histogram2d返回 [timebins, vertbins]
    // 我们先按 [timebins, vertbins] 填充，然后转置为 [vertbins, timebins]
    for (NSUInteger i = 0; i < times.count; i++) {
        double t = [times[i] doubleValue];
        double v = [values[i] doubleValue];
        double w = weights ? [weights[i] doubleValue] : 1.0;

        // 计算bin索引（精确匹配numpy的histogram2d行为）
        // numpy: bin = floor((x - range[0]) / (range[1] - range[0]) * nbins)
        // 对于 [a, b) 范围，x=b 时 bin=nb，所以需要clamp
        double tRatio = (t - timeMin) / timeSpan;
        double vRatio = (v - valueMin) / vertSpan;

        // clamp到[0, 1]范围
        if (tRatio < 0.0) tRatio = 0.0;
        if (tRatio > 1.0) tRatio = 1.0;
        if (vRatio < 0.0) vRatio = 0.0;
        if (vRatio > 1.0) vRatio = 1.0;

        // 计算bin索引（现在不会超出范围）
        NSInteger tBin = (NSInteger)floor(tRatio * timeBins);
        NSInteger vBin = (NSInteger)floor(vRatio * vertBins);

        // 额外的边界检查（理论上不需要，但为了安全）
        if (tBin < 0) tBin = 0;
        if (tBin >= timeBins) tBin = timeBins - 1;
        if (vBin < 0) vBin = 0;
        if (vBin >= vertBins) vBin = vertBins - 1;

        // 填充 [timebins, vertbins]
        hist2d[tBin * vertBins + vBin] += w;
    }

    // 4. 转置为 [vertbins, timebins] 以匹配Python的.transpose()
    float *transposed = (float *)malloc(histSize * sizeof(float));
    if (!transposed) {
        free(hist2d);
        return nil;
    }

    for (NSInteger t = 0; t < timeBins; t++) {
        for (NSInteger v = 0; v < vertBins; v++) {
            transposed[v * timeBins + t] = hist2d[t * vertBins + v];
        }
    }

    free(hist2d);
    return transposed;
}

@end
