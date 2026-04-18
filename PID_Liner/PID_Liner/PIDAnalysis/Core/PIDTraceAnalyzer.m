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

    // 🔍 调试：打印窗口0的原始输入数据（应用Hanning窗之前）
    if (windowCount > 0) {
        NSArray<NSNumber *> *rawIn = stacks.input[0];
        NSArray<NSNumber *> *rawOut = stacks.gyro[0];

        // 计算输入数据范围
        double inMin = [rawIn[0] doubleValue], inMax = inMin;
        for (NSNumber *n in rawIn) {
            double v = [n doubleValue];
            if (v < inMin) inMin = v;
            if (v > inMax) inMax = v;
        }

        double outMin = [rawOut[0] doubleValue], outMax = outMin;
        for (NSNumber *n in rawOut) {
            double v = [n doubleValue];
            if (v < outMin) outMin = v;
            if (v > outMax) outMax = v;
        }

        NSLog(@"🔍 [原始数据窗口0] input范围: [%.3f, %.3f], 前5个值: %.3f, %.3f, %.3f, %.3f, %.3f",
              inMin, inMax,
              [rawIn[0] doubleValue], [rawIn[1] doubleValue], [rawIn[2] doubleValue],
              [rawIn[3] doubleValue], [rawIn[4] doubleValue]);
        NSLog(@"🔍 [原始数据窗口0] gyro(output)范围: [%.3f, %.3f], 前5个值: %.3f, %.3f, %.3f, %.3f, %.3f",
              outMin, outMax,
              [rawOut[0] doubleValue], [rawOut[1] doubleValue], [rawOut[2] doubleValue],
              [rawOut[3] doubleValue], [rawOut[4] doubleValue]);

        // Hanning窗前5个值
        NSMutableString *winStr = [NSMutableString string];
        for (NSInteger i = 0; i < 5; i++) {
            [winStr appendFormat:@"%.6f ", [win[i] doubleValue]];
        }
        NSLog(@"🔍 [Hanning窗] 前5个值: %@", winStr);
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

    // 🔍 调试：打印应用Hanning窗后的输入数据
    if (inp.count > 0) {
        NSArray<NSNumber *> *winIn = inp[0];
        NSArray<NSNumber *> *winOut = outp[0];

        double winInMin = [winIn[0] doubleValue], winInMax = winInMin;
        for (NSNumber *n in winIn) {
            double v = [n doubleValue];
            if (v < winInMin) winInMin = v;
            if (v > winInMax) winInMax = v;
        }

        double winOutMin = [winOut[0] doubleValue], winOutMax = winOutMin;
        for (NSNumber *n in winOut) {
            double v = [n doubleValue];
            if (v < winOutMin) winOutMin = v;
            if (v > winOutMax) winOutMax = v;
        }

        NSLog(@"🔍 [加窗后窗口0] input范围: [%.6f, %.6f], 前5个值: %.6f, %.6f, %.6f, %.6f, %.6f",
              winInMin, winInMax,
              [winIn[0] doubleValue], [winIn[1] doubleValue], [winIn[2] doubleValue],
              [winIn[3] doubleValue], [winIn[4] doubleValue]);
        NSLog(@"🔍 [加窗后窗口0] gyro范围: [%.6f, %.6f], 前5个值: %.6f, %.6f, %.6f, %.6f, %.6f",
              winOutMin, winOutMax,
              [winOut[0] doubleValue], [winOut[1] doubleValue], [winOut[2] doubleValue],
              [winOut[3] doubleValue], [winOut[4] doubleValue]);
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

    // 🔍 调试：检查cumsum之前的值（详细版本）
    if (truncatedDeconv.count > 0 && truncatedDeconv[0].count > 0) {
        NSArray<NSNumber *> *firstRow = truncatedDeconv[0];
        double minVal = [firstRow[0] doubleValue], maxVal = minVal;
        for (NSNumber *num in firstRow) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🔍 [cumsum之前] 反卷积结果范围: [%.3f, %.3f], 前5个值: %.3f, %.3f, %.3f, %.3f, %.3f",
              minVal, maxVal,
              [firstRow[0] doubleValue], [firstRow[1] doubleValue], [firstRow[2] doubleValue],
              [firstRow[3] doubleValue], [firstRow[4] doubleValue]);
    }

    for (NSArray<NSNumber *> *row in truncatedDeconv) {
        if (row.count == 0) {
            [stepResponse addObject:@[]];
            continue;
        }

        // 直接对脉冲响应做累积和
        // Python: delta_resp = deconvolved_sm.cumsum(axis=1)
        // 注意：不去除DC偏移，Python也是直接cumsum
        NSArray<NSNumber *> *cumsum = [PIDInterpolation cumsum:row];

        [stepResponse addObject:cumsum];

        // 🔍 调试：打印第一个窗口的cumsum结果
        if (stepResponse.count == 1) {
            NSMutableString *s = [NSMutableString string];
            NSInteger n = MIN(10, cumsum.count);
            for (NSInteger i = 0; i < n; i++) {
                [s appendFormat:@"%.3f ", [cumsum[i] doubleValue]];
            }
            NSLog(@"🔍 [cumsum结果] 窗口0前%ld个值: %@", (long)n, s);
            NSLog(@"🔍 [cumsum结果] 起点=%.3f, 终点=%.3f, 跨度=%.3f",
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

    // 🔍 新增：打印输入参数
    NSLog(@"🔍 [输入参数] stepResponse: windowCount=%ld, responseLen=%ld",
          (long)windowCount, (long)responseLen);
    NSLog(@"🔍 [输入参数] vertRange: [%.2f, %.2f], vertBins=%ld",
          yMin, yMax, (long)vertBins);
    NSLog(@"🔍 [输入参数] dataMask: count=%lu",
          dataMask ? (unsigned long)dataMask.count : 0);

    // 🔍 新增：检查输入数据的范围（前几个窗口）
    NSLog(@"🔍 [输入数据检查] 检查前3个窗口的stepResponse范围:");
    for (NSInteger w = 0; w < MIN(3, windowCount); w++) {
        NSArray<NSNumber *> *windowResp = stepResponse[w];
        if (windowResp && windowResp.count > 0) {
            double minVal = [windowResp[0] doubleValue];
            double maxVal = minVal;
            for (NSNumber *num in windowResp) {
                double v = [num doubleValue];
                if (v < minVal) minVal = v;
                if (v > maxVal) maxVal = v;
            }
            NSLog(@"  窗口[%ld]: 范围=[%.6f, %.6f], 起点=%.6f, 终点=%.6f",
                  (long)w, minVal, maxVal, [windowResp[0] doubleValue],
                  [windowResp[windowResp.count-1] doubleValue]);
        }
    }

    // ========== 3. 生成time_resp（匹配Python） ==========
    // Python: self.rlen = self.stepcalc(self.time, Trace.resplen)  # resplen = 0.5秒
    // 也就是说 time_resp 代表 0 到 0.5 秒的时间范围
    //
    // 🔥 关键修复：时间范围固定为 0.5 秒，不依赖于传入的 sampleRate
    // - responseLen 是实际的数据点数（由反卷积结果决定）
    // - 无论 responseLen 是多少，时间范围始终是 [0, 0.5] 秒
    // - dt = 0.5 / responseLen，确保 (responseLen-1) * dt ≈ 0.5
    //
    // 注意：传入的 sampleRate 参数是原始数据的采样率，用于窗口大小计算
    // 但加权平均的时间轴应该始终对应 0.5 秒的响应时长

    double responseDuration = 0.5;  // Python 的 resplen = 0.5 秒
    double dt = responseDuration / (responseLen > 1 ? responseLen - 1 : 1);

    // 使用 linspace 生成均匀时间轴 [0, 0.5] 秒
    NSMutableArray<NSNumber *> *timeResp = [NSMutableArray arrayWithCapacity:responseLen];
    for (NSInteger i = 0; i < responseLen; i++) {
        double t = responseDuration * i / (responseLen > 1 ? responseLen - 1 : 1);
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

    // 🔍 新增：检查展平后的数据范围
    if (flatValues.count > 0) {
        double flatMin = [flatValues[0] doubleValue];
        double flatMax = flatMin;
        for (NSNumber *num in flatValues) {
            double v = [num doubleValue];
            if (v < flatMin) flatMin = v;
            if (v > flatMax) flatMax = v;
        }
        NSLog(@"🔍 [展平数据] flatValues范围: [%.6f, %.6f], 点数=%lu",
              flatMin, flatMax, (unsigned long)flatValues.count);
        NSLog(@"🔍 [展平数据] 前5个值: %.6f, %.6f, %.6f, %.6f, %.6f",
              [flatValues[0] doubleValue], [flatValues[1] doubleValue],
              [flatValues[2] doubleValue], [flatValues[3] doubleValue],
              [flatValues[4] doubleValue]);
    }

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

    // 🔍 新增：检查hist2d的统计信息
    float histSum = 0.0f;
    float histMax = 0.0f;
    NSInteger nonZeroCount = 0;
    for (NSInteger i = 0; i < vertBins * timeBins; i++) {
        float v = hist2d[i];
        histSum += v;
        if (v > histMax) histMax = v;
        if (v > 1e-6f) nonZeroCount++;
    }
    NSLog(@"🔍 [hist2d统计] sum=%.6f, max=%.6f, 非零点=%ld/%ld",
          histSum, histMax, (long)nonZeroCount, (long)(vertBins * timeBins));

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

    // 🔍 新增：分析第一个和最后一个时间点的加权平均计算
    NSMutableArray<NSNumber *> *timePointsToAnalyze = [NSMutableArray arrayWithObjects:@(0), @(timeBins-1), nil];
    // 添加一些中间点
    for (NSInteger i = 1; i < 5; i++) {
        NSInteger idx = i * timeBins / 5;
        [timePointsToAnalyze addObject:@(idx)];
    }

    for (NSInteger t = 0; t < timeBins; t++) {
        double weightedSum = 0.0;
        double weightSum = 0.0;

        // 🔍 新增：记录关键统计信息
        double maxY_at_this_t = -HUGE_VAL;
        double minY_with_weight = HUGE_VAL;
        double maxY_with_weight = -HUGE_VAL;

        for (NSInteger v = 0; v < vertBins; v++) {
            float histVal = hist2dSmooth[v * timeBins + t];
            double y = [respY[v] doubleValue];
            double w = histVal * histVal;  // 平方权重

            if (w > 1e-9) {
                if (y < minY_with_weight) minY_with_weight = y;
                if (y > maxY_with_weight) maxY_with_weight = y;
            }
            if (histVal > maxY_at_this_t) maxY_at_this_t = histVal;

            weightedSum += y * w;
            weightSum += w;
        }

        double avgVal = weightSum > 1e-9 ? weightedSum / weightSum : 0.0;
        [avgResponse addObject:@(avgVal)];

        // 🔍 新增：打印关键时间点的详细信息
        if ([timePointsToAnalyze containsObject:@(t)]) {
            NSLog(@"🔍 [加权平均详情] t[%ld]:", (long)t);
            NSLog(@"  加权平均结果: %.6f", avgVal);
            NSLog(@"  有权重的resp_y范围: [%.6f, %.6f]", minY_with_weight, maxY_with_weight);
            NSLog(@"  最大histVal: %.6f", maxY_at_this_t);
            NSLog(@"  weightSum: %.6f", weightSum);
        }
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

    // 🔥 关键修复：阶跃响应应该从0开始，表示相对于初始状态的变化
    // weighted_mode_avr 计算的是绝对位置的加权平均，需要减去初始值得到相对变化
    // 例如：如果加权平均结果是 [0.97, 1.10, 1.20]，减去0.97后得到 [0, 0.13, 0.23]
    if (avgResponse.count > 0) {
        double baseValue = [avgResponse[0] doubleValue];
        NSLog(@"🔍 [零点调整] 加权平均原始起点=%.6f，对所有值减去baseValue", baseValue);

        for (NSInteger i = 0; i < avgResponse.count; i++) {
            double adjustedVal = [avgResponse[i] doubleValue] - baseValue;
            avgResponse[i] = @(adjustedVal);
        }

        NSLog(@"🔍 [零点调整] 调整后起点=%.6f，终点=%.6f",
              [avgResponse[0] doubleValue], [avgResponse[avgResponse.count-1] doubleValue]);
    }

    // 🎯 关键输出：最终结果范围
    if (avgResponse.count > 0) {
        double minVal = [avgResponse[0] doubleValue];
        double maxVal = minVal;
        for (NSNumber *num in avgResponse) {
            double v = [num doubleValue];
            if (v < minVal) minVal = v;
            if (v > maxVal) maxVal = v;
        }
        NSLog(@"🎯🎯🎯 [最终结果] 起点=%.3f, 终点=%.3f, 跨度=%.3f (点数=%lu)",
              [avgResponse[0] doubleValue], [avgResponse[avgResponse.count-1] doubleValue],
              [avgResponse[avgResponse.count-1] doubleValue] - [avgResponse[0] doubleValue],
              (unsigned long)avgResponse.count);
    }

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

    // 🔥 关键修复：numpy histogram2d 会忽略超出 range 的值！
    // 测试证明：numpy.histogram2d(values, range=[a, b]) 会忽略 <a 或 >b 的值
    // iOS 之前的实现是把超范围值 clamp 到边界，这是错误的！

    NSInteger ignoredCount = 0;  // 🎯 统计被忽略的值数量
    NSInteger processedCount = 0;  // 🎯 统计被处理的值数量

    for (NSUInteger i = 0; i < times.count; i++) {
        double t = [times[i] doubleValue];
        double v = [values[i] doubleValue];
        double w = weights ? [weights[i] doubleValue] : 1.0;

        // 🔥 关键修复：检查是否超出范围（numpy行为：超范围值被忽略）
        // 对于半开区间 [a, b)，值 < a 或 >= b 都被视为超范围
        // 但 numpy 对边界值有特殊处理：等于 a 的值计入第一个 bin
        // 等于 b 的值也计入最后一个 bin（因为 epsilon 处理）
        if (t < timeMin || t >= timeMaxEffective) {
            ignoredCount++;
            continue;  // 🎯 跳过超出时间范围的值
        }
        if (v < valueMin || v >= valueMaxEffective) {
            ignoredCount++;
            continue;  // 🎯 跳过超出值范围的值
        }

        processedCount++;

        // 计算bin索引（精确匹配numpy的histogram2d行为）
        // numpy: bin = floor((x - range[0]) / (range[1] - range[0]) * nbins)
        double tRatio = (t - timeMin) / timeSpan;
        double vRatio = (v - valueMin) / vertSpan;

        // 由于已经检查了范围，这里 tRatio 和 vRatio 应该在 [0, 1) 内
        // 但为了浮点精度安全，再做一次 clamp
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

    // 🎯 打印统计信息（带独特标记，方便筛选）
    NSLog(@"🎯🎯🎯 [hist2d填充] 总点数=%ld, 处理=%ld, 忽略=%ld (超范围值被跳过)",
          (long)times.count, (long)processedCount, (long)ignoredCount);

    // 🎯🎯🎯 关键：打印实际使用的 value 范围（用于验证）
    double actualValueMin = HUGE_VAL, actualValueMax = -HUGE_VAL;
    for (NSUInteger i = 0; i < times.count; i++) {
        double v = [values[i] doubleValue];
        if (v >= valueMin && v < valueMaxEffective) {  // 在范围内的值
            if (v < actualValueMin) actualValueMin = v;
            if (v > actualValueMax) actualValueMax = v;
        }
    }
    NSLog(@"🎯🎯🎯 [hist2d实际范围] value范围=[%.3f, %.3f], vertRange=[%.3f, %.3f]",
          actualValueMin, actualValueMax, valueMin, valueMax);

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
                     fromReference:(NSArray<NSNumber *> *)referenceResp {
    if (!windowResp || !referenceResp || windowResp.count != referenceResp.count) {
        return 0.0;
    }

    NSInteger n = MIN(windowResp.count, referenceResp.count);
    double sumDeviation = 0.0;

    for (NSInteger i = 0; i < n; i++) {
        double windowVal = [windowResp[i] doubleValue];
        double refVal = [referenceResp[i] doubleValue];
        sumDeviation += fabs(windowVal - refVal);
    }

    return sumDeviation / n;
}

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
                                       referenceResponse:(NSArray<NSNumber *> *)referenceResp {
    if (!stepResponse || stepResponse.count == 0 || !referenceResp) {
        return @[];
    }

    double threshold = 0.5;  // Python使用的阈值
    NSMutableArray<NSNumber *> *qualityMask = [NSMutableArray arrayWithCapacity:stepResponse.count];
    NSInteger filteredCount = 0;

    for (NSArray<NSNumber *> *windowResp in stepResponse) {
        double deviation = [self meanAbsoluteDeviation:windowResp fromReference:referenceResp];
        // Python: -to_mask(clip(..., 0.5-1e-9, 0.5)) + 1
        // 简化: 偏差 <= threshold: quality=1, 偏差 > threshold: quality=0
        double quality = (deviation <= threshold) ? 1.0 : 0.0;

        [qualityMask addObject:@(quality)];

        if (quality < 0.5) {
            filteredCount++;
            NSLog(@"⚠️ [质量过滤] 窗口[%ld] 偏差=%.3f > %.3f，已过滤",
                  (long)(qualityMask.count - 1), deviation, threshold);
        }
    }

    NSLog(@"🔍 [质量过滤] 总窗口=%lu, 过滤=%ld, 保留=%lu",
          (unsigned long)stepResponse.count, (long)filteredCount,
          (unsigned long)(stepResponse.count - filteredCount));

    return [qualityMask copy];
}

/**
 * 组合两个mask（按元素相乘）
 * 对应Python: mask1 * mask2
 *
 * @param mask1 第一个mask
 * @param mask2 第二个mask
 * @return 组合后的mask
 */
+ (NSArray<NSNumber *> *)combineMasks:(NSArray<NSNumber *> *)mask1
                            withMask:(NSArray<NSNumber *> *)mask2 {
    if (!mask1 || mask1.count == 0) return mask2 ?: @[];
    if (!mask2 || mask2.count == 0) return mask1;

    NSInteger count = MIN(mask1.count, mask2.count);
    NSMutableArray<NSNumber *> *combined = [NSMutableArray arrayWithCapacity:count];

    for (NSInteger i = 0; i < count; i++) {
        double m1 = [mask1[i] doubleValue];
        double m2 = [mask2[i] doubleValue];
        [combined addObject:@(m1 * m2)];
    }

    return [combined copy];
}

@end
