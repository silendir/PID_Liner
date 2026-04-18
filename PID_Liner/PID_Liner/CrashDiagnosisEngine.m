//
//  CrashDiagnosisEngine.m
//  PID_Liner
//
//  炸机诊断引擎实现
//  本地异常检测 → JSON 特征摘要 → GLM-4.7-Flash → 诊断报告
//

#import "CrashDiagnosisEngine.h"
#import "PIDDataModels.h"
#import "PIDCSVParser.h"
#import <math.h>

/// Worker 地址（仅用于获取 API Key，不代理请求）
static NSString *const kDefaultWorkerURL = @"https://silen.dpdns.org";

/// 智谱 AI 直连地址（流式请求）
static NSString *const kZhipuAPIURL = @"https://open.bigmodel.cn/api/paas/v4/chat/completions";

/// 本地检测阈值
static const double kDesyncPSpikeThreshold    = 500.0;   // P项尖峰阈值
static const double kDesyncGyroDelayMs        = 30.0;    // 陀螺仪延迟阈值 (ms)
static const double kMotorOverheatDRmsThresh  = 80.0;    // D项RMS过热阈值
static const double kHighThrottleRatio        = 0.6;     // 高油门占比阈值
static const double kIntegralWindupThresh     = 800.0;   // I项积分饱和阈值
static const double kVibrationPeakRatio       = 5.0;     // 振动峰值/噪声底噪比
static const double kPIDSaturationThreshold   = 0.9;     // P项饱和率阈值
static const double kEmergencyStopGyroDegS    = 500.0;   // 急停残余角速度阈值

#pragma mark - CrashAnomalyIndicator

@implementation CrashAnomalyIndicator

- (instancetype)init {
    self = [super init];
    if (self) {
        _firstOccurrenceRatio = -1;  // -1 表示未记录
        _peakOccurrenceRatio = -1;
        _lastOccurrenceRatio = -1;
    }
    return self;
}

@end

#pragma mark - CrashDiagnosisResult

@implementation CrashDiagnosisResult
@end

#pragma mark - CrashDiagnosisEngine

@interface CrashDiagnosisEngine () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSession *streamSession;
@property (nonatomic, strong) NSMutableString *contentBuffer;
@property (nonatomic, strong) NSMutableString *reasoningBuffer;
@property (nonatomic, strong) NSMutableData *sseBuffer;
@property (nonatomic, copy) void(^pendingCompletion)(NSString * _Nullable report, NSError * _Nullable error);
@end

@implementation CrashDiagnosisEngine

+ (instancetype)shared {
    static CrashDiagnosisEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CrashDiagnosisEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workerURL = kDefaultWorkerURL;
        _userContext = [[NSUserDefaults standardUserDefaults] stringForKey:@"CrashDiagnosisUserContext"];
    }
    return self;
}

- (void)setUserContext:(NSString *)userContext {
    _userContext = [userContext copy];
    [[NSUserDefaults standardUserDefaults] setObject:_userContext forKey:@"CrashDiagnosisUserContext"];
}

#pragma mark - Public

- (void)diagnoseCSVAtPath:(NSString *)csvPath
               completion:(void(^)(CrashDiagnosisResult *result))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:csvPath];

        if (!data || data.timeSeconds.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CrashDiagnosisResult *r = [[CrashDiagnosisResult alloc] init];
                r.error = [NSError errorWithDomain:@"CrashDiagnosis" code:-1
                                           userInfo:@{NSLocalizedDescriptionKey: @"CSV 解析失败，无法诊断"}];
                completion(r);
            });
            return;
        }

        [self diagnoseWithData:data completion:completion];
    });
}

- (void)diagnoseWithData:(PIDCSVData *)csvData
              completion:(void(^)(CrashDiagnosisResult *result))completion {
    // 第1步：本地异常检测
    NSArray<CrashAnomalyIndicator *> *indicators = [self localDetectAnomalies:csvData];

    // 第2步：序列化为特征摘要
    NSDictionary *featureSummary = [self serializeFeatureSummary:indicators csvData:csvData];

    // 第3步：构建 AI 请求（含 stream: true）
    NSDictionary *requestBody = [self buildAIRequest:featureSummary];

    // 第4步：从 Worker 获取 API Key（Key 不驻留本地）
    [self fetchAPIKeyWithCompletion:^(NSString *key, NSError *keyError) {
        if (keyError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CrashDiagnosisResult *result = [[CrashDiagnosisResult alloc] init];
                result.localIndicators = indicators;
                result.reportText = [self fallbackReportFromIndicators:indicators csvData:csvData];
                result.error = keyError;
                completion(result);
            });
            return;
        }

        // 第5步：流式请求智谱 AI（直连，不经 Worker）
        [self streamToZhipuAI:requestBody apiKey:key completion:^(NSString *report, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CrashDiagnosisResult *result = [[CrashDiagnosisResult alloc] init];
                result.localIndicators = indicators;

                if (error && !report) {
                    result.reportText = [self fallbackReportFromIndicators:indicators csvData:csvData];
                    result.error = error;
                } else {
                    result.reportText = report ?: [self fallbackReportFromIndicators:indicators csvData:csvData];
                    if (error) result.error = error;
                }

                completion(result);
            });
        }];
    }];
}

- (void)cancelCurrentRequest {
    // 🔑 先保存再置空，确保回调能通知调用方停止 loading
    void(^completion)(NSString * _Nullable, NSError * _Nullable) = _pendingCompletion;
    [_currentTask cancel];
    _currentTask = nil;
    [_streamSession invalidateAndCancel];
    _streamSession = nil;
    _pendingCompletion = nil;

    if (completion) {
        NSError *cancelError = [NSError errorWithDomain:@"CrashDiagnosis"
                                                   code:-999
                                               userInfo:@{NSLocalizedDescriptionKey: @"诊断已取消"}];
        completion(nil, cancelError);
    }
}

#pragma mark - 本地异常检测（8项）

- (NSArray<CrashAnomalyIndicator *> *)localDetectAnomalies:(PIDCSVData *)data {
    NSMutableArray<CrashAnomalyIndicator *> *indicators = [NSMutableArray array];

    // 各轴分别检测
    NSArray<NSArray<NSNumber *> *> *pArrays = @[data.axisP0, data.axisP1, data.axisP2];
    NSArray<NSArray<NSNumber *> *> *iArrays = @[data.axisI0, data.axisI1, data.axisI2];
    NSArray<NSArray<NSNumber *> *> *dArrays = @[data.axisD0, data.axisD1, data.axisD2];
    NSArray<NSArray<NSNumber *> *> *gyroArrays = @[data.gyroADC0, data.gyroADC1, data.gyroADC2];
    NSArray<NSString *> *axisNames = @[@"roll", @"pitch", @"yaw"];

    NSInteger totalPoints = data.timeSeconds.count;

    for (NSInteger axis = 0; axis < 3; axis++) {
        NSArray<NSNumber *> *pValues = pArrays[axis];
        NSArray<NSNumber *> *iValues = iArrays[axis];
        NSArray<NSNumber *> *dValues = dArrays[axis];
        NSArray<NSNumber *> *gyroValues = gyroArrays[axis];
        NSString *axisName = axisNames[axis];

        if (!pValues || pValues.count == 0) continue;

        // 1. 失步检测（P项尖峰但陀螺仪无响应）
        CrashAnomalyIndicator *desyncInd = [self detectDesync:pValues gyro:gyroValues axis:axisName];
        [self computeTimelineForArray:pValues
                             indicator:desyncInd
                          totalPoints:totalPoints];
        [indicators addObject:desyncInd];

        // 2. 烧电机风险（D项RMS过高 + 高油门）
        CrashAnomalyIndicator *overheatInd = [self detectMotorOverheat:dValues throttle:data.throttle axis:axisName];
        [self computeTimelineForArray:dValues
                             indicator:overheatInd
                          totalPoints:totalPoints];
        [indicators addObject:overheatInd];

        // 3. 积分饱和（I项累积过大）
        CrashAnomalyIndicator *windupInd = [self detectIntegralWindup:iValues axis:axisName];
        [self computeTimelineForArray:iValues
                             indicator:windupInd
                          totalPoints:totalPoints];
        [indicators addObject:windupInd];

        // 4. 高频震动（陀螺仪 FFT）
        CrashAnomalyIndicator *vibInd = [self detectVibration:gyroValues axis:axisName sampleRate:data.sampleRate];
        [self computeTimelineForArray:gyroValues
                             indicator:vibInd
                          totalPoints:totalPoints];
        [indicators addObject:vibInd];

        // 5. PID 饱和（P项频繁触顶）
        CrashAnomalyIndicator *satInd = [self detectPIDSaturation:pValues axis:axisName];
        [self computeTimelineForArray:pValues
                             indicator:satInd
                          totalPoints:totalPoints];
        [indicators addObject:satInd];
    }

    // 6. 急停异常（遥控回中但陀螺仪持续偏转）
    CrashAnomalyIndicator *estopInd = [self detectEmergencyStop:data];
    [self computeTimelineForArray:data.gyroADC0
                         indicator:estopInd
                      totalPoints:totalPoints];
    [indicators addObject:estopInd];

    // 7. 电机缺相（D项周期性尖峰 = 蹬脚踏车特征）
    CrashAnomalyIndicator *phaseInd = [self detectPhaseLoss:dArrays];
    // 缺相用 D 项数据追踪时间线
    [self computeTimelineForArray:data.axisD0
                         indicator:phaseInd
                      totalPoints:totalPoints];
    [indicators addObject:phaseInd];

    // 8. 低电压抖动（高油门段噪声突增）
    CrashAnomalyIndicator *voltInd = [self detectVoltageSag:data];
    [self computeTimelineForArray:data.throttle
                         indicator:voltInd
                      totalPoints:totalPoints];
    [indicators addObject:voltInd];

    // 🔑 因果链分析：区分根因和结果
    [self buildCausalChain:indicators];

    return [indicators copy];
}

#pragma mark - 时间线追踪

/// 从事件列表计算首次/峰值/最后出现的时间位置
- (void)computeTimelineForArray:(NSArray<NSNumber *> *)data
                      indicator:(CrashAnomalyIndicator *)ind
                   totalPoints:(NSInteger)totalPoints {
    if (!ind.detected || data.count == 0 || totalPoints == 0) return;

    NSInteger firstIdx = -1;
    NSInteger lastIdx = -1;
    double peakVal = 0;
    NSInteger peakIdx = -1;

    for (NSInteger i = 0; i < data.count; i++) {
        double absV = fabs(data[i].doubleValue);
        if (absV > peakVal) {
            peakVal = absV;
            peakIdx = i;
        }
        if (firstIdx < 0 && absV > 0) {
            firstIdx = i;
        }
        if (absV > 0) {
            lastIdx = i;
        }
    }

    if (firstIdx >= 0) ind.firstOccurrenceRatio = (double)firstIdx / totalPoints;
    if (peakIdx >= 0) ind.peakOccurrenceRatio = (double)peakIdx / totalPoints;
    if (lastIdx >= 0) ind.lastOccurrenceRatio = (double)lastIdx / totalPoints;
}

#pragma mark - 因果链分析

/// 区分根因和结果：时间线上先发生的异常是根因，后发生的是结果
- (void)buildCausalChain:(NSMutableArray<CrashAnomalyIndicator *> *)indicators {
    // 只分析被检测到的异常
    NSArray<CrashAnomalyIndicator *> *detected = [indicators filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"detected == YES"]];

    if (detected.count < 2) {
        // 只有一个异常，它就是根因
        for (CrashAnomalyIndicator *ind in detected) {
            ind.isRootCause = YES;
        }
        return;
    }

    // 🔑 因果关系映射表（先发生 → 后发生）
    // desync 失步 → motor_phase_loss 电机缺相（失步导致电机过热烧毁线圈）
    // desync 失步 → pid_saturation PID饱和（失步导致PID拼命补偿）
    // high_frequency_vibration 高频震动 → motor_overheat_risk 烧电机（震动加剧轴承磨损）
    // integral_windup 积分饱和 → pid_saturation PID饱和（I项累积导致输出饱和）
    // low_voltage_jitter 低电压抖动 → desync 失步（电压骤降导致ESC重启）
    NSDictionary<NSString *, NSArray<NSString *> *> *causalMap = @{
        @"desync":               @[@"motor_phase_loss", @"pid_saturation"],
        @"high_frequency_vibration": @[@"motor_overheat_risk"],
        @"integral_windup":      @[@"pid_saturation"],
        @"low_voltage_jitter":   @[@"desync"]
    };

    // 按首次出现时间排序
    NSArray<CrashAnomalyIndicator *> *sorted = [detected sortedArrayUsingComparator:
        ^NSComparisonResult(CrashAnomalyIndicator *a, CrashAnomalyIndicator *b) {
            return [@(a.firstOccurrenceRatio) compare:@(b.firstOccurrenceRatio)];
        }];

    // 标记根因：最早出现且在因果映射表中有结果的
    NSMutableSet *resultTypes = [NSMutableSet set];
    for (CrashAnomalyIndicator *ind in sorted) {
        NSArray<NSString *> *causes = causalMap[ind.type];
        if (causes) {
            ind.isRootCause = YES;
            for (NSString *resultType in causes) {
                [resultTypes addObject:resultType];
            }
        }
    }

    // 标记结果：被根因指向的异常
    for (CrashAnomalyIndicator *ind in sorted) {
        if (!ind.isRootCause && [resultTypes containsObject:ind.type]) {
            // 找到导致它的根因
            for (CrashAnomalyIndicator *cause in sorted) {
                if (cause.isRootCause) {
                    NSArray<NSString *> *causes = causalMap[cause.type];
                    if ([causes containsObject:ind.type] &&
                        cause.firstOccurrenceRatio < ind.firstOccurrenceRatio) {
                        ind.causedBy = cause.type;
                        break;
                    }
                }
            }
        } else if (!ind.isRootCause && !ind.causedBy) {
            // 既不是根因也不是已知结果 → 可能是独立的根因
            ind.isRootCause = YES;
        }
    }
}

#pragma mark - 飞行阶段描述

/// 将飞行进度百分比转为中文阶段描述
- (NSString *)phaseDescriptionForRatio:(double)ratio {
    if (ratio < 0.0) return @"未知时段";
    if (ratio < 0.05) return @"起飞阶段";
    if (ratio < 0.15) return @"起飞后爬升";
    if (ratio < 0.80) return @"飞行途中";
    if (ratio < 0.95) return @"降落阶段";
    return @"着陆时刻";
}

/// 将飞行进度转为具体时间描述
- (NSString *)timeDescriptionForRatio:(double)ratio duration:(double)duration {
    if (ratio < 0) return @"";
    double seconds = ratio * duration;
    int mins = (int)(seconds / 60);
    int secs = (int)(seconds) % 60;
    if (mins > 0) {
        return [NSString stringWithFormat:@"%d分%02d秒", mins, secs];
    }
    return [NSString stringWithFormat:@"%d秒", secs];
}

/// 1. 失步检测
- (CrashAnomalyIndicator *)detectDesync:(NSArray<NSNumber *> *)pValues
                                   gyro:(NSArray<NSNumber *> *)gyroValues
                                    axis:(NSString *)axis {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"desync";
    ind.axis = axis;

    NSInteger count = MIN(pValues.count, gyroValues.count);
    NSInteger spikeCount = 0;
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];

    for (NSInteger i = 10; i < count - 10; i++) {
        double pCurrent = pValues[i].doubleValue;

        // 检测 P 项尖峰
        if (fabs(pCurrent) > kDesyncPSpikeThreshold) {
            // 检查陀螺仪在附近窗口内是否有对应响应
            double gyroMaxDelta = 0;
            for (NSInteger j = MAX(0, i - 5); j < MIN(count, i + 20); j++) {
                double delta = fabs(gyroValues[j].doubleValue - gyroValues[MAX(0, j - 1)].doubleValue);
                if (delta > gyroMaxDelta) gyroMaxDelta = delta;
            }

            // P项飙了但陀螺仪变化很小 → 失步特征
            if (gyroMaxDelta < 50) {
                spikeCount++;
                if (events.count < 5) {
                    [events addObject:@{
                        @"index": @(i),
                        @"p_value": @(pCurrent),
                        @"gyro_delta": @(gyroMaxDelta)
                    }];
                }
            }
        }
    }

    ind.detected = (spikeCount >= 2);
    ind.severity = spikeCount >= 5 ? @"high" : (spikeCount >= 2 ? @"medium" : @"low");
    ind.detail = [NSString stringWithFormat:@"P项尖峰次数: %ld (阈值: %.0f)", (long)spikeCount, kDesyncPSpikeThreshold];
    ind.events = events.count > 0 ? [events copy] : nil;

    return ind;
}

/// 2. 烧电机风险
- (CrashAnomalyIndicator *)detectMotorOverheat:(NSArray<NSNumber *> *)dValues
                                      throttle:(NSArray<NSNumber *> *)throttleValues
                                          axis:(NSString *)axis {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"motor_overheat_risk";
    ind.axis = axis;

    if (dValues.count == 0) {
        ind.detected = NO;
        ind.detail = @"无D项数据";
        return ind;
    }

    // 计算 D 项 RMS
    double sumSq = 0;
    for (NSNumber *v in dValues) {
        sumSq += v.doubleValue * v.doubleValue;
    }
    double dRms = sqrt(sumSq / dValues.count);

    // 计算高油门占比
    NSInteger highThrottleCount = 0;
    NSInteger throttleCount = MIN(dValues.count, throttleValues.count);
    for (NSInteger i = 0; i < throttleCount; i++) {
        if (throttleValues[i].doubleValue > 1500) {
            highThrottleCount++;
        }
    }
    double highThrottleRatio = throttleCount > 0 ? (double)highThrottleCount / throttleCount : 0;

    ind.detected = (dRms > kMotorOverheatDRmsThresh && highThrottleRatio > kHighThrottleRatio);
    ind.severity = dRms > 120 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"D项RMS: %.1f (阈值: %.0f), 高油门占比: %.0f%%",
                  dRms, kMotorOverheatDRmsThresh, highThrottleRatio * 100];

    return ind;
}

/// 3. 积分饱和
- (CrashAnomalyIndicator *)detectIntegralWindup:(NSArray<NSNumber *> *)iValues
                                           axis:(NSString *)axis {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"integral_windup";
    ind.axis = axis;

    if (iValues.count == 0) {
        ind.detected = NO;
        return ind;
    }

    double maxI = 0;
    double sumI = 0;
    for (NSNumber *v in iValues) {
        double absV = fabs(v.doubleValue);
        if (absV > maxI) maxI = absV;
        sumI += absV;
    }
    double avgI = sumI / iValues.count;

    ind.detected = (maxI > kIntegralWindupThresh);
    ind.severity = maxI > 1500 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"I项最大值: %.0f, 平均值: %.1f (阈值: %.0f)",
                  maxI, avgI, kIntegralWindupThresh];

    return ind;
}

/// 4. 高频震动（简化 FFT：滑动窗口能量检测）
- (CrashAnomalyIndicator *)detectVibration:(NSArray<NSNumber *> *)gyroValues
                                      axis:(NSString *)axis
                                 sampleRate:(double)sampleRate {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"high_frequency_vibration";
    ind.axis = axis;

    if (gyroValues.count < 200) {
        ind.detected = NO;
        return ind;
    }

    // 简化：用相邻点差值的 RMS 估计高频能量
    NSInteger windowSize = 100;
    double maxHighFreqEnergy = 0;
    double baseNoise = 0;

    // 先计算整体低频基线
    double sum = 0;
    for (NSInteger i = 0; i < gyroValues.count; i++) {
        sum += gyroValues[i].doubleValue;
    }
    double mean = sum / gyroValues.count;

    double sumDevSq = 0;
    for (NSInteger i = 0; i < gyroValues.count; i++) {
        double dev = gyroValues[i].doubleValue - mean;
        sumDevSq += dev * dev;
    }
    baseNoise = sqrt(sumDevSq / gyroValues.count);

    // 滑动窗口检测高频段能量
    for (NSInteger i = 0; i < gyroValues.count - windowSize; i += windowSize / 2) {
        double diffSumSq = 0;
        for (NSInteger j = i + 1; j < i + windowSize && j < gyroValues.count; j++) {
            double diff = gyroValues[j].doubleValue - gyroValues[j - 1].doubleValue;
            diffSumSq += diff * diff;
        }
        double energy = sqrt(diffSumSq / windowSize);
        if (energy > maxHighFreqEnergy) maxHighFreqEnergy = energy;
    }

    double ratio = baseNoise > 0.01 ? maxHighFreqEnergy / baseNoise : 0;

    ind.detected = (ratio > kVibrationPeakRatio);
    ind.severity = ratio > 10 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"高频能量比: %.1f (阈值: %.0f), 基线噪声: %.1f",
                  ratio, kVibrationPeakRatio, baseNoise];

    return ind;
}

/// 5. PID 饱和
- (CrashAnomalyIndicator *)detectPIDSaturation:(NSArray<NSNumber *> *)pValues
                                          axis:(NSString *)axis {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"pid_saturation";
    ind.axis = axis;

    if (pValues.count == 0) {
        ind.detected = NO;
        return ind;
    }

    // 找 P 项最大值（作为输出限幅参考）
    double maxP = 0;
    for (NSNumber *v in pValues) {
        double absV = fabs(v.doubleValue);
        if (absV > maxP) maxP = absV;
    }

    if (maxP < 100) {
        ind.detected = NO;
        ind.detail = @"P项幅度太小，无饱和迹象";
        return ind;
    }

    // 计算接近限幅的比例
    double saturationThreshold = maxP * kPIDSaturationThreshold;
    NSInteger saturationCount = 0;
    for (NSNumber *v in pValues) {
        if (fabs(v.doubleValue) > saturationThreshold) {
            saturationCount++;
        }
    }
    double saturationRatio = (double)saturationCount / pValues.count;

    ind.detected = (saturationRatio > 0.15);
    ind.severity = saturationRatio > 0.3 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"P项饱和率: %.1f%% (阈值: 15%%), 最大输出: %.0f",
                  saturationRatio * 100, maxP];

    return ind;
}

/// 6. 急停异常
- (CrashAnomalyIndicator *)detectEmergencyStop:(PIDCSVData *)data {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"emergency_stop_anomaly";

    NSInteger count = MIN(data.rcCommand0.count, data.gyroADC0.count);
    if (count < 50) {
        ind.detected = NO;
        return ind;
    }

    // 检测遥控回中（rcCommand 接近 0）但陀螺仪仍有大角速度的时刻
    NSInteger anomalyCount = 0;
    for (NSInteger i = 20; i < count - 5; i++) {
        double rcRoll = fabs(data.rcCommand0[i].doubleValue);
        double rcPitch = fabs(data.rcCommand1[i].doubleValue);
        double rcYaw = fabs(data.rcCommand2[i].doubleValue);

        // 遥控输入接近零（回中）
        BOOL rcCentered = (rcRoll < 100 && rcPitch < 100 && rcYaw < 100);

        if (rcCentered) {
            // 检查陀螺仪角速度是否仍然很大
            double gyroMag = sqrt(data.gyroADC0[i].doubleValue * data.gyroADC0[i].doubleValue +
                                  data.gyroADC1[i].doubleValue * data.gyroADC1[i].doubleValue +
                                  data.gyroADC2[i].doubleValue * data.gyroADC2[i].doubleValue);

            if (gyroMag > kEmergencyStopGyroDegS) {
                anomalyCount++;
            }
        }
    }

    ind.detected = (anomalyCount > 10);
    ind.severity = anomalyCount > 50 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"急停异常帧数: %ld (遥控回中但角速度>%.0f°/s)",
                  (long)anomalyCount, kEmergencyStopGyroDegS];

    return ind;
}

/// 7. 电机缺相（蹬脚踏车：D项周期性尖峰 + 陀螺仪周期性扰动）
/// 缺相 = 电机三相掉了一相 → 转矩不连续 → 一顿一顿的
/// 黑盒数据中没有单独电机输出，但缺相会间接反映在：
///   - D 项出现周期性尖峰（每次顿挫产生角速度突变）
///   - 陀螺仪出现与转速同步的周期性扰动
- (CrashAnomalyIndicator *)detectPhaseLoss:(NSArray<NSArray<NSNumber *> *> *)gyroArrays {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"motor_phase_loss";

    // 🔑 改用 D 项数据检测周期性尖峰（传入的 gyroArrays 在调用处改为 D 项）
    // 但当前调用签名是陀螺仪，所以先用陀螺仪检测周期性扰动
    // 真正的缺相特征：信号中有规律的重复性脉冲，而不是持续偏移

    NSArray<NSString *> *axisNames = @[@"roll", @"pitch", @"yaw"];
    NSString *worstAxis = nil;
    double worstPeriodicity = 0;

    for (NSInteger axis = 0; axis < 3; axis++) {
        NSArray<NSNumber *> *gyro = gyroArrays[axis];
        if (gyro.count < 200) continue;

        // 🔑 步骤1：计算相邻点差值（高频变化）
        NSInteger diffCount = (NSInteger)gyro.count - 1;
        double *diffs = (double *)malloc(diffCount * sizeof(double));
        if (!diffs) continue;

        double meanDiff = 0;
        for (NSInteger i = 0; i < diffCount; i++) {
            diffs[i] = fabs(gyro[i + 1].doubleValue - gyro[i].doubleValue);
            meanDiff += diffs[i];
        }
        meanDiff /= diffCount;

        // 🔑 步骤2：找出尖峰（差值超过均值 3 倍的点）
        double spikeThreshold = meanDiff * 3.0;
        NSInteger *spikeIndices = (NSInteger *)malloc(diffCount * sizeof(NSInteger));
        NSInteger spikeCount = 0;

        for (NSInteger i = 0; i < diffCount; i++) {
            if (diffs[i] > spikeThreshold) {
                spikeIndices[spikeCount++] = i;
            }
        }

        // 🔑 步骤3：检测尖峰的周期性（相邻尖峰间距是否稳定）
        // 缺相的特征：尖峰间隔接近一致（因为电机转速稳定时顿挫频率固定）
        if (spikeCount >= 5) {
            // 计算相邻尖峰的间隔
            NSInteger intervalCount = spikeCount - 1;
            double *intervals = (double *)malloc(intervalCount * sizeof(double));
            double meanInterval = 0;

            for (NSInteger i = 0; i < intervalCount; i++) {
                intervals[i] = spikeIndices[i + 1] - spikeIndices[i];
                meanInterval += intervals[i];
            }
            meanInterval /= intervalCount;

            // 计算间隔的标准差（越小说明越有规律）
            double sumSqDev = 0;
            for (NSInteger i = 0; i < intervalCount; i++) {
                double dev = intervals[i] - meanInterval;
                sumSqDev += dev * dev;
            }
            double stdDev = sqrt(sumSqDev / intervalCount);

            // 周期性得分 = 1 - (变异系数)，越接近 1 越有规律
            double cv = meanInterval > 0 ? stdDev / meanInterval : 999;
            double periodicityScore = fmax(0, 1.0 - cv);

            // 尖峰密度：总点数中有多少比例是尖峰
            double spikeDensity = (double)spikeCount / gyro.count;

            // 综合得分：周期性高 + 尖峰密度合理 → 缺相
            // 密度不能太高（否则是普通噪声），也不能太低（偶然事件）
            double densityScore = 0;
            if (spikeDensity > 0.005 && spikeDensity < 0.1) {
                densityScore = 1.0 - fabs(spikeDensity - 0.03) / 0.03;
                densityScore = fmax(0, fmin(1, densityScore));
            }

            double combinedScore = periodicityScore * 0.6 + densityScore * 0.4;

            if (combinedScore > worstPeriodicity) {
                worstPeriodicity = combinedScore;
                worstAxis = axisNames[axis];
            }

            free(intervals);
        }

        free(spikeIndices);
        free(diffs);
    }

    // 🔑 阈值：周期性得分 > 0.5 才判定缺相（严格，避免误报）
    ind.detected = (worstPeriodicity > 0.5);
    ind.severity = worstPeriodicity > 0.75 ? @"high" : @"medium";
    ind.axis = worstAxis;
    ind.detail = [NSString stringWithFormat:@"周期性顿挫得分: %.2f (%@轴)",
                  worstPeriodicity, worstAxis ?: @"无"];

    return ind;
}

/// 8. 低电压抖动（高油门段噪声突增）
- (CrashAnomalyIndicator *)detectVoltageSag:(PIDCSVData *)data {
    CrashAnomalyIndicator *ind = [[CrashAnomalyIndicator alloc] init];
    ind.type = @"low_voltage_jitter";

    NSInteger count = MIN(data.throttle.count, data.gyroADC0.count);
    if (count < 100) {
        ind.detected = NO;
        return ind;
    }

    // 分别计算低油门和高油门段的陀螺仪噪声
    double lowNoise = 0, highNoise = 0;
    NSInteger lowCount = 0, highCount = 0;

    for (NSInteger i = 1; i < count; i++) {
        double throttle = data.throttle[i].doubleValue;
        double gyroDelta = fabs(data.gyroADC0[i].doubleValue - data.gyroADC0[i - 1].doubleValue) +
                          fabs(data.gyroADC1[i].doubleValue - data.gyroADC1[i - 1].doubleValue) +
                          fabs(data.gyroADC2[i].doubleValue - data.gyroADC2[i - 1].doubleValue);

        if (throttle < 1200) {
            lowNoise += gyroDelta;
            lowCount++;
        } else if (throttle > 1700) {
            highNoise += gyroDelta;
            highCount++;
        }
    }

    if (lowCount > 0) lowNoise /= lowCount;
    if (highCount > 0) highNoise /= highCount;

    double noiseRatio = lowNoise > 0.01 ? highNoise / lowNoise : 0;

    ind.detected = (noiseRatio > 3.0 && highCount > 100);
    ind.severity = noiseRatio > 5.0 ? @"high" : @"medium";
    ind.detail = [NSString stringWithFormat:@"高低油门噪声比: %.1fx (低: %.1f, 高: %.1f)",
                  noiseRatio, lowNoise, highNoise];

    return ind;
}

#pragma mark - 特征序列化

- (NSDictionary *)serializeFeatureSummary:(NSArray<CrashAnomalyIndicator *> *)indicators
                                  csvData:(PIDCSVData *)csvData {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];

    // 飞行摘要
    double duration = csvData.timeSeconds.count > 0
        ? csvData.timeSeconds.lastObject.doubleValue - csvData.timeSeconds.firstObject.doubleValue
        : 0;

    summary[@"flight_summary"] = @{
        @"duration_seconds": @(duration),
        @"sample_rate_hz": @(csvData.sampleRate),
        @"data_points": @(csvData.timeSeconds.count)
    };

    // 异常指标（含时间线和因果链）
    NSMutableDictionary *anomalies = [NSMutableDictionary dictionary];
    for (CrashAnomalyIndicator *ind in indicators) {
        NSString *key = ind.type;
        if (ind.axis) {
            key = [NSString stringWithFormat:@"%@_%@", ind.type, ind.axis];
        }
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"detected"] = @(ind.detected);
        item[@"severity"] = ind.severity ?: @"none";
        item[@"detail"] = ind.detail ?: @"";
        if (ind.axis) item[@"axis"] = ind.axis;

        // 🔑 时间线数据（飞行进度百分比 → 阶段描述）
        if (ind.firstOccurrenceRatio >= 0) {
            item[@"first_at_percent"] = [NSString stringWithFormat:@"%.0f%%", ind.firstOccurrenceRatio * 100];
            item[@"first_at_phase"] = [self phaseDescriptionForRatio:ind.firstOccurrenceRatio];
            item[@"first_at_time"] = [self timeDescriptionForRatio:ind.firstOccurrenceRatio duration:duration];

            item[@"peak_at_percent"] = [NSString stringWithFormat:@"%.0f%%", ind.peakOccurrenceRatio * 100];
            item[@"peak_at_phase"] = [self phaseDescriptionForRatio:ind.peakOccurrenceRatio];

            item[@"last_at_percent"] = [NSString stringWithFormat:@"%.0f%%", ind.lastOccurrenceRatio * 100];
            item[@"last_at_phase"] = [self phaseDescriptionForRatio:ind.lastOccurrenceRatio];
        }

        // 🔑 因果链
        item[@"is_root_cause"] = @(ind.isRootCause);
        if (ind.causedBy) {
            item[@"caused_by"] = ind.causedBy;
        }

        anomalies[key] = [item copy];
    }
    summary[@"anomaly_indicators"] = [anomalies copy];

    // PID 统计
    NSDictionary *pidStats = [self computePIDStats:csvData];
    if (pidStats) summary[@"pid_stats"] = pidStats;

    return [summary copy];
}

- (NSDictionary *)computePIDStats:(PIDCSVData *)data {
    NSArray<NSArray<NSNumber *> *> *pArrays = @[data.axisP0, data.axisP1, data.axisP2];
    NSArray<NSArray<NSNumber *> *> *dArrays = @[data.axisD0, data.axisD1, data.axisD2];
    NSArray<NSString *> *axisNames = @[@"roll", @"pitch", @"yaw"];

    NSMutableDictionary *stats = [NSMutableDictionary dictionary];

    for (NSInteger i = 0; i < 3; i++) {
        NSArray<NSNumber *> *p = pArrays[i];
        NSArray<NSNumber *> *d = dArrays[i];

        if (p.count == 0) continue;

        double pMax = 0, pRms = 0, dRms = 0;
        double pSumSq = 0, dSumSq = 0;

        for (NSNumber *v in p) {
            double absV = fabs(v.doubleValue);
            if (absV > pMax) pMax = absV;
            pSumSq += v.doubleValue * v.doubleValue;
        }
        pRms = sqrt(pSumSq / p.count);

        if (d.count > 0) {
            for (NSNumber *v in d) dSumSq += v.doubleValue * v.doubleValue;
            dRms = sqrt(dSumSq / d.count);
        }

        stats[axisNames[i]] = @{
            @"p_max": @(pMax),
            @"p_rms": @(pRms),
            @"d_rms": @(dRms),
            @"data_points": @(p.count)
        };
    }

    return [stats copy];
}

#pragma mark - AI 请求构建

- (NSDictionary *)buildAIRequest:(NSDictionary *)featureSummary {
    NSMutableString *sp = [NSMutableString string];

    // 🔑 从老版本叙事逻辑提炼：角色驱动 + 自然叙事流 + 线框图视觉元素
    [sp appendString:@"你是FPV老飞手。看到黑盒数据后,先画飞行线框图:\n"
        @"起飞→爬升→巡航→降落→着陆, 出问题阶段标▲写专业术语\n"
        @"再给每个异常画一条血条(█共10格):\n"
        @"积分饱和/IntegralWindup ████████░░ 80%\n"
        @"然后分析因果: 【根因】【结果】写专业术语, 【建议】写大白话\n"
        @"以「真相只有一个!」一句话总结根因\n"
        @"术语:desync=失步,prop wash=洗桨,phase loss=缺相,overshoot=过冲,FF=前馈,TPA=油门衰减,"
        @"integral windup=积分饱和,gyro=陀螺仪,D-band noise=D频段噪声,PID saturation=PID饱和,"
        @"motor overheat=烧电机,vibration=高频震动,emergency stop=急停,voltage sag=低电压抖动。"
        @"不提算法/AI。root_cause先发生,caused_by是结果。正常就说✅未检测到异常。不超过500字。\n"];

    if (_userContext.length > 0) {
        [sp appendFormat:@"【自定义】%@\n", _userContext];
    }

    // 🔑 用紧凑 JSON 而非 pretty printed，节省 ~40% token
    NSString *compactJSON = [self compactJSON:featureSummary];
    NSString *userMsg = [NSString stringWithFormat:@"飞行数据诊断:\n%@", compactJSON];

    return @{
        @"model": @"glm-4-flash",
        @"messages": @[
            @{@"role": @"system", @"content": [sp copy]},
            @{@"role": @"user",   @"content": userMsg}
        ],
        @"temperature": @(0.3),
        @"max_tokens": @(8192),
        @"stream": @(YES),
        // 🔑 关闭深度思考，避免 reasoning_content 过长导致 content 为空、前端超时
        @"thinking": @{@"type": @"disabled"}
    };
}

/// 紧凑 JSON（无缩进，比 prettyJSON 节省 30~40% token）
- (NSString *)compactJSON:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [dict description];
}

- (NSString *)prettyJSON:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [dict description];
}

#pragma mark - 网络请求（直连智谱 AI + 流式输出）

/// 从 Worker 获取 API Key（Key 不驻留本地，仅内存临时使用）
- (void)fetchAPIKeyWithCompletion:(void(^)(NSString * _Nullable key, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:_workerURL];
    if (!url) {
        completion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Worker URL 无效"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setTimeoutInterval:15];

    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }
            if (!data) {
                completion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-10
                                               userInfo:@{NSLocalizedDescriptionKey: @"Key 获取失败：空响应"}]);
                return;
            }
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *key = dict[@"key"];
            if (key.length == 0) {
                completion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-11
                                               userInfo:@{NSLocalizedDescriptionKey: @"Key 获取失败：无 key 字段"}]);
                return;
            }
            NSLog(@"🔑 API Key 获取成功");
            completion(key, nil);
        }] resume];
}

/// 流式请求智谱 AI（直连，不经 Worker，避免 Cloudflare 超时）
- (void)streamToZhipuAI:(NSDictionary *)body
                 apiKey:(NSString *)apiKey
             completion:(void(^)(NSString * _Nullable report, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:kZhipuAPIURL];
    if (!url) {
        completion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-12
                                         userInfo:@{NSLocalizedDescriptionKey: @"智谱 API URL 无效"}]);
        return;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) {
        completion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-3
                                         userInfo:@{NSLocalizedDescriptionKey: @"请求序列化失败"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [request setTimeoutInterval:300];

    NSLog(@"📤 ══════════ 诊断请求(直连智谱) ══════════");
    NSLog(@"📤 URL: %@", url.absoluteString);
    NSLog(@"📤 请求体(%lu字节)", (unsigned long)jsonData.length);
    NSLog(@"📤 ══════════════════════════════");

    // 重置缓冲区
    self.contentBuffer = [NSMutableString string];
    self.reasoningBuffer = [NSMutableString string];
    self.sseBuffer = [NSMutableData data];
    self.pendingCompletion = completion;

    // 🔑 后台队列处理 SSE，避免大量流式数据阻塞主线程导致无法点取消
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    self.streamSession = [NSURLSession sessionWithConfiguration:config
                                                      delegate:self
                                                 delegateQueue:delegateQueue];

    self.currentTask = [self.streamSession dataTaskWithRequest:request];
    [self.currentTask resume];
}

#pragma mark - NSURLSessionDataDelegate（流式 SSE 解析）

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
    NSLog(@"📥 HTTP %ld", (long)httpResp.statusCode);
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    // 🔍 调试：打印原始响应数据
    NSString *rawData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"📥 收到数据(%lu字节): %@", (unsigned long)data.length, rawData);

    [self.sseBuffer appendData:data];

    NSString *bufferStr = [[NSString alloc] initWithData:self.sseBuffer encoding:NSUTF8StringEncoding];
    NSArray *messages = [bufferStr componentsSeparatedByString:@"\n\n"];

    // 处理所有完整的 SSE 消息（最后一个可能不完整，留在缓冲区）
    for (NSInteger i = 0; i < messages.count - 1; i++) {
        NSString *msg = [messages[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (msg.length > 0) {
            [self processSSEMessage:msg];
        }
    }

    // 保留未完成的部分
    NSString *remaining = messages.lastObject ?: @"";
    self.sseBuffer = [[remaining dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    // 处理缓冲区残余
    if (self.sseBuffer.length > 0) {
        NSString *remaining = [[NSString alloc] initWithData:self.sseBuffer encoding:NSUTF8StringEncoding];
        NSString *trimmed = [remaining stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [self processSSEMessage:trimmed];
        }
    }

    NSLog(@"📥 ══════════ 流式响应完成 ══════════");
    NSLog(@"📥 content: %lu字符, reasoning: %lu字符",
          (unsigned long)self.contentBuffer.length,
          (unsigned long)self.reasoningBuffer.length);

    // 🔑 只返回 content（最终诊断报告），永远不把 reasoning 暴露给用户
    NSString *report = self.contentBuffer.length > 0 ? [self.contentBuffer copy] : nil;

    if (error && !report) {
        NSLog(@"📥 流式错误: %@", error.localizedDescription);
        if (self.pendingCompletion) {
            self.pendingCompletion(nil, error);
        }
    } else if (report.length > 0) {
        if (self.pendingCompletion) {
            self.pendingCompletion(report, error);
        }
    } else {
        if (self.pendingCompletion) {
            self.pendingCompletion(nil, [NSError errorWithDomain:@"CrashDiagnosis" code:-8
                                                         userInfo:@{NSLocalizedDescriptionKey: @"AI 未返回有效内容"}]);
        }
    }

    self.pendingCompletion = nil;
    [self.streamSession invalidateAndCancel];
    self.streamSession = nil;
}

/// 解析单条 SSE 消息（data: {...}）
- (void)processSSEMessage:(NSString *)message {
    for (NSString *line in [message componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed hasPrefix:@"data: "]) continue;

        NSString *jsonStr = [trimmed substringFromIndex:6];

        if ([jsonStr isEqualToString:@"[DONE]"]) {
            NSLog(@"📥 流式传输结束 [DONE]");
            return;
        }

        NSDictionary *chunk = [NSJSONSerialization JSONObjectWithData:
                               [jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![chunk isKindOfClass:[NSDictionary class]]) continue;

        NSArray *choices = chunk[@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) continue;

        NSDictionary *delta = choices[0][@"delta"];
        if (![delta isKindOfClass:[NSDictionary class]]) continue;

        // 提取正式输出
        NSString *content = delta[@"content"];
        if (content.length > 0) {
            [self.contentBuffer appendString:content];
        }

        // 提取推理内容（思考模式降级）
        NSString *reasoning = delta[@"reasoning_content"];
        if (reasoning.length > 0) {
            [self.reasoningBuffer appendString:reasoning];
        }

        // 🔑 流式回调：dispatch to main queue for UI update（delegate 现在在后台线程）
        if (self.contentBuffer.length > 0 && self.onStreamingText) {
            NSString *partialText = [self.contentBuffer copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onStreamingText) {
                    self.onStreamingText(partialText);
                }
            });
        } else if (self.reasoningBuffer.length > 0 && self.onStreamingText) {
            // 只显示简单的进度提示，不暴露思考过程原文
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onStreamingText) {
                    self.onStreamingText(@"⏳ AI 正在分析飞行数据，请稍候...");
                }
            });
        }
    }
}

#pragma mark - 降级报告（AI 不可用时）

- (NSString *)fallbackReportFromIndicators:(NSArray<CrashAnomalyIndicator *> *)indicators
                                   csvData:(PIDCSVData *)csvData {
    NSMutableString *report = [NSMutableString string];

    double duration = csvData.timeSeconds.count > 0
        ? csvData.timeSeconds.lastObject.doubleValue - csvData.timeSeconds.firstObject.doubleValue : 0;

    [report appendFormat:@"📋 本地诊断报告（AI 不可用，仅展示本地检测结果）\n\n"];
    [report appendFormat:@"⏱ 飞行时长: %.1fs | 数据点: %ld | 采样率: %.0fHz\n\n",
        duration, (long)csvData.timeSeconds.count, csvData.sampleRate];

    // 筛选被检测到的异常
    NSArray<CrashAnomalyIndicator *> *detected = [indicators filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"detected == YES"]];

    if (detected.count == 0) {
        [report appendString:@"✅ 本次飞行数据未检测到明显异常\n"];
        [report appendString:@"\n💡 联网后可获取 AI 深度诊断"];
        return [report copy];
    }

    // 按时间线排序（最早出现的排前面）
    NSArray<CrashAnomalyIndicator *> *sorted = [detected sortedArrayUsingComparator:
        ^NSComparisonResult(CrashAnomalyIndicator *a, CrashAnomalyIndicator *b) {
            return [@(a.firstOccurrenceRatio) compare:@(b.firstOccurrenceRatio)];
        }];

    // 🔑 分离根因和结果
    NSMutableArray<CrashAnomalyIndicator *> *rootCauses = [NSMutableArray array];
    NSMutableArray<CrashAnomalyIndicator *> *results = [NSMutableArray array];
    for (CrashAnomalyIndicator *ind in sorted) {
        if (ind.isRootCause) {
            [rootCauses addObject:ind];
        } else {
            [results addObject:ind];
        }
    }

    // 📖 时间线还原（柯南风格）
    [report appendString:@"📖 案发经过\n"];
    [report appendString:@"━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"];

    if (duration > 0) {
        [report appendFormat:@"飞行从 0 秒开始，持续 %.1f 秒。\n\n", duration];
    }

    for (CrashAnomalyIndicator *ind in sorted) {
        NSString *typeName = [self displayNameForType:ind.type];
        NSString *axisLabel = ind.axis ? [NSString stringWithFormat:@"[%@轴] ", ind.axis.uppercaseString] : @"";
        NSString *timeLabel = @"";
        if (ind.firstOccurrenceRatio >= 0 && duration > 0) {
            timeLabel = [NSString stringWithFormat:@"(第 %@)",
                [self timeDescriptionForRatio:ind.firstOccurrenceRatio duration:duration]];
        }

        NSString *prefix = @"";
        if (ind.isRootCause) {
            prefix = @"⚡ 根因：";
        } else if (ind.causedBy) {
            NSString *causeName = [self displayNameForType:ind.causedBy];
            prefix = [NSString stringWithFormat:@"→ 结果（由%@引发）：", causeName];
        }

        [report appendFormat:@"  %@ %@%@ %@%@\n", prefix, typeName, axisLabel, timeLabel, ind.detail];
    }

    // 🔍 真相
    [report appendString:@"\n🔍 真相只有一个！\n"];
    [report appendString:@"━━━━━━━━━━━━━━━━━━━━━━━━━━\n"];
    if (rootCauses.count > 0) {
        for (CrashAnomalyIndicator *cause in rootCauses) {
            NSString *typeName = [self displayNameForType:cause.type];
            NSString *axisLabel = cause.axis ? [NSString stringWithFormat:@"%@轴", cause.axis] : @"";
            [report appendFormat:@"根因：%@ %@ — %@\n", typeName, axisLabel, cause.detail];

            // 找出它导致的结果
            for (CrashAnomalyIndicator *result in results) {
                if ([result.causedBy isEqualToString:cause.type]) {
                    NSString *resultName = [self displayNameForType:result.type];
                    [report appendFormat:@"  → 导致：%@ %@\n", resultName, result.detail];
                }
            }
        }
    }

    [report appendFormat:@"\n💡 联网后可获取 AI 深度诊断"];

    return [report copy];
}

- (NSString *)displayNameForType:(NSString *)type {
    NSDictionary *names = @{
        @"desync": @"电机失步",
        @"motor_overheat_risk": @"烧电机风险",
        @"motor_phase_loss": @"电机缺相",
        @"integral_windup": @"积分饱和",
        @"high_frequency_vibration": @"高频震动",
        @"pid_saturation": @"PID 输出饱和",
        @"emergency_stop_anomaly": @"急停异常",
        @"low_voltage_jitter": @"低电压抖动"
    };
    return names[type] ?: type;
}

@end
