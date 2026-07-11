//
//  RealBBLClosureTests.m
//  PID_LinerTests
//
//  阶段2.5b-1: 真实BBL → stackResponse统计阶跃 → fit二阶 → 回放 RMSE
//
//  目的: 测二阶模型能否拟合真实飞行统计平均响应
//    RMSE < 0.05 → 二阶够 → 进 2.5b-2（单次阶跃）
//    RMSE ≥ 0.05 → 二阶不够 → 反解免谈，先升级模型
//
//  数据流: BlackboxDecoder → PIDCSVParser → PIDStackData.stackFromData
//          → PIDTraceAnalyzer.stackResponse → 跨窗口平均 → fitSecondOrder → 回放 RMSE
//

#import <XCTest/XCTest.h>
#import "BlackboxDecoder.h"
#import "PIDCSVParser.h"
#import "PIDDataModels.h"
#import "PIDTraceAnalyzer.h"
#import "PIDRecommendationEngine.h"
#import "BBLHeaderParser.h"
#import "PIDReverseSolver.h"  // 阶段3.2 真实BBL反解
#import <math.h>

#pragma mark - 私有方法暴露

@interface PIDRecommendationEngine (RealBBLClosureAccess)
- (void)fitSecondOrderFromResponse:(NSArray<NSNumber *> *)response
                              gain:(double *)outGain
                      naturalFreq:(double *)outWn
                     dampingRatio:(double *)outZeta;
@end

@interface RealBBLClosureTests : XCTestCase
@end

@implementation RealBBLClosureTests

/// RMSE
- (double)rmseBetween:(NSArray<NSNumber *> *)a and:(NSArray<NSNumber *> *)b {
    NSInteger n = MIN(a.count, b.count);
    if (n == 0) return NAN;
    double sum = 0.0;
    for (NSInteger i = 0; i < n; i++) {
        double d = a[i].doubleValue - b[i].doubleValue;
        sum += d * d;
    }
    return sqrt(sum / (double)n);
}

/// 跨窗口简单平均 stepResponse[窗口][点] → 单条曲线
- (NSArray<NSNumber *> *)averageAcrossWindows:(NSArray<NSArray<NSNumber *> *> *)stepResp
                                       points:(NSInteger)usePoints {
    NSInteger nWindows = stepResp.count;
    if (nWindows == 0) return @[];
    NSMutableArray<NSNumber *> *avg = [NSMutableArray arrayWithCapacity:usePoints];
    for (NSInteger t = 0; t < usePoints; t++) {
        double sum = 0.0;
        NSInteger cnt = 0;
        for (NSInteger w = 0; w < nWindows; w++) {
            if (t < stepResp[w].count) {
                sum += stepResp[w][t].doubleValue;
                cnt++;
            }
        }
        [avg addObject:@(cnt > 0 ? sum / (double)cnt : 0.0)];
    }
    return [avg copy];
}

/// 核心测试：真实 BBL → 二阶拟合 RMSE
- (void)testRealBBL_ForwardModelRMSE {
    // 从 test bundle 读 BBL，复制到 NSTemp（decodeFlightLog 需可写目录产 CSV）
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bundleBBL = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bundleBBL, @"001.bbl 未在 test bundle");
    NSString *tempBBL = [NSTemporaryDirectory() stringByAppendingPathComponent:@"001.bbl"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tempBBL error:nil];
    NSError *copyErr = nil;
    [fm copyItemAtPath:bundleBBL toPath:tempBBL error:&copyErr];
    XCTAssertNil(copyErr, @"复制 BBL 到 NSTemp 失败");

    // 1. BBL → CSV（CSV 写到 NSTemp 同目录）
    BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
    int decResult = [decoder decodeFlightLog:tempBBL logIndex:0];
    XCTAssertEqual(decResult, 0, @"BBL 解码失败 rc=%d", decResult);
    NSString *csvPath = [[tempBBL stringByDeletingPathExtension]
        stringByAppendingFormat:@".01.csv"];

    // 2. CSV → PIDCSVData
    PIDCSVParser *parser = [PIDCSVParser parser];
    PIDCSVData *data = [parser parseCSV:csvPath];
    XCTAssertNotNil(data, @"CSV解析失败: %@", csvPath);
    XCTAssertGreaterThan(data.timeUs.count, 100, @"数据点太少: %lu", (unsigned long)data.timeUs.count);

    double sampleRate = data.sampleRate > 0 ? data.sampleRate : 8000.0;

    // 3. stackFromData（Roll 轴）
    //    🔑 windowSize 必须匹配 sampleRate（1秒窗口）：ViewController 硬编码 8000 是假设 8kHz
    //    本测试用真实 sampleRate（如 1024Hz→1024 点），避免窗口/采样率不匹配导致振荡
    NSInteger windowSize = 8000;  // 匹配 ViewController 固定 8000
    PIDStackData *stackData = [PIDStackData stackFromData:data
                                                axisIndex:0
                                               windowSize:windowSize
                                                 overlap:0.9375
                                                    pGain:45.0];
    XCTAssertGreaterThan(stackData.windowCount, 0, @"堆叠窗口为空");

    // 4. Hanning 窗 + stackResponse
    NSArray<NSNumber *> *window = [PIDTraceAnalyzer hanningWindowWithLength:windowSize];
    PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];
    PIDResponseResult *response = [analyzer stackResponse:stackData window:window];
    XCTAssertGreaterThan(response.stepResponse.count, 0, @"stepResponse为空");

    // 5. 复刻 ViewController 提纯流程（lowHighMask + quality 过滤）= 1.1 的阶跃提纯
    NSDictionary *masks = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:500.0];  // low: maxInput<500
    NSArray<NSNumber *> *lowMask = masks[@"low"];
    NSDictionary *tooLowMasks = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:20.0];  // high: maxInput>=20
    NSArray<NSNumber *> *toolowMask = tooLowMasks[@"high"];
    NSMutableArray<NSNumber *> *respLowMask = [NSMutableArray arrayWithCapacity:lowMask.count];
    for (NSInteger i = 0; i < (NSInteger)MIN(lowMask.count, toolowMask.count); i++) {
        [respLowMask addObject:@([lowMask[i] doubleValue] * [toolowMask[i] doubleValue])];
    }
    NSArray<NSNumber *> *vertRange = @[@(-1.5), @(3.5)];
    NSArray<NSNumber *> *respLowInitial = [PIDTraceAnalyzer
        weightedModeAverageWithStepResponse:response.stepResponse
        avgTime:response.avgTime dataMask:respLowMask
        vertRange:vertRange vertBins:1000 sampleRate:sampleRate];
    NSArray<NSNumber *> *qualityMask = [PIDTraceAnalyzer
        calculateResponseQualityMask:response.stepResponse referenceResponse:respLowInitial];
    NSArray<NSNumber *> *combined = [PIDTraceAnalyzer combineMasks:respLowMask withMask:qualityMask];
    NSArray<NSNumber *> *avgCurve = [PIDTraceAnalyzer
        weightedModeAverageWithStepResponse:response.stepResponse
        avgTime:response.avgTime dataMask:combined
        vertRange:vertRange vertBins:1000 sampleRate:sampleRate];
    XCTAssertGreaterThan(avgCurve.count, 100, @"提纯曲线点数太少");
    NSInteger usePoints = (NSInteger)avgCurve.count;

    // 6. 归一化 avgCurve 到稳态=1（让 RMSE 在归一化尺度，0.05 阈值才适用）
    double steadyState = 0;
    NSInteger tailStart = avgCurve.count * 9 / 10;
    for (NSInteger i = tailStart; i < avgCurve.count; i++) steadyState += avgCurve[i].doubleValue;
    steadyState /= (double)(avgCurve.count - tailStart);
    if (fabs(steadyState) < 1e-9) steadyState = 1.0;
    NSMutableArray<NSNumber *> *normCurve = [NSMutableArray arrayWithCapacity:avgCurve.count];
    for (NSNumber *v in avgCurve) [normCurve addObject:@(v.doubleValue / steadyState)];

    // 7. fit 二阶（归一化曲线）
    double K = 0, wn = 0, zeta = 0;
    PIDRecommendationEngine *eng = [[PIDRecommendationEngine alloc] init];
    [eng fitSecondOrderFromResponse:normCurve gain:&K naturalFreq:&wn dampingRatio:&zeta];

    // 8. 回放
    NSArray<NSNumber *> *replayed = [PIDRecommendationEngine
        predictedCurveWithGain:K naturalFreq:wn dampingRatio:zeta
                        length:normCurve.count duration:0.5];

    // 9. 归一化 RMSE
    double rmse = [self rmseBetween:normCurve and:replayed];

    NSLog(@"\n  📊 真实BBL[001] Roll:\n    窗口=%ld 点=%ld sampleRate=%.0f steady=%.1f\n    fit: K=%.3f ωn=%.1f(%.1fHz) ζ=%.3f\n    归一化RMSE=%.4f",
          (long)response.stepResponse.count, (long)usePoints, sampleRate, steadyState,
          K, wn, wn / (2 * M_PI), zeta, rmse);

    // avgCurve 形状诊断
    NSInteger N = avgCurve.count;
    NSMutableString *shape = [NSMutableString string];
    for (int s = 0; s <= 10; s++) {
        NSInteger idx = MIN((NSInteger)(s * (N - 1) / 10.0), N - 1);
        [shape appendFormat:@"%.2f ", avgCurve[idx].doubleValue];
    }
    // 单窗口诊断（区分 stackResponse 输出 vs weightedModeAverage 平均）
    NSArray<NSNumber *> *win0 = response.stepResponse.firstObject;
    NSInteger wN = win0.count;
    NSMutableString *winShape = [NSMutableString string];
    for (int s = 0; s <= 6; s++) {
        NSInteger idx = MIN((NSInteger)(s * (wN - 1) / 6.0), wN - 1);
        [winShape appendFormat:@"%.2f ", win0[idx].doubleValue];
    }

    XCTAssertLessThan(rmse, 0.05,
        @"RMSE=%.4f 提纯avgCurve形: %@ | 单窗口[0]形: %@ (wN=%ld avgCurve.count=%ld)",
        rmse, shape, winShape, (long)wN, (long)avgCurve.count);
}

#pragma mark - 阶段2.5c: 机械常数标定 (K_plant, τ_m)

/// 真实BBL → fit (ωn,ζ) + 已知PID → 解标定方程 → (K_plant, τ_m) + 自检
/// 验证纯PD二阶公式能否从飞行数据解出物理合理的机械常数
///   ωn² = K_plant·P / τ_m           ...(1)
///   2ζωn = (1 + K_plant·D) / τ_m    ...(2)
///   解析: τ_m = 1/(2ζωn − ωn²·D/P),  K_plant = ωn²·τ_m/P
- (void)testCalibration_MechConstants_FromRealBBL {
    // ── 1. BBL → CSV → PIDCSVData (复用2.5b) ──
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bundleBBL = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bundleBBL, @"001.bbl 未在 test bundle");
    NSString *tempBBL = [NSTemporaryDirectory() stringByAppendingPathComponent:@"001_calib.bbl"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tempBBL error:nil];
    NSError *copyErr = nil;
    [fm copyItemAtPath:bundleBBL toPath:tempBBL error:&copyErr];
    XCTAssertNil(copyErr, @"复制BBL失败");

    BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
    XCTAssertEqual([decoder decodeFlightLog:tempBBL logIndex:0], 0, @"BBL解码失败");
    NSString *csvPath = [[tempBBL stringByDeletingPathExtension] stringByAppendingFormat:@".01.csv"];
    PIDCSVData *data = [[PIDCSVParser parser] parseCSV:csvPath];
    XCTAssertNotNil(data, @"CSV解析失败");

    // ── 2. 读真实PID (BBL header 解析, BBLHeaderParser) ──
    //    BBL header 文本含 rollPID:38,85,44 / feedforward_weight:72,76,72
    //    BlackboxDecoder没提取 → BBLHeaderParser纯ObjC补这个缺口
    NSDictionary *header = [BBLHeaderParser parseHeaderFromFile:tempBBL];
    NSArray<NSString *> *pidParts = [[header objectForKey:@"rollPID"] componentsSeparatedByString:@","];
    NSArray<NSString *> *ffParts = [[header objectForKey:@"feedforward_weight"] componentsSeparatedByString:@","];
    double P  = pidParts.count > 0 ? [pidParts[0] doubleValue] : 45.0;
    double I  = pidParts.count > 1 ? [pidParts[1] doubleValue] : 80.0;
    double D  = pidParts.count > 2 ? [pidParts[2] doubleValue] : 30.0;
    double FF = ffParts.count > 0 ? [ffParts[0] doubleValue] : 120.0;
    NSString *pidSource = [NSString stringWithFormat:@"BBLHeader真实PID rollPID=%@ FF=%@",
                           header[@"rollPID"] ?: @"?",
                           ffParts.count > 0 ? ffParts[0] : @"?"];

    // ── 3. stackResponse + 提纯 (复用2.5b ViewController流程) ──
    double sampleRate = data.sampleRate > 0 ? data.sampleRate : 8000.0;
    NSInteger windowSize = 8000;
    PIDStackData *stackData = [PIDStackData stackFromData:data axisIndex:0
                                                windowSize:windowSize overlap:0.9375 pGain:P];
    PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];
    PIDResponseResult *response = [analyzer stackResponse:stackData
                                  window:[PIDTraceAnalyzer hanningWindowWithLength:windowSize]];
    NSDictionary *masks = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:500.0];
    NSArray<NSNumber *> *lowMask = masks[@"low"];
    NSDictionary *tooLow = [PIDTraceAnalyzer lowHighMask:response.maxInput threshold:20.0];
    NSArray<NSNumber *> *toolowMask = tooLow[@"high"];
    NSMutableArray<NSNumber *> *respLowMask = [NSMutableArray arrayWithCapacity:lowMask.count];
    for (NSInteger i = 0; i < (NSInteger)MIN(lowMask.count, toolowMask.count); i++) {
        [respLowMask addObject:@([lowMask[i] doubleValue] * [toolowMask[i] doubleValue])];
    }
    NSArray *vr = @[@(-1.5), @(3.5)];
    NSArray *init0 = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:response.stepResponse
        avgTime:response.avgTime dataMask:respLowMask vertRange:vr vertBins:1000 sampleRate:sampleRate];
    NSArray *qMask = [PIDTraceAnalyzer calculateResponseQualityMask:response.stepResponse referenceResponse:init0];
    NSArray *combined = [PIDTraceAnalyzer combineMasks:respLowMask withMask:qMask];
    NSArray<NSNumber *> *avgCurve = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:response.stepResponse
        avgTime:response.avgTime dataMask:combined vertRange:vr vertBins:1000 sampleRate:sampleRate];

    // ── 4. 归一化 + fit (K, ωn, ζ) ──
    double ss = 0; NSInteger tail = avgCurve.count * 9 / 10;
    for (NSInteger i = tail; i < avgCurve.count; i++) ss += avgCurve[i].doubleValue;
    ss /= (double)(avgCurve.count - tail); if (fabs(ss) < 1e-9) ss = 1.0;
    NSMutableArray<NSNumber *> *norm = [NSMutableArray arrayWithCapacity:avgCurve.count];
    for (NSNumber *v in avgCurve) [norm addObject:@(v.doubleValue / ss)];

    double K = 0, wn = 0, zeta = 0;
    PIDRecommendationEngine *eng = [[PIDRecommendationEngine alloc] init];
    [eng fitSecondOrderFromResponse:norm gain:&K naturalFreq:&wn dampingRatio:&zeta];

    // ── 5. ★ 标定求解 (K_plant, τ_m) ★
    double denom   = 2.0 * zeta * wn - wn * wn * D / P;   // τ_m 分母
    BOOL hasPos    = (denom > 1e-9);                       // 有正解?
    double tauM    = hasPos ? (1.0 / denom) : NAN;         // 秒
    double kPlant  = hasPos ? (wn * wn * tauM / P) : NAN;
    BOOL tauOk     = hasPos && (tauM >= 0.003 && tauM <= 0.030);  // 物理范围 3~30ms

    // round-trip 自检: (K_plant,τ_m)+P,D 重算 (ωn,ζ) 应=fit值 (数学恒等,验证求解无误)
    double wnR    = hasPos ? sqrt(kPlant * P / tauM) : NAN;
    double zetaR  = hasPos ? (1.0 + kPlant * D) / (2.0 * tauM * wnR) : NAN;

    NSLog(@"\n🔧 机械常数标定 [001.bbl Roll]\n  PID来源: %@\n  PID: P=%.1f I=%.1f D=%.1f FF=%.1f\n  fit: K=%.3f ωn=%.1f(%.1fHz) ζ=%.3f\n  ─── 标定求解 ───\n  denom = 2ζωn − ωn²·D/P = %.2f\n  τ_m   = %.5f s (%.2f ms)\n  K_plant = %.4f\n  正解: %@ | τ_m物理范围[3-30ms]: %@\n  ─── round-trip自检(应≈0%%误差) ───\n  ωn: %.1f vs %.1f (Δ=%.3f%%)\n  ζ:  %.3f vs %.3f (Δ=%.3f%%)",
          pidSource, P, I, D, FF,
          K, wn, wn / (2 * M_PI), zeta,
          denom, tauM, tauM * 1000.0, kPlant,
          hasPos ? @"YES" : @"NO❌(模型不自洽)", tauOk ? @"YES✅" : @"NO❌",
          wnR, wn, fabs(wnR - wn) / wn * 100.0,
          zetaR, zeta, zeta > 1e-9 ? fabs(zetaR - zeta) / zeta * 100.0 : 0.0);

    // ponytail: NSLog 在 Xcode16 ephemeral clone 不进 stdout，写文件供测试外读取
    NSString *calibReport = [NSString stringWithFormat:
        @"PID来源:%@\nP=%.1f I=%.1f D=%.1f FF=%.1f\nfit:K=%.3f wn=%.1f(%.1fHz) zeta=%.3f\ndenom=%.2f\ntauM=%.5fs(%.2fms)\nkPlant=%.4f\nvalid=%@ tauRangeOK=%@\nroundTrip: wnDelta=%.3f%% zetaDelta=%.3f%%",
        pidSource, P, I, D, FF, K, wn, wn / (2 * M_PI), zeta, denom, tauM, tauM * 1000.0, kPlant,
        hasPos ? @"YES" : @"NO", tauOk ? @"YES" : @"NO",
        fabs(wnR - wn) / wn * 100.0, zeta > 1e-9 ? fabs(zetaR - zeta) / zeta * 100.0 : 0.0];
    [calibReport writeToFile:@"/tmp/calib_result.txt" atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];

    // 📋 标定实验记录 (2026-07-11, 001.bbl Roll):
    //   fit: ωn=575.9(91.7Hz) ζ=0.315 K=1.0；denom = 2ζωn − ωn²·D/P = −220710 (负) → 无正解
    //   根因: BF的D=30非纯D(经D-term滤波/D_max/单位转换)，等效D远小于标称值，
    //         纯PD二阶公式直接代入D=30不自洽 → 证实反解方案选型3(前向须给D-term正确建模)。
    //   次发现1: 单条BBL的(ωn,ζ)标定机械常数自由度不够(2方程 vs K_plant/τ_m/D缩放多未知)，
    //            标定应并入反解(多曲线过定fit)，不单独做。
    //   次发现2: 001.bbl的CSV头未注入PID元数据，fallback到BF默认(45/30)。
    XCTAssertGreaterThan(wn, 2 * M_PI * 5, @"ωn=%.1f 过低", wn);
    XCTAssertLessThan(wn, 2 * M_PI * 300, @"ωn=%.1f 过高", wn);
}

#pragma mark - BBLHeaderParser 验证

/// 验证 BBLHeaderParser 能从 001.bbl header 解析出真实 PID/FF/d_min
- (void)testBBLHeaderParser_Parses001 {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl, @"001.bbl 不在 test bundle");

    NSDictionary *h = [BBLHeaderParser parseHeaderFromFile:bbl];
    XCTAssertNotNil(h, @"BBLHeaderParser 返回 nil");

    // 真实PID (strings 001.bbl 实测: rollPID:38,85,44 / FF:72 / d_min:29)
    XCTAssertEqualObjects(h[@"rollPID"], @"38,85,44", @"rollPID 解析错");
    XCTAssertEqualObjects(h[@"pitchPID"], @"41,90,48");
    XCTAssertEqualObjects(h[@"yawPID"], @"41,90,0");
    XCTAssertEqualObjects(h[@"feedforward_weight"], @"72,76,72");
    XCTAssertEqualObjects(h[@"d_min"], @"29,31,0");
    XCTAssertEqualObjects(h[@"Craft name"], @"Silen");
    XCTAssertTrue([h[@"Firmware revision"] containsString:@"Betaflight"],
                  @"固件版本解析错: %@", h[@"Firmware revision"]);
}

#pragma mark - 阶段3.2: 真实BBL反解 (反解框架 vs 真实数据)

// 目的: 001.bbl 真实 Roll 阶跃曲线 → PIDReverseSolver 反解 → 能否还原 BBL header 真实 PID(38/85/44/72)?
//   ✅ 接近 → 轻量 forward 在真实数据下可用, 反解可产品化
//   ❌ 偏离大 → 真实曲线非纯二阶(BF D-term 动态 d_min/双低通/TPA), 需扩 forward
// mech(87/0.01/0.0007) = 2.5c 用真实PID+fit曲线标定的参考值, 与 fit(ωn=575.9,ζ=0.315) 自洽

/// 001.bbl → 归一化(稳态=1) Roll 阶跃曲线 (复刻 2.5b ViewController 提纯流程)
/// avgCurve 时间跨度固定 0.5s (weightedModeAverage 内 responseDuration=0.5), 反解 duration 须=0.5 对齐
- (nullable NSArray<NSNumber *> *)normalizedRollStepCurveFromBBL:(NSString *)bblPath
                                                    outSampleRate:(double *)outSR {
    @try {
        NSString *tempBBL = [NSTemporaryDirectory() stringByAppendingPathComponent:@"001_rev.bbl"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:tempBBL error:nil];
        if (![fm copyItemAtPath:bblPath toPath:tempBBL error:nil]) return nil;

        BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
        if ([decoder decodeFlightLog:tempBBL logIndex:0] != 0) return nil;
        NSString *csvPath = [[tempBBL stringByDeletingPathExtension] stringByAppendingFormat:@".01.csv"];
        PIDCSVData *data = [[PIDCSVParser parser] parseCSV:csvPath];
        if (!data || data.timeUs.count < 100) return nil;

        double sampleRate = data.sampleRate > 0 ? data.sampleRate : 8000.0;
        if (outSR) *outSR = sampleRate;

        NSInteger windowSize = 8000;
        PIDStackData *stackData = [PIDStackData stackFromData:data axisIndex:0
                                                    windowSize:windowSize overlap:0.9375 pGain:45.0];
        PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];
        PIDResponseResult *response = [analyzer stackResponse:stackData
                                      window:[PIDTraceAnalyzer hanningWindowWithLength:windowSize]];
        if (response.stepResponse.count == 0) return nil;

        // 提纯: lowHighMask×2 → weightedModeAverage 初值 → qualityMask → 再平均
        NSArray<NSNumber *> *lowMask = [[PIDTraceAnalyzer lowHighMask:response.maxInput threshold:500.0] objectForKey:@"low"];
        NSArray<NSNumber *> *toolowMask = [[PIDTraceAnalyzer lowHighMask:response.maxInput threshold:20.0] objectForKey:@"high"];
        NSMutableArray<NSNumber *> *respLowMask = [NSMutableArray arrayWithCapacity:lowMask.count];
        for (NSInteger i = 0; i < (NSInteger)MIN(lowMask.count, toolowMask.count); i++) {
            [respLowMask addObject:@([lowMask[i] doubleValue] * [toolowMask[i] doubleValue])];
        }
        NSArray<NSNumber *> *vr = @[@(-1.5), @(3.5)];
        NSArray<NSNumber *> *init0 = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:response.stepResponse
            avgTime:response.avgTime dataMask:respLowMask vertRange:vr vertBins:1000 sampleRate:sampleRate];
        NSArray<NSNumber *> *qMask = [PIDTraceAnalyzer calculateResponseQualityMask:response.stepResponse referenceResponse:init0];
        NSArray<NSNumber *> *combined = [PIDTraceAnalyzer combineMasks:respLowMask withMask:qMask];
        NSArray<NSNumber *> *avgCurve = [PIDTraceAnalyzer weightedModeAverageWithStepResponse:response.stepResponse
            avgTime:response.avgTime dataMask:combined vertRange:vr vertBins:1000 sampleRate:sampleRate];
        if (avgCurve.count < 100) return nil;

        // 归一化稳态=1 (让 RMSE 在归一化尺度)
        double ss = 0; NSInteger tail = avgCurve.count * 9 / 10;
        for (NSInteger i = tail; i < avgCurve.count; i++) ss += avgCurve[i].doubleValue;
        ss /= (double)(avgCurve.count - tail); if (fabs(ss) < 1e-9) ss = 1.0;
        NSMutableArray<NSNumber *> *norm = [NSMutableArray arrayWithCapacity:avgCurve.count];
        for (NSNumber *v in avgCurve) [norm addObject:@(v.doubleValue / ss)];
        return [norm copy];
    } @catch (NSException *e) {
        NSLog(@"⚠️ normalizedRollStepCurve 异常: %@", e);
        return nil;
    }
}

/// BBL header → 真实 Roll PID (P/I/D/FF), 缺字段 fallback 到 001.bbl 实测值
- (void)readRealRollPIDFromBBL:(NSString *)bblPath
                          outP:(double *)outP outI:(double *)outI outD:(double *)outD outFF:(double *)outFF {
    NSDictionary *header = [BBLHeaderParser parseHeaderFromFile:bblPath];
    NSArray<NSString *> *pidParts = [[header objectForKey:@"rollPID"] componentsSeparatedByString:@","];
    NSArray<NSString *> *ffParts = [[header objectForKey:@"feedforward_weight"] componentsSeparatedByString:@","];
    if (outP)  *outP  = pidParts.count > 0 ? [pidParts[0] doubleValue] : 38.0;
    if (outI)  *outI  = pidParts.count > 1 ? [pidParts[1] doubleValue] : 85.0;
    if (outD)  *outD  = pidParts.count > 2 ? [pidParts[2] doubleValue] : 44.0;
    if (outFF) *outFF = ffParts.count > 0 ? [ffParts[0] doubleValue] : 72.0;
}

/// 相对误差 %
- (double)pctErr:(double)solved vs:(double)truth {
    if (fabs(truth) < 1e-9) return fabs(solved - truth) * 100.0;
    return fabs(solved - truth) / fabs(truth) * 100.0;
}

/// 真实BBL[001] Roll → 反解 P/D (最小验证: 真实曲线下框架是否工作)
- (void)testRealBBL_ReverseSolve_PD {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl, @"001.bbl 不在 test bundle");

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target, @"曲线提取失败");
    XCTAssertGreaterThan(target.count, 100);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];

    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];

    // 扰动初值 (P+40%, D-40%), I/FF 固定真值
    PIDValues *guess = [PIDValues new];
    guess.p = P * 1.4; guess.i = I; guess.d = D * 0.6; guess.ff = FF;

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:mech
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:(NSInteger)target.count duration:0.5];
    XCTAssertNotNil(r, @"反解返回 nil");

    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];

    // 写报告 (NSLog 被 Xcode16 ephemeral clone 吞, 写文件供测试外读取)
    NSString *report = [NSString stringWithFormat:
        @"targetN=%lu sampleRate=%.0f duration=0.5\ntruth:  P=%.0f I=%.0f D=%.0f FF=%.0f\nsolved: P=%.2f(%.1f%%) D=%.2f(%.1f%%)\niter=%ld RMSE=%.4f converged=%d",
        (unsigned long)target.count, sr, P, I, D, FF,
        r.solvedPID.p, pErr, r.solvedPID.d, dErr,
        (long)r.iterations, r.finalRMSE, r.converged];
    [report writeToFile:@"/tmp/realsolve_pd.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

    // 真实曲线非纯二阶, 首轮先只断言反解执行成功, 数值阈值待 /tmp/realsolve_pd.txt 看后定
    XCTAssertGreaterThan(r.solvedPID.p, 0, @"P 反解非正");
    XCTAssertGreaterThan(r.solvedPID.d, 0, @"D 反解非正");
}

/// 真实BBL[001] Roll → 反解全4参 (I 在单阶跃信号弱, 预期 I 仍塌到0, P/D/FF 是看点)
- (void)testRealBBL_ReverseSolve_AllFour {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];

    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];

    PIDValues *guess = [PIDValues new];
    guess.p = P * 1.3; guess.i = I * 1.3; guess.d = D * 0.7; guess.ff = FF * 0.7;

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:mech
                                                    fitMask:PIDReverseFitAll
                                                     length:(NSInteger)target.count duration:0.5];
    XCTAssertNotNil(r);

    double pErr  = [self pctErr:r.solvedPID.p  vs:P];
    double iErr  = [self pctErr:r.solvedPID.i  vs:I];
    double dErr  = [self pctErr:r.solvedPID.d  vs:D];
    double ffErr = [self pctErr:r.solvedPID.ff vs:FF];

    NSString *report = [NSString stringWithFormat:
        @"truth:  P=%.0f I=%.0f D=%.0f FF=%.0f\nsolved: P=%.2f(%.1f%%) I=%.2f(%.1f%%) D=%.2f(%.1f%%) FF=%.2f(%.1f%%)\niter=%ld RMSE=%.4f converged=%d",
        P, I, D, FF,
        r.solvedPID.p, pErr, r.solvedPID.i, iErr, r.solvedPID.d, dErr, r.solvedPID.ff, ffErr,
        (long)r.iterations, r.finalRMSE, r.converged];
    [report writeToFile:@"/tmp/realsolve_4p.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

    XCTAssertGreaterThan(r.solvedPID.p, 0);
}

/// 🔬 诊断: 从真值初值反解 — 区分 P 偏离的根因
///   真值初值 → LM 停在真值(±1%) → P 欠定(初值依赖, 正则化可治)
///   真值初值 → LM 漂移到 22      → 模型偏差(二阶 forward 系统拉低 ωn, 扩 forward 才能治)
- (void)testRealBBL_ReverseSolve_PD_TruthInit {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];

    // 基线: forward(真实PID) vs target 的 RMSE — 真实PID 在 forward 下离 target 多远
    PIDValues *truthPID = [PIDValues new];
    truthPID.p = P; truthPID.i = I; truthPID.d = D; truthPID.ff = FF;
    NSArray<NSNumber *> *fwdTruth = [PIDReverseSolver forwardCurveWithPID:truthPID
                                                             mechConstants:mech
                                                                     length:(NSInteger)target.count duration:0.5];
    double rmseTruth = [self rmseBetween:target and:fwdTruth];

    // 从真值初值反解 P/D
    PIDValues *guess = [PIDValues new];
    guess.p = P; guess.i = I; guess.d = D; guess.ff = FF;
    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:mech
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:(NSInteger)target.count duration:0.5];
    XCTAssertNotNil(r);

    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];

    NSString *report = [NSString stringWithFormat:
        @"基线 forward(真实PID=%.0f/%.0f) vs target: RMSE=%.4f\n从真值初值反解: P=%.2f(%.1f%%) D=%.2f(%.1f%%) iter=%ld RMSE=%.4f\n诊断: %@",
        P, D, rmseTruth,
        r.solvedPID.p, pErr, r.solvedPID.d, dErr,
        (long)r.iterations, r.finalRMSE,
        pErr < 1.0 ? @"P 保持真值 → P 欠定(初值依赖), 正则化可治"
                   : [NSString stringWithFormat:@"P 漂移%.1f%% → 模型偏差(二阶forward拉低ωn), 扩forward才能治", pErr]];
    [report writeToFile:@"/tmp/realsolve_truthinit.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

    XCTAssertGreaterThan(r.solvedPID.p, 0);
}

@end