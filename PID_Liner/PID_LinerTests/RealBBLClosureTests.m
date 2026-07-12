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

#pragma mark - [3.3b-2h] 吴bbl 6条反解公共输入容器

/// 6条吴bbl反解的公共提取结果 (2g内联, 抽出供 2h-a/2i 复用, 避免每个验证测试重抄提取逻辑)
@interface Wu6ReverseBundle : NSObject
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic, copy) NSArray<NSString *> *grps;
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *targets;
@property (nonatomic, strong) NSArray<NSNumber *> *Pv, *Iv, *Dv, *Fv, *Nv, *dMv, *dGv;
@property (nonatomic, strong) NSArray<BFFilterConfig *> *filters;
@property (nonatomic, assign) double bestK;
@property (nonatomic, copy) NSString *extractLog;
@property (nonatomic, copy) NSString *sweepLog;
@end

@implementation Wu6ReverseBundle
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
        // 唯一临时文件名 (基于输入 basename), 避免 001/003 等多 BBL 共享 001_rev.bbl 冲突
        NSString *baseName = [[bblPath lastPathComponent] stringByDeletingPathExtension];
        NSString *tempBBL = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_rev.bbl", baseName]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:tempBBL error:nil];
        // 清理同 basename 残留 CSV (blackbox-tools 输出 .NN.csv, 避免上次产物干扰本次解析)
        for (int s = 0; s < 10; s++) {
            NSString *oldCsv = [[tempBBL stringByDeletingPathExtension]
                stringByAppendingFormat:@".%02d.csv", s];
            [fm removeItemAtPath:oldCsv error:nil];
        }
        if (![fm copyItemAtPath:bblPath toPath:tempBBL error:nil]) return nil;

        // 多 session BBL: 选数据最多的 session
        // (003 logIdx0=1411点太短是解锁片段, logIdx1=55454点是主飞行)
        // ponytail: 试 logIdx 0..3, 够 16000 点(2个8000窗口)就停, 避免全 session 解码
        PIDCSVData *data = nil;
        NSInteger bestPts = 0;
        NSString *dir = [tempBBL stringByDeletingLastPathComponent];
        NSString *prefix = [[tempBBL lastPathComponent] stringByDeletingPathExtension];
        for (int tryLog = 0; tryLog < 4; tryLog++) {
            for (int s = 0; s < 10; s++) {
                NSString *c = [[tempBBL stringByDeletingPathExtension] stringByAppendingFormat:@".%02d.csv", s];
                [fm removeItemAtPath:c error:nil];
            }
            BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
            if ([decoder decodeFlightLog:tempBBL logIndex:tryLog] != 0) break;  // 无更多 session
            NSString *csvFound = nil;
            for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([f hasPrefix:prefix] && [f hasSuffix:@".csv"]) { csvFound = [dir stringByAppendingPathComponent:f]; break; }
            }
            PIDCSVData *d = csvFound ? [[PIDCSVParser parser] parseCSV:csvFound] : nil;
            NSInteger pts = d ? d.timeUs.count : 0;
            if (pts > bestPts) { bestPts = pts; data = d; }
            if (pts > 16000) break;  // 够 2 个 8000 窗口, 不用试更多
        }
        if (!data || data.timeUs.count < 100) return nil;

        double sampleRate = data.sampleRate > 0 ? data.sampleRate : 8000.0;
        if (outSR) *outSR = sampleRate;

        NSInteger windowSize = 8000;  // 7.8秒@1024Hz: 完整捕捉阶跃响应(含稳态); 1秒窗口RMSE 0.067→0.34反解崩溃
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
/// FF 增益字段版本差异: BF4.2=feedforward_weight, BF4.5+=ff_weight (优先4.2, 回退4.5)
- (void)readRealRollPIDFromBBL:(NSString *)bblPath
                          outP:(double *)outP outI:(double *)outI outD:(double *)outD outFF:(double *)outFF {
    NSDictionary *header = [BBLHeaderParser parseHeaderFromFile:bblPath];
    NSArray<NSString *> *pidParts = [[header objectForKey:@"rollPID"] componentsSeparatedByString:@","];
    NSString *ffField = [header objectForKey:@"feedforward_weight"];  // BF4.2
    if (ffField.length == 0) ffField = [header objectForKey:@"ff_weight"];  // BF4.5+ 改名
    NSArray<NSString *> *ffParts = [ffField componentsSeparatedByString:@","];
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

/// 🎯 3.3a 真实BBL续: 带 gyro 低通反解 — 验证 P 能否从 22.48 → 接近 38
/// 3.3a 合成已证: forward 加 gyro150Hz 低通后 P 偏差消除 (合成 43.4%→0.00%)
/// 此测试: 同款滤波上真实 001.bbl, P 误差能从 40.8% 降到多少?
- (void)testRealBBL_ReverseSolve_PD_WithGyroLowpass {
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
    guess.p = P * 1.4; guess.i = I; guess.d = D * 0.6; guess.ff = FF;

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:mech
                                              filterConfig:[BFFilterConfig gyroLowpass:150.0]
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:(NSInteger)target.count duration:0.5];
    XCTAssertNotNil(r);

    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];

    NSString *report = [NSString stringWithFormat:
        @"[3.3a 真实BBL] 001.bbl Roll, 带 gyro150Hz 低通反解\n"
        @"truth:  P=%.0f I=%.0f D=%.0f FF=%.0f\n"
        @"solved: P=%.2f(%.1f%%) D=%.2f(%.1f%%) iter=%ld RMSE=%.4f\n"
        @"对比3.2无滤波: P=22.48(40.8%%)\n"
        @"判定: %@",
        P, I, D, FF,
        r.solvedPID.p, pErr, r.solvedPID.d, dErr, (long)r.iterations, r.finalRMSE,
        pErr < 15.0 ? @"✅ P误差<15% → 加低通在真实BBL也有效"
                    : @"⚠️ P仍>15% → 真实曲线还有dterm动态未建模, 需3.3b扩滤波"];
    [report writeToFile:@"/tmp/realsolve_lowpass.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

    XCTAssertGreaterThan(r.solvedPID.p, 0);
}

/// 🔬 3.3a 扫频: gyro 低通截止 Hz → 反解 P, 找 P=38(真值) 对应的等效截止 f*
/// 已知两端: 0Hz→P=22.48(偏低40.8%), 150Hz→P=77.78(偏高104.7%)
/// 目标: 看 P 随 f 是否单调, 定位 f* 使 P≈38 (该 f* 即真实 BBL 的等效涂抹截止)
- (void)testRealBBL_ReverseSolve_PD_LowpassSweep {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);
    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target);
    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];
    PIDReverseSolver *solver = [PIDReverseSolver new];

    double hzs[] = {0, 50, 100, 150, 200, 300, 500};
    int cnt = (int)(sizeof(hzs) / sizeof(hzs[0]));
    NSMutableString *rep = [NSMutableString stringWithFormat:
        @"[3.3a 扫频] 001.bbl Roll, P真值=%.0f D真值=%.0f\n截止Hz → 反解P(误差%%) D  RMSE\n", P, D];
    for (int k = 0; k < cnt; k++) {
        PIDValues *guess = [PIDValues new];
        guess.p = P * 1.2; guess.i = I; guess.d = D * 0.8; guess.ff = FF;
        BFFilterConfig *f = (hzs[k] > 0) ? [BFFilterConfig gyroLowpass:hzs[k]]
                                          : [BFFilterConfig noFilter];
        PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                                  initialGuess:guess
                                                 mechConstants:mech
                                                  filterConfig:f
                                                        fitMask:PIDReverseFitP | PIDReverseFitD
                                                         length:(NSInteger)target.count duration:0.5];
        double pErr = r ? [self pctErr:r.solvedPID.p vs:P] : -1.0;
        [rep appendFormat:@"  %4.0fHz → P=%6.1f(%5.1f%%)  D=%6.1f  RMSE=%.4f\n",
            hzs[k], r.solvedPID.p, pErr, r.solvedPID.d, r.finalRMSE];
    }
    [rep appendString:@"\n判定: P 随 f 单调 → 加低通方向对, f* 处 P≈38 即真实等效涂抹截止\n"];
    [rep writeToFile:@"/tmp/realsolve_sweep.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertGreaterThan(P, 0);
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

#pragma mark - 阶段3.3b-1: BF 真实 gyro 三级 PT1 链 (替换3.3a猜错的biquad)

// 背景: 3.3a 用单 biquad 扫频, 200Hz 得 P=42.6(12%最近), 但 RMSE 地板 0.063 全程不降
//       (单 biquad 不增模型容量). 且 BF type=0=PT1, 3.3a 用 biquad 类型建错.
// 3.3b-1: 换 BF 真实 type=0 PT1, 三级串联 (BBL header 实测 gyro_lowpass=200/lowpass2=250/dyn=200-500)
// 看点: ① P 误差能否 <5%  ② finalRMSE 地板能否 <0.063 (降=PT1链真增容量, 方向对, 继续dterm)

/// 🎯 真实BBL[001] + BF真实 gyro 三级 PT1 链 (200/250/dyn200) 反解 P/D
- (void)testRealBBL_ReverseSolve_PD_WithGyroPT1Chain {
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
    guess.p = P * 1.4; guess.i = I; guess.d = D * 0.6; guess.ff = FF;

    // BF 真实 gyro 三级 PT1 (001.bbl header 实测): 200 / 250 / dyn 取下限 200 (低油门)
    BFFilterConfig *filter = [BFFilterConfig gyroPT1Chain:200.0 h2:250.0 dyn:200.0];

    PIDReverseSolver *solver = [PIDReverseSolver new];
    PIDReverseSolveResult *r = [solver solveFromTargetCurve:target
                                              initialGuess:guess
                                             mechConstants:mech
                                              filterConfig:filter
                                                    fitMask:PIDReverseFitP | PIDReverseFitD
                                                     length:(NSInteger)target.count duration:0.5];
    XCTAssertNotNil(r);

    double pErr = [self pctErr:r.solvedPID.p vs:P];
    double dErr = [self pctErr:r.solvedPID.d vs:D];

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-1 真实BBL] 001.bbl Roll, BF真实gyro三级PT1链 (200/250/200)\n"
        @"truth:  P=%.0f I=%.0f D=%.0f FF=%.0f\n"
        @"solved: P=%.2f(%.1f%%) D=%.2f(%.1f%%) iter=%ld RMSE=%.4f\n"
        @"对比:\n"
        @"  3.2 无滤波:       P=22.48(40.8%%) RMSE=0.0626\n"
        @"  3.3a 单biquad200: P=42.6(12.1%%)  RMSE=0.0648\n"
        @"判定: %@",
        P, I, D, FF,
        r.solvedPID.p, pErr, r.solvedPID.d, dErr, (long)r.iterations, r.finalRMSE,
        pErr < 5.0 ? @"✅ P<5% → PT1链治本, 可上dterm"
                   : (r.finalRMSE < 0.060 ? @"🔶 P仍偏但RMSE降了 → PT1链增容量, 继续dterm(3.3b-2)"
                                          : @"❌ P偏+RMSE不降 → PT1链不够, 问题在d_min动态/TPA/模型结构")];
    [report writeToFile:@"/tmp/realsolve_pt1chain.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"🎯 3.3b-1 PT1链: P=%.2f(%.1f%%) D=%.2f(%.1f%%) RMSE=%.4f",
          r.solvedPID.p, pErr, r.solvedPID.d, dErr, r.finalRMSE);
    XCTAssertGreaterThan(r.solvedPID.p, 0);
}

/// 🔬 3.3b 诊断: residual = target − forward(真实PID) 频谱, 定位 RMSE 地板性质
/// 3.3b-1 证 gyro 低通(任何形式)破不了 RMSE 地板(~0.063) → 地板是模型产生不了的曲线结构
/// 本测试输出 target/forward/residual 三列到 /tmp/residual_diag.txt, 供离线 FFT 分析:
///   残余集中低频→I/稳态; 中频→dterm动态振荡(确认方向); 白噪→统计噪声(致命); 峰→RPM谐波
- (void)testRealBBL_ResidualSpectrumDiag {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];

    PIDValues *truth = [PIDValues new];
    truth.p = P; truth.i = I; truth.d = D; truth.ff = FF;
    NSArray<NSNumber *> *fwd = [PIDReverseSolver forwardCurveWithPID:truth
                                                        mechConstants:mech
                                                                length:(NSInteger)target.count
                                                              duration:0.5];
    XCTAssertNotNil(fwd);

    NSInteger N = MIN(target.count, fwd.count);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"# 3.3b residual 频谱诊断 001.bbl Roll (N=%ld duration=0.5s fs=%.1fHz)\n"
        @"# truth PID: P=%.0f I=%.0f D=%.0f FF=%.0f\n"
        @"# 列: target  forward  residual(target-fwd)\n",
        (long)N, (double)(N - 1) / 0.5, P, I, D, FF];
    double sumSq = 0.0;
    for (NSInteger k = 0; k < N; k++) {
        double t = target[k].doubleValue;
        double f = fwd[k].doubleValue;
        double res = t - f;
        sumSq += res * res;
        [out appendFormat:@"%.6f %.6f %.6f\n", t, f, res];
    }
    double rmse = sqrt(sumSq / (double)N);
    NSString *header = [NSString stringWithFormat:@"# residual RMSE=%.4f (=RMSE地板, forward(真实PID)离target多远)\n", rmse];
    [out insertString:header atIndex:0];

    [out writeToFile:@"/tmp/residual_diag.txt" atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🔬 residual 诊断: N=%ld RMSE=%.4f → /tmp/residual_diag.txt", (long)N, rmse);
    XCTAssertGreaterThan(N, 100);
}

#pragma mark - 阶段3.3b-2b: 时域 forward + dterm 三级 PT1 链 vs 真实 BBL

// 背景: 2a 时域骨架已对齐解析 h(t) (纯PD RMSE=2.7e-8). 2b 加 BF 真实 dterm 三级 PT1 (150/150/120).
// 假设 (3.3b-1 频谱诊断): RMSE 地板 ~0.063 的残余 40-70Hz 占 34% = dterm 动态振荡.
//   固定 D (解析/2a) 全频阻尼 → 产生不了这带振荡 → 残余;
//   dterm 低通衰减高频 D → 等效阻尼在高频下降 → 能产生 20-100Hz 振荡 → 残余应降.
// 看点: ① td+dterm 的 RMSE 是否 < 解析 0.069  ② 残差 20-100Hz 带能量是否下降

/// 带内功率 (Goertzel 风格直接相关, fs Hz, fLo~fHi Hz, 2Hz 分辨率)
/// ponytail: 不引 Accelerate, N~4000 带内 ~40 频点 × N = 160k 次运算, 测试可接受
- (double)bandEnergy:(NSArray<NSNumber *> *)sig fs:(double)fs fLo:(double)fLo fHi:(double)fHi {
    NSInteger N = sig.count;
    if (N < 4 || fs <= 0 || fHi <= fLo) return 0.0;
    double dt = 1.0 / fs;
    double e = 0.0;
    for (double f = fLo; f <= fHi + 1e-9; f += 2.0) {
        double w = 2.0 * M_PI * f;
        double re = 0.0, im = 0.0;
        for (NSInteger k = 0; k < N; k++) {
            double s = sig[k].doubleValue;
            double ang = w * (double)k * dt;
            re += s * cos(ang);
            im += s * sin(ang);
        }
        e += (re * re + im * im);
    }
    return e / ((double)N * (double)N * (double)((NSInteger)((fHi - fLo) / 2.0) + 1));
}

/// 🎯 3.3b-2b: 真实 BBL vs 三路 forward (解析 / 时域无dterm / 时域+dterm链)
/// 判定 dterm 三级 PT1 链能否降 RMSE 地板 + 残差 20-100Hz 带能量
- (void)testRealBBL_TimeDomain_DtermChain_VsAnalytic {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    XCTAssertNotNil(target);
    NSInteger N = (NSInteger)target.count;
    XCTAssertGreaterThan(N, 100);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];

    PIDValues *pid = [PIDValues new];
    pid.p = P; pid.i = I; pid.d = D; pid.ff = FF;

    // 三路 forward
    NSArray<NSNumber *> *fwdAnalytic = [PIDReverseSolver forwardCurveWithPID:pid
                                                                 mechConstants:mech
                                                                         length:N duration:0.5];
    NSArray<NSNumber *> *fwdTD_NoDterm = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                              mechConstants:mech
                                                                              filterConfig:nil
                                                                                     length:N duration:0.5];
    BFFilterConfig *dtermChain = [BFFilterConfig dtermPT1Chain:150.0 h2:150.0 dyn:120.0];
    NSArray<NSNumber *> *fwdTD_Dterm = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                            mechConstants:mech
                                                                            filterConfig:dtermChain
                                                                                   length:N duration:0.5];

    // 残差 (target − forward)
    NSMutableArray<NSNumber *> *resA = [NSMutableArray arrayWithCapacity:N];
    NSMutableArray<NSNumber *> *resTN = [NSMutableArray arrayWithCapacity:N];
    NSMutableArray<NSNumber *> *resTD = [NSMutableArray arrayWithCapacity:N];
    for (NSInteger k = 0; k < N; k++) {
        double t = target[k].doubleValue;
        [resA  addObject:@(t - fwdAnalytic[k].doubleValue)];
        [resTN addObject:@(t - fwdTD_NoDterm[k].doubleValue)];
        [resTD addObject:@(t - fwdTD_Dterm[k].doubleValue)];
    }

    double rmseA  = [self rmseBetween:target and:fwdAnalytic];
    double rmseTN = [self rmseBetween:target and:fwdTD_NoDterm];
    double rmseTD = [self rmseBetween:target and:fwdTD_Dterm];

    double fs = (double)(N - 1) / 0.5;
    double bandA  = [self bandEnergy:resA  fs:fs fLo:20.0 fHi:100.0];
    double bandTN = [self bandEnergy:resTN fs:fs fLo:20.0 fHi:100.0];
    double bandTD = [self bandEnergy:resTD fs:fs fLo:20.0 fHi:100.0];

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2b 真实BBL] 001.bbl Roll, 三路 forward 对比 (PID=%.0f/%.0f/%.0f/%.0f)\n"
        @"  解析 (经验I/FF 0.3权重):     RMSE=%.4f  带20-100Hz=%.4e\n"
        @"  时域 无dterm (物理I/FF):     RMSE=%.4f  带20-100Hz=%.4e\n"
        @"  时域 +dterm链(150/150/120):  RMSE=%.4f  带20-100Hz=%.4e\n"
        @"判定: %@",
        P, I, D, FF,
        rmseA, bandA, rmseTN, bandTN, rmseTD, bandTD,
        rmseTD < rmseA ? @"✅ dterm链降RMSE → D路径建模对, 可上2c(d_min/TPA)"
                       : @"⚠️ dterm链未降RMSE → 需查dScale标定或FF, 留分析"];
    [report writeToFile:@"/tmp/realsolve_td_dterm.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertGreaterThan(rmseTD, 0.0);  // 仅断言执行成功, 数值由 /tmp 报告判定 (2b 探索阶段)
}

/// 🎯 3.3b-2c-α: dScale 扫描基线 (最小信息量实验, 定 2c 方向)
///
/// 2b 实锤: dterm 链 + 旧 dScale(0.0007) → 过振荡 (RMSE 0.069→0.120, 带 20-100Hz 翻 3 倍).
/// 根因假设: dScale=0.0007 是为"固定 D 全频阻尼"标定, 隐式含 dterm 滤波补偿;
///           显式加 dterm 滤波后用同一 dScale → 高频阻尼被削两次 → 过振荡.
///           修正方向应为"更大 dScale"补偿回被滤掉的高频 D.
///
/// 本测试扫 dScale, 找时域+dterm 链最小 RMSE, 判定 2c 后续:
///   最优 RMSE ≤ 0.0669 (无 dterm 基线) → dScale 重标定够, d_min/TPA 可选 (Ponytail 止步)
///   最优 RMSE > 0.0669                  → 光调 dScale 不够, 需 d_min 非线性 (进 2c-β)
- (void)testRealBBL_TimeDomain_DtermChain_dScaleSweep {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    NSInteger N = (NSInteger)target.count;
    XCTAssertGreaterThan(N, 100);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];

    PIDValues *pid = [PIDValues new];
    pid.p = P; pid.i = I; pid.d = D; pid.ff = FF;

    BFFilterConfig *dtermChain = [BFFilterConfig dtermPT1Chain:150.0 h2:150.0 dyn:120.0];
    double fs = (double)(N - 1) / 0.5;

    // 扫描点: 覆盖 0.0007 上下一个量级 (0.0003 ~ 0.0050)
    double dScales[] = {0.0003, 0.0005, 0.0007, 0.0010, 0.0015, 0.0020, 0.0030, 0.0050};
    int nSweep = (int)(sizeof(dScales) / sizeof(dScales[0]));

    double bestRMSE = 1e9, bestDScale = 0.0, bestBand = 0.0;
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"[3.3b-2c-α dScale扫描] 001.bbl Roll, 时域+dterm链(150/150/120), PID=%.0f/%.0f/%.0f/%.0f\n"
        @"基线: 无dterm RMSE=0.0669 | 旧dScale(0.0007)+dterm RMSE=0.1203\n", P, I, D, FF];

    for (int i = 0; i < nSweep; i++) {
        double ds = dScales[i];
        BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:ds];
        NSArray<NSNumber *> *fwd = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                     mechConstants:mech
                                                                     filterConfig:dtermChain
                                                                            length:N duration:0.5];
        // 残差 (target − forward) 与带内能量
        NSMutableArray<NSNumber *> *res = [NSMutableArray arrayWithCapacity:N];
        for (NSInteger k = 0; k < N; k++) [res addObject:@(target[k].doubleValue - fwd[k].doubleValue)];
        double rmse = [self rmseBetween:target and:fwd];
        double band = [self bandEnergy:res fs:fs fLo:20.0 fHi:100.0];
        [report appendFormat:@"  dScale=%.5f  Kd_eff=%.5f  RMSE=%.4f  带20-100Hz=%.4e\n",
                              ds, D * ds, rmse, band];
        if (rmse < bestRMSE) { bestRMSE = rmse; bestDScale = ds; bestBand = band; }
    }

    [report appendFormat:@"最优: dScale=%.5f Kd_eff=%.5f RMSE=%.4f 带20-100Hz=%.4e\n",
                          bestDScale, D * bestDScale, bestRMSE, bestBand];
    [report appendFormat:@"判定: %@",
        (bestRMSE <= 0.0669) ? @"✅ dScale重标定够 → d_min/TPA可选 (止步)"
                             : @"⚠️ 光调dScale不够 → 需d_min非线性 (进2c-β)"];
    [report writeToFile:@"/tmp/realsolve_td_dscale_sweep.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertGreaterThan(bestRMSE, 0.0);  // 仅断言执行成功, 方向由 /tmp 报告判定
}

/// 🎯 3.3b-2c-β: d_min 非线性动态 D (解开 α 的单 dScale 死锁)
///
/// α 实锤: 单 dScale 是 trade-off 死锁 (升 dScale 压对 20-100Hz 振荡但坏形状, 降反之).
/// β 假设: d_min 让 D 动态 — k=0 setpoint 变: D=D_max 压超调; k>0 静止: D=d_min 保形状,
///         能同时满足"压振荡"+"保形状", RMSE 降到 α 最优 (0.1116) 之下, 趋近无 dterm 基线 (0.0669).
/// BBL header 真实值: rollPID D=44 (D_max), d_min=29, d_min_gain=37.
/// 扫 dMin{0禁用, 29真实} × dScale, 判定动态 D 是否解开死锁.
- (void)testRealBBL_TimeDomain_DminDynamic_Sweep {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl = [bundle pathForResource:@"001" ofType:@"bbl"];
    XCTAssertNotNil(bbl);

    double sr = 0;
    NSArray<NSNumber *> *target = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
    NSInteger N = (NSInteger)target.count;
    XCTAssertGreaterThan(N, 100);

    double P = 0, I = 0, D = 0, FF = 0;
    [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
    double dMinGainReal = 37.0;  // BBL header: d_min_gain=37

    PIDValues *pid = [PIDValues new];
    pid.p = P; pid.i = I; pid.d = D; pid.ff = FF;

    BFFilterConfig *dtermChain = [BFFilterConfig dtermPT1Chain:150.0 h2:150.0 dyn:120.0];
    double fs = (double)(N - 1) / 0.5;

    double dScales[] = {0.0003, 0.0007, 0.0010};
    double dMins[]   = {0.0, 29.0};  // 0=禁用(2b 固定 D), 29=BBL 真实 d_min
    int nDS = (int)(sizeof(dScales) / sizeof(dScales[0]));
    int nDM = (int)(sizeof(dMins) / sizeof(dMins[0]));

    double bestRMSE = 1e9, bestDScale = 0.0, bestDmin = 0.0;
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"[3.3b-2c-β d_min动态] 001.bbl Roll, 时域+dterm链(150/150/120), PID=%.0f/%.0f/%.0f/%.0f, d_min_gain=%.0f\n"
        @"基线: α最优(禁用d_min, dScale=0.0003)=0.1116 | 无dterm=0.0669\n", P, I, D, FF, dMinGainReal];

    for (int im = 0; im < nDM; im++) {
        for (int is = 0; is < nDS; is++) {
            double dm = dMins[im], ds = dScales[is];
            BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01
                                                          dScale:ds dMin:dm dMinGain:dMinGainReal];
            NSArray<NSNumber *> *fwd = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                                                                         mechConstants:mech
                                                                         filterConfig:dtermChain
                                                                                length:N duration:0.5];
            NSMutableArray<NSNumber *> *res = [NSMutableArray arrayWithCapacity:N];
            for (NSInteger k = 0; k < N; k++) [res addObject:@(target[k].doubleValue - fwd[k].doubleValue)];
            double rmse = [self rmseBetween:target and:fwd];
            double band = [self bandEnergy:res fs:fs fLo:20.0 fHi:100.0];
            [report appendFormat:@"  dMin=%-5.1f dScale=%.4f  RMSE=%.4f  带20-100Hz=%.4e\n",
                                  dm, ds, rmse, band];
            if (rmse < bestRMSE) { bestRMSE = rmse; bestDScale = ds; bestDmin = dm; }
        }
    }

    [report appendFormat:@"最优: dMin=%.1f dScale=%.4f RMSE=%.4f\n", bestDmin, bestDScale, bestRMSE];
    [report appendFormat:@"判定: %@",
        (bestDmin > 0.0 && bestRMSE < 0.1116) ? @"✅ d_min降RMSE → 动态D解开死锁 (进γ/TPA 或定稿)"
                                              : (bestDmin > 0.0 ? @"⚠️ d_min未明显降RMSE → 查dMinGain/dterm参数"
                                                                : @"⚠️ 禁用d_min最优 → d_min建模有误")];
    [report writeToFile:@"/tmp/realsolve_td_dmin.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertGreaterThan(bestRMSE, 0.0);  // 仅断言执行成功, 方向由 /tmp 报告判定
}

/// 🎯 2c 交叉验证基线 (Silen 001+003 同架不同 PID) — 摆脱"样本=1"
///
/// 003.bbl 是 Silen 同架不同 PID (P 38→34, D 44→39, d_min 29→26), 一直在项目主目录没进测试.
/// 本测试: 两条 BBL 各自反解 P/D (当前解析 forward + 固定 K=87/τ=0.01), 看 P 偏差是否系统性.
///   两条 P 偏差接近 → 系统性模型偏差 (K_plant/τ_m 错, 标定可治)
///   两条 P 偏差差异大 → PID 相关, 标定救不了, 要扩 forward
- (void)testCrossValidation_Silen_Baseline {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl001 = [bundle pathForResource:@"001" ofType:@"bbl"];
    NSString *bbl003 = [bundle pathForResource:@"003" ofType:@"bbl"];
    XCTAssertNotNil(bbl001, @"001.bbl 未在 test bundle");
    XCTAssertNotNil(bbl003, @"003.bbl 未在 test bundle (PBXFileSystemSynchronized 应自动加)");

    double sr1 = 0, sr3 = 0;
    NSArray<NSNumber *> *t1 = [self normalizedRollStepCurveFromBBL:bbl001 outSampleRate:&sr1];
    NSArray<NSNumber *> *t3 = [self normalizedRollStepCurveFromBBL:bbl003 outSampleRate:&sr3];
    XCTAssertGreaterThan(t1.count, 100);
    XCTAssertGreaterThan(t3.count, 100);

    double P1=0,I1=0,D1=0,FF1=0, P3=0,I3=0,D3=0,FF3=0;
    [self readRealRollPIDFromBBL:bbl001 outP:&P1 outI:&I1 outD:&D1 outFF:&FF1];
    [self readRealRollPIDFromBBL:bbl003 outP:&P3 outI:&I3 outD:&D3 outFF:&FF3];

    BFMechConstants *mech = [BFMechConstants withKPlant:87.0 tauM:0.01 dScale:0.0007];
    PIDReverseSolver *solver = [PIDReverseSolver new];

    // 反解 001 (扰动初值 P+40%/D-40%, I/FF 固定真值)
    PIDValues *g1 = [PIDValues new];
    g1.p=P1*1.4; g1.i=I1; g1.d=D1*0.6; g1.ff=FF1;
    PIDReverseSolveResult *r1 = [solver solveFromTargetCurve:t1 initialGuess:g1
                                               mechConstants:mech fitMask:PIDReverseFitP|PIDReverseFitD
                                                    length:(NSInteger)t1.count duration:0.5];
    // 反解 003
    PIDValues *g3 = [PIDValues new];
    g3.p=P3*1.4; g3.i=I3; g3.d=D3*0.6; g3.ff=FF3;
    PIDReverseSolveResult *r3 = [solver solveFromTargetCurve:t3 initialGuess:g3
                                               mechConstants:mech fitMask:PIDReverseFitP|PIDReverseFitD
                                                    length:(NSInteger)t3.count duration:0.5];
    XCTAssertNotNil(r1); XCTAssertNotNil(r3);

    double pErr1 = [self pctErr:r1.solvedPID.p vs:P1];
    double pErr3 = [self pctErr:r3.solvedPID.p vs:P3];
    double dErr1 = [self pctErr:r1.solvedPID.d vs:D1];
    double dErr3 = [self pctErr:r3.solvedPID.d vs:D3];

    NSString *report = [NSString stringWithFormat:
        @"[2c 交叉验证基线] Silen 001+003 (解析forward, K=87/τ=0.01/dScale=0.0007)\n"
        @"001: truth P=%.0f D=%.0f d_min=29 → solved P=%.2f(%.1f%%) D=%.2f(%.1f%%) RMSE=%.4f\n"
        @"003: truth P=%.0f D=%.0f d_min=26 → solved P=%.2f(%.1f%%) D=%.2f(%.1f%%) RMSE=%.4f\n"
        @"P偏差差 = |%.1f − %.1f| = %.1f%%\n"
        @"判定: %@",
        P1,D1, r1.solvedPID.p,pErr1, r1.solvedPID.d,dErr1, r1.finalRMSE,
        P3,D3, r3.solvedPID.p,pErr3, r3.solvedPID.d,dErr3, r3.finalRMSE,
        pErr1, pErr3, fabs(pErr1-pErr3),
        (fabs(pErr1-pErr3) < 10.0)
            ? @"✅ 两条P偏差接近(<10%) → 系统性模型偏差, 标定K_plant/τ_m可治"
            : @"⚠️ 两条P偏差差异大 → PID相关, 标定救不了, 需扩forward"];
    [report writeToFile:@"/tmp/crossval_baseline.txt" atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);

    XCTAssertGreaterThan(r1.solvedPID.p, 0);
    XCTAssertGreaterThan(r3.solvedPID.p, 0);
}

/// 诊断: 全部 BBL 各 session 数据长度 (决定哪些够 windowSize=8000 做统计阶跃)
/// 001/003 from bundle; 吴bbl 6 条 (BF4.5) 用绝对路径 (诊断用, 不 portable)
- (void)testBBL_AllSessionLengths {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSArray *> *bbls = @[
        @[@"001(Silen4.2.6)",   [bundle pathForResource:@"001" ofType:@"bbl"] ?: @""],
        @[@"003(Silen4.2.6)",   [bundle pathForResource:@"003" ofType:@"bbl"] ?: @""],
        @[@"吴515inch2.0(4.5.2)", @"/Users/liangjuan/PID_Liner/吴bbl/515inch2.0.BBL"],
        @[@"吴WU3(4.5.3)",       @"/Users/liangjuan/PID_Liner/吴bbl/WU3.BBL"],
        @[@"吴bde51.2.0(4.5.3)", @"/Users/liangjuan/PID_Liner/吴bbl/bde51.2.0.BBL"],
        @[@"吴xxx5101(4.5.3)",   @"/Users/liangjuan/PID_Liner/吴bbl/xxx5101.BBL"],
        @[@"吴五一LOG(4.5.2)",   @"/Users/liangjuan/PID_Liner/吴bbl/五一五寸LOG_20260501_144246_MAMBAF722_2022B.BBL"],
        @[@"吴bde51.3.0(4.5.3)", @"/Users/liangjuan/PID_Liner/吴bbl/吴bde51.3.0.BBL"],
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableString *report = [NSMutableString stringWithFormat:@"各 BBL session 数据长度 (windowSize=8000 需点数>>8000):\n"];
    for (NSUInteger i = 0; i < bbls.count; i++) {
        NSString *name = bbls[i][0];
        NSString *src  = bbls[i][1];
        if (src.length == 0 || ![fm fileExistsAtPath:src]) {
            [report appendFormat:@"\n%@: 文件不存在\n", name];
            continue;
        }
        [report appendFormat:@"\n%@:\n", name];
        for (int logIdx = 0; logIdx < 2; logIdx++) {
            NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"sesslen_%lu_%d.bbl", (unsigned long)i, logIdx]];
            [fm removeItemAtPath:temp error:nil];
            NSString *dir = [temp stringByDeletingLastPathComponent];
            NSString *prefix = [[temp lastPathComponent] stringByDeletingPathExtension];
            for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([f hasPrefix:prefix] && [f hasSuffix:@".csv"])
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            }
            [fm copyItemAtPath:src toPath:temp error:nil];
            BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
            int rc = [decoder decodeFlightLog:temp logIndex:logIdx];
            if (rc != 0) { [report appendFormat:@"  logIdx=%d rc=%d (无更多session)\n", logIdx, rc]; break; }
            NSString *csvFound = nil;
            for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([f hasPrefix:prefix] && [f hasSuffix:@".csv"]) { csvFound = [dir stringByAppendingPathComponent:f]; break; }
            }
            PIDCSVData *data = csvFound ? [[PIDCSVParser parser] parseCSV:csvFound] : nil;
            NSInteger pts = data ? data.timeUs.count : 0;
            double sr = data ? data.sampleRate : 0;
            [report appendFormat:@"  logIdx=%d 点数=%ld sampleRate=%.1f 时长=%.2fs 够8000窗口=%@\n",
                logIdx, (long)pts, sr, sr > 0 ? pts / sr : 0.0, pts > 8000 ? @"✅" : @"❌"];
        }
    }
    [report writeToFile:@"/tmp/bbl_session_lengths.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(bbls.count, 0);
}

/// 🎯 2c 标定 K_plant/τ_m + 交叉验证 (Silen 001 标定 → 003 验证)
///
/// 基线: 001 P偏低40.8%, 003 P偏低31.2% (系统性, 差9.6%). 假设 K_plant/τ_m 错致 P 系统偏低.
/// 标定: 扫 (K_plant, τ_m) 找 001 forward(真实PID) 最小 RMSE.
/// 交叉验证: 用 001 标定值反解 003, 看 P 误差是否也降 (降=非过拟合, 不降=过拟合001).
- (void)testCalibration_KPlant_TauM_CrossVal {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *bbl001 = [bundle pathForResource:@"001" ofType:@"bbl"];
    NSString *bbl003 = [bundle pathForResource:@"003" ofType:@"bbl"];
    XCTAssertNotNil(bbl001); XCTAssertNotNil(bbl003);

    double sr1=0, sr3=0;
    NSArray<NSNumber *> *t1 = [self normalizedRollStepCurveFromBBL:bbl001 outSampleRate:&sr1];
    NSArray<NSNumber *> *t3 = [self normalizedRollStepCurveFromBBL:bbl003 outSampleRate:&sr3];
    NSInteger N1 = (NSInteger)t1.count, N3 = (NSInteger)t3.count;

    double P1=0,I1=0,D1=0,FF1=0, P3=0,I3=0,D3=0,FF3=0;
    [self readRealRollPIDFromBBL:bbl001 outP:&P1 outI:&I1 outD:&D1 outFF:&FF1];
    [self readRealRollPIDFromBBL:bbl003 outP:&P3 outI:&I3 outD:&D3 outFF:&FF3];

    PIDValues *truth1 = [PIDValues new]; truth1.p=P1; truth1.i=I1; truth1.d=D1; truth1.ff=FF1;
    PIDValues *truth3 = [PIDValues new]; truth3.p=P3; truth3.i=I3; truth3.d=D3; truth3.ff=FF3;

    // 扫 (K_plant, τ_m) 找 001/003 各自 forward(真实PID) 最小 RMSE (dScale 固定 0.0007)
    double kPlants[] = {50, 70, 87, 110, 150};
    double tauMs[]   = {0.006, 0.010, 0.015};
    int nK = (int)(sizeof(kPlants)/sizeof(kPlants[0]));
    int nT = (int)(sizeof(tauMs)/sizeof(tauMs[0]));

    double bestRMSE1 = 1e9, bestK1 = 0, bestTau1 = 0;
    double bestRMSE3 = 1e9, bestK3 = 0, bestTau3 = 0;
    NSMutableString *sweep = [NSMutableString string];
    for (int ik = 0; ik < nK; ik++) {
        for (int it = 0; it < nT; it++) {
            BFMechConstants *m = [BFMechConstants withKPlant:kPlants[ik] tauM:tauMs[it] dScale:0.0007];
            NSArray<NSNumber *> *f1 = [PIDReverseSolver forwardCurveWithPID:truth1 mechConstants:m length:N1 duration:0.5];
            NSArray<NSNumber *> *f3 = [PIDReverseSolver forwardCurveWithPID:truth3 mechConstants:m length:N3 duration:0.5];
            double rmse1 = [self rmseBetween:t1 and:f1];
            double rmse3 = [self rmseBetween:t3 and:f3];
            [sweep appendFormat:@"  K=%-5.1f τ=%.4f → 001 RMSE=%.4f | 003 RMSE=%.4f\n", kPlants[ik], tauMs[it], rmse1, rmse3];
            if (rmse1 < bestRMSE1) { bestRMSE1 = rmse1; bestK1 = kPlants[ik]; bestTau1 = tauMs[it]; }
            if (rmse3 < bestRMSE3) { bestRMSE3 = rmse3; bestK3 = kPlants[ik]; bestTau3 = tauMs[it]; }
        }
    }

    PIDReverseSolver *solver = [PIDReverseSolver new];

    // 用 001 标定反解 001(自) + 003(交叉); 用 003 标定反解 003(自)
    BFMechConstants *calib1 = [BFMechConstants withKPlant:bestK1 tauM:bestTau1 dScale:0.0007];
    BFMechConstants *calib3 = [BFMechConstants withKPlant:bestK3 tauM:bestTau3 dScale:0.0007];
    PIDValues *g1 = [PIDValues new]; g1.p=P1*1.4; g1.i=I1; g1.d=D1*0.6; g1.ff=FF1;
    PIDValues *g3 = [PIDValues new]; g3.p=P3*1.4; g3.i=I3; g3.d=D3*0.6; g3.ff=FF3;
    PIDReverseSolveResult *r1self = [solver solveFromTargetCurve:t1 initialGuess:g1
                                                    mechConstants:calib1 fitMask:PIDReverseFitP|PIDReverseFitD
                                                         length:N1 duration:0.5];
    PIDReverseSolveResult *r3cross = [solver solveFromTargetCurve:t3 initialGuess:g3
                                                     mechConstants:calib1 fitMask:PIDReverseFitP|PIDReverseFitD
                                                          length:N3 duration:0.5];
    PIDReverseSolveResult *r3self = [solver solveFromTargetCurve:t3 initialGuess:g3
                                                    mechConstants:calib3 fitMask:PIDReverseFitP|PIDReverseFitD
                                                         length:N3 duration:0.5];
    XCTAssertNotNil(r1self); XCTAssertNotNil(r3cross); XCTAssertNotNil(r3self);

    double pErr1self  = [self pctErr:r1self.solvedPID.p  vs:P1];
    double pErr3cross = [self pctErr:r3cross.solvedPID.p vs:P3];
    double pErr3self  = [self pctErr:r3self.solvedPID.p  vs:P3];

    NSString *verdict;
    if (pErr1self < 5.0 && pErr3cross < 15.0) {
        verdict = @"✅ 001标定泛化到003 (K_plant是飞机常数)";
    } else if (pErr3self < 5.0) {
        verdict = [NSString stringWithFormat:@"⚠️ 003需不同K_plant(003最优K=%.1f vs 001 K=%.1f) → K_plant非飞机常数(过拟合)", bestK3, bestK1];
    } else {
        verdict = @"❌ 003自标定也不达标 → 003问题不在K_plant, 在forward结构(gyro链)";
    }

    NSString *report = [NSString stringWithFormat:
        @"[2c K_plant/τ_m 标定+交叉验证] Silen 001+003 (dScale=0.0007)\n"
        @"扫描 (forward(真实PID) RMSE):\n%@\n"
        @"001 最优: K=%.1f τ=%.4f RMSE=%.4f\n"
        @"003 最优: K=%.1f τ=%.4f RMSE=%.4f\n"
        @"反解 P 误差:\n"
        @"  001 用001标定(自):   P=%.2f(%.1f%%) [基线40.8%%]\n"
        @"  003 用001标定(交叉): P=%.2f(%.1f%%) [基线31.2%%]\n"
        @"  003 用003标定(自):   P=%.2f(%.1f%%)\n"
        @"判定: %@",
        sweep,
        bestK1, bestTau1, bestRMSE1,
        bestK3, bestTau3, bestRMSE3,
        r1self.solvedPID.p, pErr1self,
        r3cross.solvedPID.p, pErr3cross,
        r3self.solvedPID.p, pErr3self,
        verdict];
    [report writeToFile:@"/tmp/calib_ktau_crossval.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(r1self.solvedPID.p, 0);
}

/// 🎯 阶段3.3b-2d: 吴bbl 6条交叉验证 (BF4.5, 3种PID, 另一架飞机)
/// 3种P (42/26/32), 每种有重复样本 → 测区分度(不同P解出不同值) + 重复性(同P解出相近值)
/// 吴飞机K_plant未知 → 先扫K标定(6条forward时域平均RMSE最小), 再反解
/// BF4.5适配: FF fallback(header无feedforward_weight), d_min/d_max_gain从header读
/// duration=0.5 (avgCurve固定0~0.5s时间轴, line848-849, 与Silen可比)
- (void)testCrossValidation_WuBBL_Baseline {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    /// 6条BBL, 3种PID配置:
    ///   A (42/76/44, d_min=33~40): wu_515inch, wu_51log  [BF4.5.2, gyro动态0-500]
    ///   B (26/43/26, d_min=21):    wu_xxx5101            [BF4.5.3]
    ///   C (32/43/26, d_min=0):     wu_bde51_2_0/3_0, wu_wu3 [BF4.5.3]
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    // 1. 提取 6 条曲线 + PID 真值 + d_min/d_max_gain (明确类型并行数组, 避免malloc)
    NSMutableArray<NSString *> *names=[NSMutableArray array], *grps=[NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *targets=[NSMutableArray array];
    NSMutableArray<NSNumber *> *Pv=[NSMutableArray array], *Iv=[NSMutableArray array],
        *Dv=[NSMutableArray array], *Fv=[NSMutableArray array],
        *dMv=[NSMutableArray array], *dGv=[NSMutableArray array], *Nv=[NSMutableArray array];
    NSMutableString *extract = [NSMutableString stringWithString:@"曲线提取:\n"];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *name = spec[@"name"];
        NSString *bbl = [bundle pathForResource:name ofType:@"bbl"];
        if (!bbl) { [extract appendFormat:@"  %@: ❌ bundle无BBL\n", name]; continue; }
        double sr=0;  // sampleRate仅提纯用, forward用duration=0.5不依赖sr
        NSArray<NSNumber *> *t = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!t || t.count < 100) {
            [extract appendFormat:@"  %@: ❌ 曲线失败(N=%lu)\n", name, t?(unsigned long)t.count:0];
            continue;
        }
        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];  // FF fallback 72(BF4.5无feedforward_weight)
        NSDictionary<NSString *, NSString *> *header = [BBLHeaderParser parseHeaderFromFile:bbl];
        NSArray<NSString *> *dm = [[header objectForKey:@"d_min"] componentsSeparatedByString:@","];
        double dMin = dm.count>0 ? [dm[0] doubleValue] : 0.0;  // roll = 第0个
        double dGain = [[header objectForKey:@"d_max_gain"] doubleValue];

        [names addObject:name]; [grps addObject:spec[@"grp"]]; [targets addObject:t];
        [Pv addObject:@(P)]; [Iv addObject:@(I)]; [Dv addObject:@(D)]; [Fv addObject:@(FF)];
        [dMv addObject:@(dMin)]; [dGv addObject:@(dGain)]; [Nv addObject:@((NSInteger)t.count)];
        [extract appendFormat:@"  %@[%@] P=%.0f I=%.0f D=%.0f FF=%.0f dMin=%.0f dGain=%.0f N=%lu\n",
            name, spec[@"grp"], P,I,D,FF,dMin,dGain,(unsigned long)t.count];
    }
    NSInteger valid = (NSInteger)names.count;
    XCTAssertGreaterThanOrEqual(valid, 4, @"至少4条曲线提取成功");

    // 2. 扫 K (10-150) 找吴飞机最优 K_plant (6条forward时域平均RMSE最小)
    double kPlants[] = {10, 30, 50, 70, 90, 110, 150};
    int nK = (int)(sizeof(kPlants)/sizeof(kPlants[0]));
    double bestK = 50, bestAvgRMSE = 1e9;
    NSMutableString *sweep = [NSMutableString string];
    for (int ik=0; ik<nK; ik++) {
        double sumRMSE = 0;
        for (NSInteger j=0; j<valid; j++) {
            BFMechConstants *m = [BFMechConstants withKPlant:kPlants[ik] tauM:0.010
                                                       dScale:0.0007 dMin:dMv[j].doubleValue dMinGain:dGv[j].doubleValue];
            PIDValues *pid = [PIDValues new];
            pid.p=Pv[j].doubleValue; pid.i=Iv[j].doubleValue;
            pid.d=Dv[j].doubleValue; pid.ff=Fv[j].doubleValue;
            NSInteger N = Nv[j].integerValue;
            NSArray<NSNumber *> *f = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                mechConstants:m filterConfig:nil length:N duration:0.5];
            sumRMSE += [self rmseBetween:targets[j] and:f];
        }
        double avg = sumRMSE / (double)valid;
        [sweep appendFormat:@"  K=%-5.1f → %ld条平均RMSE=%.4f\n", kPlants[ik], (long)valid, avg];
        if (avg < bestAvgRMSE) { bestAvgRMSE = avg; bestK = kPlants[ik]; }
    }

    // 3. 用最优 K 反解 6 条 (fit P/D)
    NSMutableString *solve = [NSMutableString stringWithString:@"反解(fit P/D, 最优K):\n"];
    double pErrSum=0; NSInteger pCnt=0;
    for (NSInteger j=0; j<valid; j++) {
        BFMechConstants *m = [BFMechConstants withKPlant:bestK tauM:0.010
                                                   dScale:0.0007 dMin:dMv[j].doubleValue dMinGain:dGv[j].doubleValue];
        PIDValues *guess = [PIDValues new];
        double P=Pv[j].doubleValue, D=Dv[j].doubleValue;
        guess.p=P*1.3; guess.i=Iv[j].doubleValue; guess.d=D*0.7; guess.ff=Fv[j].doubleValue;
        NSInteger N = Nv[j].integerValue;
        PIDReverseSolver *solver = [PIDReverseSolver new];
        PIDReverseSolveResult *r = [solver solveFromTargetCurve:targets[j] initialGuess:guess
                                                    mechConstants:m fitMask:PIDReverseFitP|PIDReverseFitD
                                                         length:N duration:0.5];
        if (!r) { [solve appendFormat:@"  %@[%@]: ❌ 反解nil\n", names[j], grps[j]]; continue; }
        double pErr = [self pctErr:r.solvedPID.p vs:P];
        double dErr = [self pctErr:r.solvedPID.d vs:D];
        pErrSum += pErr; pCnt++;
        [solve appendFormat:@"  %@[%@] P真=%.0f 解=%.2f(%.1f%%) D真=%.0f 解=%.2f(%.1f%%) RMSE=%.4f iter=%ld\n",
            names[j], grps[j], P, r.solvedPID.p, pErr, D, r.solvedPID.d, dErr,
            r.finalRMSE, (long)r.iterations];
    }

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2d 吴bbl 6条交叉验证] BF4.5 另一架飞机 (duration=0.5)\n"
        @"%@\n"
        @"K_plant 扫描 (forward时域, %ld条平均RMSE):\n%@\n"
        @"吴飞机最优 K=%.1f (平均RMSE=%.4f) | Silen最优K=50\n"
        @"%@\n"
        @"平均 P 误差=%.1f%% (n=%ld)\n"
        @"判定: 区分度(A=42/B=26/C=32应解出不同P) + 重复性(同组应相近) + 精度(P误差<15%%)",
        extract, (long)valid, sweep, bestK, bestAvgRMSE, solve, pCnt>0?pErrSum/(double)pCnt:0.0, (long)pCnt];
    [report writeToFile:@"/tmp/realsolve_wu6.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(bestK, 0);
}

/// 🎯 阶段3.3b-2e: 吴bbl 6条 + gyro PT1 链 (解析forward, 验证P误差能否24.8%→<15%)
///
/// 2d基线: 反解走解析forward, filterConfig:nil → 无gyro涂抹 → P系统偏低24.8%
///   根因: 真实BBL的gyro已被BF低通涂抹变缓, forward无滤波只能降ωn匹配 → P偏低
/// 3.3a合成已证: forward加gyro低通后P偏差消除 (43.4%→0.00%)
/// 本测试: 解析forward + 每条BBL真实gyro PT1链(从header读) + K扫描, 看P能否达标
///
/// BF4.5 gyro通道 (strings实测): 2级结构 (BF4.2是3级)
///   lpf1: static>0用static, 否则dyn中点 (A组static=0,dyn0-500→250; B/C组static=250)
///   lpf2: lpf2_static_hz (A=450, B/C=500) — 第二级
///   → gyroPT1Chain(h1=lpf1等效, h2=lpf2, dyn=0) 跳过第三级 (BF4.5只2级)
///
/// 🔑 模型一致性: K扫描与反解都用解析forward+gyro链
///   (2d基线K扫描用时域带d_min, 反解用解析不带d_min — 历史遗留不一致, 本测试修正)
- (void)testCrossValidation_WuBBL_WithGyroChain {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    // 1. 提取6条曲线 + PID + gyro等效截止 (解析forward不读d_min, 故不提d_min)
    NSMutableArray<NSString *> *names=[NSMutableArray array], *grps=[NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *targets=[NSMutableArray array];
    NSMutableArray<NSNumber *> *Pv=[NSMutableArray array], *Iv=[NSMutableArray array],
        *Dv=[NSMutableArray array], *Fv=[NSMutableArray array],
        *Nv=[NSMutableArray array], *gH1v=[NSMutableArray array], *gH2v=[NSMutableArray array];
    NSMutableString *extract = [NSMutableString stringWithString:@"曲线提取 + gyro链:\n"];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *name = spec[@"name"];
        NSString *bbl = [bundle pathForResource:name ofType:@"bbl"];
        if (!bbl) { [extract appendFormat:@"  %@: ❌ bundle无BBL\n", name]; continue; }
        double sr=0;  // sampleRate仅提纯用, 解析forward用duration=0.5不依赖sr
        NSArray<NSNumber *> *t = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!t || t.count < 100) { [extract appendFormat:@"  %@: ❌ 曲线失败\n", name]; continue; }
        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];

        // BF4.5 gyro等效截止: lpf1(static>0?static:dyn中点) + lpf2
        NSDictionary<NSString *, NSString *> *header = [BBLHeaderParser parseHeaderFromFile:bbl];
        double lpf1Static = [[header objectForKey:@"gyro_lpf1_static_hz"] doubleValue];
        NSString *dynHzStr = [header objectForKey:@"gyro_lpf1_dyn_hz"];
        if (dynHzStr.length == 0) dynHzStr = @"0,500";  // BF4.5 缺字段兜底
        NSArray<NSString *> *dp = [dynHzStr componentsSeparatedByString:@","];
        double dynLo = dp.count>0 ? [dp[0] doubleValue] : 0;
        double dynHi = dp.count>1 ? [dp[1] doubleValue] : 500;
        double gH1 = (lpf1Static > 0) ? lpf1Static : (dynLo + dynHi) / 2.0;
        double gH2 = [[header objectForKey:@"gyro_lpf2_static_hz"] doubleValue];

        [names addObject:name]; [grps addObject:spec[@"grp"]]; [targets addObject:t];
        [Pv addObject:@(P)]; [Iv addObject:@(I)]; [Dv addObject:@(D)]; [Fv addObject:@(FF)];
        [Nv addObject:@((NSInteger)t.count)];
        [gH1v addObject:@(gH1)]; [gH2v addObject:@(gH2)];
        [extract appendFormat:@"  %@[%@] P=%.0f D=%.0f FF=%.0f N=%lu gyro(h1=%.0f,h2=%.0f)\n",
            name, spec[@"grp"], P, D, FF, (unsigned long)t.count, gH1, gH2];
    }
    NSInteger valid = (NSInteger)names.count;
    XCTAssertGreaterThanOrEqual(valid, 4, @"至少4条曲线提取成功");

    // 2. 扫K (解析forward + gyro链, 与反解一致)
    double kPlants[] = {50, 70, 90, 110, 130, 150};
    int nK = (int)(sizeof(kPlants)/sizeof(kPlants[0]));
    double bestK = 110, bestAvgRMSE = 1e9;
    NSMutableString *sweep = [NSMutableString string];
    for (int ik=0; ik<nK; ik++) {
        double sumRMSE = 0;
        for (NSInteger j=0; j<valid; j++) {
            BFMechConstants *m = [BFMechConstants withKPlant:kPlants[ik] tauM:0.010 dScale:0.0007];
            PIDValues *pid = [PIDValues new];
            pid.p=Pv[j].doubleValue; pid.i=Iv[j].doubleValue;
            pid.d=Dv[j].doubleValue; pid.ff=Fv[j].doubleValue;
            BFFilterConfig *f = [BFFilterConfig gyroPT1Chain:gH1v[j].doubleValue
                                                          h2:gH2v[j].doubleValue
                                                         dyn:0];
            NSInteger N = Nv[j].integerValue;
            NSArray<NSNumber *> *curve = [PIDReverseSolver forwardCurveWithPID:pid
                                                                mechConstants:m
                                                                filterConfig:f
                                                                       length:N duration:0.5];
            sumRMSE += [self rmseBetween:targets[j] and:curve];
        }
        double avg = sumRMSE / (double)valid;
        [sweep appendFormat:@"  K=%-5.1f → %ld条平均RMSE=%.4f\n", kPlants[ik], (long)valid, avg];
        if (avg < bestAvgRMSE) { bestAvgRMSE = avg; bestK = kPlants[ik]; }
    }

    // 3. 反解6条 (解析forward + gyro链)
    NSMutableString *solve = [NSMutableString stringWithString:@"反解(fit P/D, 解析forward+gyro链):\n"];
    double pErrSum=0; NSInteger pCnt=0;
    NSMutableArray<NSNumber *> *solvedP = [NSMutableArray array];
    NSMutableArray<NSString *> *solvedGrp = [NSMutableArray array];
    for (NSInteger j=0; j<valid; j++) {
        BFMechConstants *m = [BFMechConstants withKPlant:bestK tauM:0.010 dScale:0.0007];
        BFFilterConfig *f = [BFFilterConfig gyroPT1Chain:gH1v[j].doubleValue
                                                      h2:gH2v[j].doubleValue
                                                     dyn:0];
        PIDValues *guess = [PIDValues new];
        double P=Pv[j].doubleValue, D=Dv[j].doubleValue;
        guess.p=P*1.3; guess.i=Iv[j].doubleValue; guess.d=D*0.7; guess.ff=Fv[j].doubleValue;
        NSInteger N = Nv[j].integerValue;
        PIDReverseSolver *solver = [PIDReverseSolver new];
        PIDReverseSolveResult *r = [solver solveFromTargetCurve:targets[j] initialGuess:guess
                                                    mechConstants:m filterConfig:f
                                                         fitMask:PIDReverseFitP|PIDReverseFitD
                                                              length:N duration:0.5];
        if (!r) { [solve appendFormat:@"  %@[%@]: ❌ 反解nil\n", names[j], grps[j]]; continue; }
        double pErr = [self pctErr:r.solvedPID.p vs:P];
        double dErr = [self pctErr:r.solvedPID.d vs:D];
        pErrSum += pErr; pCnt++;
        [solvedP addObject:@(r.solvedPID.p)]; [solvedGrp addObject:grps[j]];
        [solve appendFormat:@"  %@[%@] P真=%.0f 解=%.2f(%.1f%%) D真=%.0f 解=%.2f(%.1f%%) RMSE=%.4f iter=%ld\n",
            names[j], grps[j], P, r.solvedPID.p, pErr, D, r.solvedPID.d, dErr,
            r.finalRMSE, (long)r.iterations];
    }

    // C组重复性: 3条P解的极差/均值 (2d基线 C组 27/23/20, 极差大→反解对曲线细节过敏)
    double cMin=1e9, cMax=0, cSum=0; NSInteger cCnt=0;
    for (NSInteger j=0; j<solvedP.count; j++) {
        if ([solvedGrp[j] isEqualToString:@"C"]) {
            double p = solvedP[j].doubleValue;
            cMin = MIN(cMin, p); cMax = MAX(cMax, p); cSum += p; cCnt++;
        }
    }
    double cSpread = (cCnt>=2 && cSum>0) ? (cMax-cMin)/(cSum/cCnt)*100.0 : -1.0;
    double avgPErr = pCnt>0 ? pErrSum/(double)pCnt : 0.0;

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2e 吴bbl 6条+gyro链] 解析forward, BF4.5 gyro PT1链(h1=lpf1等效,h2=lpf2)\n"
        @"%@\n"
        @"K扫描 (解析forward+gyro链, %ld条平均RMSE):\n%@\n"
        @"最优K=%.1f (avgRMSE=%.4f) | 2d基线 K=110(时域,avg=0.0661)\n"
        @"%@\n"
        @"平均P误差=%.1f%% (2d基线=24.8%%)\n"
        @"C组重复性: P解极差/均值=%.1f%% (2d基线≈36%%, n=%ld)\n"
        @"判定: %@",
        extract, (long)valid, sweep, bestK, bestAvgRMSE, solve,
        avgPErr, cSpread, (long)cCnt,
        (avgPErr<15.0 && cSpread>=0 && cSpread<15.0)
            ? @"✅ P<15%且C组重复性<15% → gyro链治本, 可定稿"
            : (avgPErr<15.0
                ? @"🔶 P达标但C组重复性仍差 → 反解对曲线细节过敏, 需正则化"
                : @"⚠️ P仍>15% → 解析+gyro链不够, 需时域forward+dterm(改引擎)")];
    [report writeToFile:@"/tmp/realsolve_wu6_gyro.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(bestK, 0);
}

/// 🎯 阶段3.3b-2g: 时域forward接入反解LM (forward物理最全: d_min动态D + dterm PT1链 + gyro链)
///
/// 2e实锤: 解析forward + gyro链 → P平均83.2% (反解P爆炸).
/// 2f诊断: P-only仍36.3% → forward对P系统偏差, 非共线, Tikhonov治不了.
/// 根因: 解析forward是纯二阶(ζ由dScale常数定), 真实BF有d_min动态D+dterm双低通
///        → D阻尼被低估 → forward过振荡(t=0.005超调34% vs avgCurve 8-15%)
///        → LM为贴平avgCurve只能压P → P偏低/爆炸.
/// 本测试: 反解LM改用时域forward (RK4积分, 含d_min非线性 + dterm PT1链), 看P能否达标.
/// 模型一致性: K扫描与反解都用时域forward + gyro链 + dterm链 + d_min.
/// 时域RK4是O(N), 6条反解可在秒级完成.
- (void)testCrossValidation_WuBBL_TimeDomainReverse {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    // 1. 提取6条曲线 + PID + gyro等效截止 + d_min/dGain (合并2d的d_min提取与2e的gyro提取)
    NSMutableArray<NSString *> *names=[NSMutableArray array], *grps=[NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *targets=[NSMutableArray array];
    NSMutableArray<NSNumber *> *Pv=[NSMutableArray array], *Iv=[NSMutableArray array],
        *Dv=[NSMutableArray array], *Fv=[NSMutableArray array],
        *Nv=[NSMutableArray array], *gH1v=[NSMutableArray array], *gH2v=[NSMutableArray array],
        *dMv=[NSMutableArray array], *dGv=[NSMutableArray array];
    NSMutableString *extract = [NSMutableString stringWithString:@"曲线提取 + gyro链 + d_min:\n"];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *name = spec[@"name"];
        NSString *bbl = [bundle pathForResource:name ofType:@"bbl"];
        if (!bbl) { [extract appendFormat:@"  %@: ❌ bundle无BBL\n", name]; continue; }
        double sr=0;
        NSArray<NSNumber *> *t = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!t || t.count < 100) { [extract appendFormat:@"  %@: ❌ 曲线失败\n", name]; continue; }
        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
        NSDictionary<NSString *, NSString *> *header = [BBLHeaderParser parseHeaderFromFile:bbl];
        // BF4.5 gyro等效截止: lpf1(static>0?static:dyn中点) + lpf2
        double lpf1Static = [[header objectForKey:@"gyro_lpf1_static_hz"] doubleValue];
        NSString *dynHzStr = [header objectForKey:@"gyro_lpf1_dyn_hz"];
        if (dynHzStr.length == 0) dynHzStr = @"0,500";  // BF4.5 缺字段兜底
        NSArray<NSString *> *dp = [dynHzStr componentsSeparatedByString:@","];
        double dynLo = dp.count>0 ? [dp[0] doubleValue] : 0;
        double dynHi = dp.count>1 ? [dp[1] doubleValue] : 500;
        double gH1 = (lpf1Static > 0) ? lpf1Static : (dynLo + dynHi) / 2.0;
        double gH2 = [[header objectForKey:@"gyro_lpf2_static_hz"] doubleValue];
        // d_min/d_max_gain (roll = 第0个)
        NSArray<NSString *> *dm = [[header objectForKey:@"d_min"] componentsSeparatedByString:@","];
        double dMin = dm.count>0 ? [dm[0] doubleValue] : 0.0;
        double dGain = [[header objectForKey:@"d_max_gain"] doubleValue];

        [names addObject:name]; [grps addObject:spec[@"grp"]]; [targets addObject:t];
        [Pv addObject:@(P)]; [Iv addObject:@(I)]; [Dv addObject:@(D)]; [Fv addObject:@(FF)];
        [Nv addObject:@((NSInteger)t.count)];
        [gH1v addObject:@(gH1)]; [gH2v addObject:@(gH2)];
        [dMv addObject:@(dMin)]; [dGv addObject:@(dGain)];
        [extract appendFormat:@"  %@[%@] P=%.0f D=%.0f FF=%.0f N=%lu gyro(%.0f,%.0f) dMin=%.0f dGain=%.0f\n",
            name, spec[@"grp"], P, D, FF, (unsigned long)t.count, gH1, gH2, dMin, dGain];
    }
    NSInteger valid = (NSInteger)names.count;
    XCTAssertGreaterThanOrEqual(valid, 4, @"至少4条曲线提取成功");

    // 🔑 构造同时含gyro链+dterm链的filter (时域forward读gyroPT1Hz+dtermPT1Hz两组字段)
    // dterm链用001.bbl标定值150/150/120 (吴bbl BF4.5 dterm配置相近, 先跑通定方向)
    NSMutableArray<BFFilterConfig *> *filters = [NSMutableArray array];
    for (NSInteger j=0; j<valid; j++) {
        BFFilterConfig *f = [[BFFilterConfig alloc] init];
        f.gyroPT1Hz = gH1v[j].doubleValue;    // gyro lpf1 等效
        f.gyroPT1_2Hz = gH2v[j].doubleValue;  // gyro lpf2
        f.gyroPT1DynHz = 0;                     // BF4.5 只2级, 第三级跳过
        f.dtermPT1Hz = 150.0;                   // dterm_lowpass (001标定)
        f.dtermPT1_2Hz = 150.0;                 // dterm_lowpass2
        f.dtermPT1DynHz = 120.0;                // dterm_lowpass_dyn 中点
        [filters addObject:f];
    }

    // 2. 扫K (时域forward + gyro链 + dterm链 + d_min, 与反解一致)
    double kPlants[] = {50, 70, 90, 110, 130, 150};
    int nK = (int)(sizeof(kPlants)/sizeof(kPlants[0]));
    double bestK = 110, bestAvgRMSE = 1e9;
    NSMutableString *sweep = [NSMutableString string];
    for (int ik=0; ik<nK; ik++) {
        double sumRMSE = 0;
        for (NSInteger j=0; j<valid; j++) {
            BFMechConstants *m = [BFMechConstants withKPlant:kPlants[ik] tauM:0.010
                                                       dScale:0.0007
                                                          dMin:dMv[j].doubleValue dMinGain:dGv[j].doubleValue];
            PIDValues *pid = [PIDValues new];
            pid.p=Pv[j].doubleValue; pid.i=Iv[j].doubleValue;
            pid.d=Dv[j].doubleValue; pid.ff=Fv[j].doubleValue;
            NSInteger N = Nv[j].integerValue;
            NSArray<NSNumber *> *curve = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                mechConstants:m filterConfig:filters[j] length:N duration:0.5];
            sumRMSE += [self rmseBetween:targets[j] and:curve];
        }
        double avg = sumRMSE / (double)valid;
        [sweep appendFormat:@"  K=%-5.1f → %ld条平均RMSE=%.4f\n", kPlants[ik], (long)valid, avg];
        if (avg < bestAvgRMSE) { bestAvgRMSE = avg; bestK = kPlants[ik]; }
    }

    // 3. 反解6条 (时域forward td=YES + gyro链 + dterm链 + d_min)
    NSMutableString *solve = [NSMutableString stringWithString:
        @"反解(fit P/D, 时域forward + gyro链 + dterm链 + d_min):\n"];
    double pErrSum=0; NSInteger pCnt=0;
    NSMutableArray<NSNumber *> *solvedP = [NSMutableArray array];
    NSMutableArray<NSString *> *solvedGrp = [NSMutableArray array];
    for (NSInteger j=0; j<valid; j++) {
        BFMechConstants *m = [BFMechConstants withKPlant:bestK tauM:0.010
                                                   dScale:0.0007
                                                      dMin:dMv[j].doubleValue dMinGain:dGv[j].doubleValue];
        PIDValues *guess = [PIDValues new];
        double P=Pv[j].doubleValue, D=Dv[j].doubleValue;
        guess.p=P*1.3; guess.i=Iv[j].doubleValue; guess.d=D*0.7; guess.ff=Fv[j].doubleValue;
        NSInteger N = Nv[j].integerValue;
        PIDReverseSolver *solver = [PIDReverseSolver new];
        PIDReverseSolveResult *r = [solver solveFromTargetCurve:targets[j] initialGuess:guess
                                                    mechConstants:m filterConfig:filters[j]
                                                         fitMask:PIDReverseFitP|PIDReverseFitD
                                                     useTimeDomain:YES
                                                          length:N duration:0.5];
        if (!r) { [solve appendFormat:@"  %@[%@]: ❌ 反解nil\n", names[j], grps[j]]; continue; }
        double pErr = [self pctErr:r.solvedPID.p vs:P];
        double dErr = [self pctErr:r.solvedPID.d vs:D];
        pErrSum += pErr; pCnt++;
        [solvedP addObject:@(r.solvedPID.p)]; [solvedGrp addObject:grps[j]];
        [solve appendFormat:@"  %@[%@] P真=%.0f 解=%.2f(%.1f%%) D真=%.0f 解=%.2f(%.1f%%) RMSE=%.4f iter=%ld\n",
            names[j], grps[j], P, r.solvedPID.p, pErr, D, r.solvedPID.d, dErr,
            r.finalRMSE, (long)r.iterations];
    }

    // C组重复性: 3条P解极差/均值
    double cMin=1e9, cMax=0, cSum=0; NSInteger cCnt=0;
    for (NSInteger j=0; j<solvedP.count; j++) {
        if ([solvedGrp[j] isEqualToString:@"C"]) {
            double p = solvedP[j].doubleValue;
            cMin = MIN(cMin, p); cMax = MAX(cMax, p); cSum += p; cCnt++;
        }
    }
    double cSpread = (cCnt>=2 && cSum>0) ? (cMax-cMin)/(cSum/cCnt)*100.0 : -1.0;
    double avgPErr = pCnt>0 ? pErrSum/(double)pCnt : 0.0;

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2g 吴bbl 6条] 时域forward反解 (d_min动态D + dterm PT1链 + gyro链)\n"
        @"%@\n"
        @"K扫描 (时域forward+全滤波, %ld条平均RMSE):\n%@\n"
        @"最优K=%.1f (avgRMSE=%.4f) | 2e基线 K=110(解析+gyro, avg=0.0643)\n"
        @"%@\n"
        @"平均P误差=%.1f%% (2e基线=83.2%%, 2d基线=24.8%%)\n"
        @"C组重复性: P解极差/均值=%.1f%% (n=%ld)\n"
        @"判定: %@",
        extract, (long)valid, sweep, bestK, bestAvgRMSE, solve,
        avgPErr, cSpread, (long)cCnt,
        (avgPErr<15.0 && cSpread>=0 && cSpread<15.0)
            ? @"✅ P<15%且C组重复性<15% → 时域forward治本, 可定稿反解"
            : (avgPErr<15.0
                ? @"🔶 P达标但C组重复性仍差 → 需正则化或曲线质量门控"
                : @"⚠️ P仍>15% → 时域forward也不够, forward模型层穷尽, 转质量门控")];
    [report writeToFile:@"/tmp/realsolve_wu6_td.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(bestK, 0);
}

/// [3.3b-2h] 吴bbl 6条反解公共输入 (曲线提取 + gyro+dterm filter + d_min + K扫描)
/// 2g 内联版, 此处抽出供 2h-a/2i 复用, 避免每个验证测试重抄提取逻辑. K扫描用真值时域forward.
- (nullable Wu6ReverseBundle *)extractWu6Bundle {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    NSMutableArray<NSString *> *names=[NSMutableArray array], *grps=[NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *targets=[NSMutableArray array];
    NSMutableArray<NSNumber *> *Pv=[NSMutableArray array], *Iv=[NSMutableArray array],
        *Dv=[NSMutableArray array], *Fv=[NSMutableArray array],
        *Nv=[NSMutableArray array], *dMv=[NSMutableArray array], *dGv=[NSMutableArray array];
    NSMutableArray<BFFilterConfig *> *filters=[NSMutableArray array];
    NSMutableString *extract = [NSMutableString stringWithString:@"曲线提取 + gyro链 + d_min:\n"];

    /// 提取6条: 曲线 + PID + gyro等效截止 + d_min/dGain, 同循环组装filter
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *name = spec[@"name"];
        NSString *bbl = [bundle pathForResource:name ofType:@"bbl"];
        if (!bbl) { [extract appendFormat:@"  %@: ❌ bundle无BBL\n", name]; continue; }
        double sr=0;
        NSArray<NSNumber *> *t = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!t || t.count < 100) { [extract appendFormat:@"  %@: ❌ 曲线失败\n", name]; continue; }
        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
        NSDictionary<NSString *, NSString *> *header = [BBLHeaderParser parseHeaderFromFile:bbl];
        // BF4.5 gyro等效截止: lpf1(static>0?static:dyn中点) + lpf2
        double lpf1Static = [[header objectForKey:@"gyro_lpf1_static_hz"] doubleValue];
        NSString *dynHzStr = [header objectForKey:@"gyro_lpf1_dyn_hz"];
        if (dynHzStr.length == 0) dynHzStr = @"0,500";  // BF4.5 缺字段兜底
        NSArray<NSString *> *dp = [dynHzStr componentsSeparatedByString:@","];
        double dynLo = dp.count>0 ? [dp[0] doubleValue] : 0;
        double dynHi = dp.count>1 ? [dp[1] doubleValue] : 500;
        double gH1 = (lpf1Static > 0) ? lpf1Static : (dynLo + dynHi) / 2.0;
        double gH2 = [[header objectForKey:@"gyro_lpf2_static_hz"] doubleValue];
        // d_min/d_max_gain (roll = 第0个)
        NSArray<NSString *> *dm = [[header objectForKey:@"d_min"] componentsSeparatedByString:@","];
        double dMin = dm.count>0 ? [dm[0] doubleValue] : 0.0;
        double dGain = [[header objectForKey:@"d_max_gain"] doubleValue];

        /// 同循环组装filter (gyro链 + dterm链, 后者用001标定150/150/120)
        BFFilterConfig *f = [[BFFilterConfig alloc] init];
        f.gyroPT1Hz = gH1;          // gyro lpf1 等效
        f.gyroPT1_2Hz = gH2;        // gyro lpf2
        f.gyroPT1DynHz = 0;         // BF4.5 只2级, 第三级跳过
        f.dtermPT1Hz = 150.0;       // dterm_lowpass (001标定)
        f.dtermPT1_2Hz = 150.0;     // dterm_lowpass2
        f.dtermPT1DynHz = 120.0;    // dterm_lowpass_dyn 中点

        [names addObject:name]; [grps addObject:spec[@"grp"]]; [targets addObject:t];
        [Pv addObject:@(P)]; [Iv addObject:@(I)]; [Dv addObject:@(D)]; [Fv addObject:@(FF)];
        [Nv addObject:@((NSInteger)t.count)];
        [dMv addObject:@(dMin)]; [dGv addObject:@(dGain)]; [filters addObject:f];
        [extract appendFormat:@"  %@[%@] P=%.0f D=%.0f FF=%.0f N=%lu gyro(%.0f,%.0f) dMin=%.0f dGain=%.0f\n",
            name, spec[@"grp"], P, D, FF, (unsigned long)t.count, gH1, gH2, dMin, dGain];
    }
    NSInteger valid = (NSInteger)names.count;
    if (valid < 4) return nil;  // 🔑 提取不足4条视为失败

    /// K扫描 (真值时域forward + 全滤波, 与反解一致)
    double kPlants[] = {50, 70, 90, 110, 130, 150};
    int nK = (int)(sizeof(kPlants)/sizeof(kPlants[0]));
    double bestK = 110, bestAvgRMSE = 1e9;
    NSMutableString *sweep = [NSMutableString string];
    for (int ik=0; ik<nK; ik++) {
        double sumRMSE = 0;
        for (NSInteger j=0; j<valid; j++) {
            BFMechConstants *m = [BFMechConstants withKPlant:kPlants[ik] tauM:0.010
                                                       dScale:0.0007
                                                          dMin:dMv[j].doubleValue dMinGain:dGv[j].doubleValue];
            PIDValues *pid = [PIDValues new];
            pid.p=Pv[j].doubleValue; pid.i=Iv[j].doubleValue;
            pid.d=Dv[j].doubleValue; pid.ff=Fv[j].doubleValue;
            NSInteger N = Nv[j].integerValue;
            NSArray<NSNumber *> *curve = [PIDReverseSolver forwardCurveTimeDomainWithPID:pid
                mechConstants:m filterConfig:filters[j] length:N duration:0.5];
            sumRMSE += [self rmseBetween:targets[j] and:curve];
        }
        double avg = sumRMSE / (double)valid;
        [sweep appendFormat:@"  K=%-5.1f → %ld条平均RMSE=%.4f\n", kPlants[ik], (long)valid, avg];
        if (avg < bestAvgRMSE) { bestAvgRMSE = avg; bestK = kPlants[ik]; }
    }

    Wu6ReverseBundle *b = [Wu6ReverseBundle new];
    b.names=[names copy]; b.grps=[grps copy]; b.targets=[targets copy];
    b.Pv=[Pv copy]; b.Iv=[Iv copy]; b.Dv=[Dv copy]; b.Fv=[Fv copy]; b.Nv=[Nv copy];
    b.dMv=[dMv copy]; b.dGv=[dGv copy]; b.filters=[filters copy];
    b.bestK=bestK; b.extractLog=[extract copy]; b.sweepLog=[sweep copy];
    return b;
}

/// 🎯 阶段3.3b-2h-a: P-only反解验证 (D/FF/I 固定 header 真值)
///
/// 2g突破: 时域forward + fit P/D → P达标8.9%, 但D解爆炸(147-187%, D欠定).
/// 本测试: fitMask=P-only, D/FF/I固定为BBL header真值 (消除D欠定干扰),
///         验证P精度是否进一步提升 + 收敛更稳.
/// 假设: P主导ωn, D经dterm滤波+d_min钝化后对曲线影响小; 固定D=真值给LM
///       一个无欠定的1维搜索空间, P应更准.
/// 期望: P误差 < 2g的8.9%, C组重复性更优.
/// 判定: P<8%且C组极差<10% → P-only是D治理正解, 进集成(2h-b).
- (void)testCrossValidation_WuBBL_TimeDomainReverse_POnly {
    Wu6ReverseBundle *b = [self extractWu6Bundle];
    XCTAssertNotNil(b, @"提取6条曲线失败");
    NSInteger valid = (NSInteger)b.names.count;

    NSMutableString *solve = [NSMutableString stringWithString:
        @"反解(fit P-only, D/FF/I固定header真值, 时域forward+gyro+dterm+d_min):\n"];
    double pErrSum=0; NSInteger pCnt=0;
    NSMutableArray<NSNumber *> *solvedP = [NSMutableArray array];
    NSMutableArray<NSString *> *solvedGrp = [NSMutableArray array];
    for (NSInteger j=0; j<valid; j++) {
        BFMechConstants *m = [BFMechConstants withKPlant:b.bestK tauM:0.010
                                                   dScale:0.0007
                                                      dMin:b.dMv[j].doubleValue dMinGain:b.dGv[j].doubleValue];
        /// P-only: D/FF/I固定header真值, P给扰动初值(×1.3)让LM工作
        PIDValues *guess = [PIDValues new];
        double P=b.Pv[j].doubleValue;
        guess.p = P * 1.3;
        guess.i = b.Iv[j].doubleValue;
        guess.d = b.Dv[j].doubleValue;    // 真值固定, 不拟合
        guess.ff = b.Fv[j].doubleValue;   // 真值固定, 不拟合
        NSInteger N = b.Nv[j].integerValue;
        PIDReverseSolver *solver = [PIDReverseSolver new];
        PIDReverseSolveResult *r = [solver solveFromTargetCurve:b.targets[j] initialGuess:guess
                                                    mechConstants:m filterConfig:b.filters[j]
                                                         fitMask:PIDReverseFitP
                                                     useTimeDomain:YES
                                                          length:N duration:0.5];
        if (!r) { [solve appendFormat:@"  %@[%@]: ❌ 反解nil\n", b.names[j], b.grps[j]]; continue; }
        double pErr = [self pctErr:r.solvedPID.p vs:P];
        pErrSum += pErr; pCnt++;
        [solvedP addObject:@(r.solvedPID.p)]; [solvedGrp addObject:b.grps[j]];
        [solve appendFormat:@"  %@[%@] P真=%.0f 解=%.2f(%.1f%%) RMSE=%.4f iter=%ld\n",
            b.names[j], b.grps[j], P, r.solvedPID.p, pErr,
            r.finalRMSE, (long)r.iterations];
    }

    /// C组重复性: 3条P解极差/均值
    double cMin=1e9, cMax=0, cSum=0; NSInteger cCnt=0;
    for (NSInteger j=0; j<solvedP.count; j++) {
        if ([solvedGrp[j] isEqualToString:@"C"]) {
            double p = solvedP[j].doubleValue;
            cMin = MIN(cMin, p); cMax = MAX(cMax, p); cSum += p; cCnt++;
        }
    }
    double cSpread = (cCnt>=2 && cSum>0) ? (cMax-cMin)/(cSum/cCnt)*100.0 : -1.0;
    double avgPErr = pCnt>0 ? pErrSum/(double)pCnt : 0.0;

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2h-a 吴bbl 6条] P-only反解 (D/FF/I固定header真值)\n"
        @"%@\n"
        @"K扫描 (时域forward+全滤波, %ld条平均RMSE):\n%@\n"
        @"最优K=%.1f (同2g)\n"
        @"%@\n"
        @"平均P误差=%.1f%% (2g基线=8.9%%, 2e基线=83.2%%)\n"
        @"C组重复性: P解极差/均值=%.1f%% (n=%ld)\n"
        @"判定: %@",
        b.extractLog, (long)valid, b.sweepLog, b.bestK, solve,
        avgPErr, cSpread, (long)cCnt,
        (avgPErr<8.0 && cSpread>=0 && cSpread<10.0)
            ? @"✅ P<8%且C组重复性<10% → P-only消除D欠定, D治理正解, 进集成2h-b"
            : (avgPErr<8.0
                ? @"🔶 P达标但C组重复性仍差 → 需曲线质量门控"
                : @"⚠️ P-only反不如2g PD联立 → D虽欠定但有信息, 重新评估")];
    [report writeToFile:@"/tmp/realsolve_wu6_td_ponly.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(b.bestK, 0);
}

/// 🔬 阶段3.3b-2f-诊断: 单参拟合灵敏度 (零引擎改动, 确认Tikhonov是否对症)
///
/// 2e实锤: fit P/D 时 P 爆炸(83.2%), 猜根因是P/D/FF雅可比共线(欠定).
/// 本测试: 逐参 fit (P only / D only), D/FF 固定真值, 看 P 能否准确.
///   P only P准确(<15%) → 共线是根因, Tikhonov对症(进2f-正则化)
///   P only P仍偏(>15%) → forward对P系统偏差, Tikhonov治不了, 需改模型
/// 解析forward无gyro链(与2d基线一致), K=110(2d最优)
- (void)testCrossValidation_WuBBL_PerParamSensitivity {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    // 提取 6 条曲线 + PID (解析forward不读d_min, 故不提)
    NSMutableArray<NSString *> *names=[NSMutableArray array], *grps=[NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *targets=[NSMutableArray array];
    NSMutableArray<NSNumber *> *Pv=[NSMutableArray array], *Iv=[NSMutableArray array],
        *Dv=[NSMutableArray array], *Fv=[NSMutableArray array], *Nv=[NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *bbl = [bundle pathForResource:spec[@"name"] ofType:@"bbl"];
        if (!bbl) continue;
        double sr=0;
        NSArray<NSNumber *> *t = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!t || t.count < 100) continue;
        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
        [names addObject:spec[@"name"]]; [grps addObject:spec[@"grp"]]; [targets addObject:t];
        [Pv addObject:@(P)]; [Iv addObject:@(I)]; [Dv addObject:@(D)]; [Fv addObject:@(FF)];
        [Nv addObject:@((NSInteger)t.count)];
    }
    NSInteger valid = (NSInteger)names.count;
    XCTAssertGreaterThanOrEqual(valid, 4, @"至少4条曲线提取成功");

    BFMechConstants *mech = [BFMechConstants withKPlant:110.0 tauM:0.010 dScale:0.0007];
    PIDReverseSolver *solver = [PIDReverseSolver new];
    NSMutableString *solve = [NSMutableString stringWithString:
        @"单参灵敏度 (K=110, 解析forward无gyro链):\n"
        @"  name[grp]      | P-only解(%)  | D-only解(%)  | P+D解(%)对照\n"];

    double pOnlyErrSum=0, dOnlyErrSum=0, pDErrSum=0;
    NSInteger pOnlyCnt=0, dOnlyCnt=0, pDCnt=0;
    for (NSInteger j=0; j<valid; j++) {
        double P=Pv[j].doubleValue, D=Dv[j].doubleValue;
        NSInteger N = Nv[j].integerValue;

        // P only: guess P 扰动+30%, D/FF 固定真值 (排除D/FF共线)
        PIDValues *gP = [PIDValues new];
        gP.p=P*1.3; gP.i=Iv[j].doubleValue; gP.d=D; gP.ff=Fv[j].doubleValue;
        PIDReverseSolveResult *rP = [solver solveFromTargetCurve:targets[j] initialGuess:gP
                                                     mechConstants:mech
                                                          fitMask:PIDReverseFitP
                                                               length:N duration:0.5];
        // D only: P/FF 固定真值, guess D 扰动-30%
        PIDValues *gD = [PIDValues new];
        gD.p=P; gD.i=Iv[j].doubleValue; gD.d=D*0.7; gD.ff=Fv[j].doubleValue;
        PIDReverseSolveResult *rD = [solver solveFromTargetCurve:targets[j] initialGuess:gD
                                                     mechConstants:mech
                                                          fitMask:PIDReverseFitD
                                                               length:N duration:0.5];
        // P+D 对照 (2d基线)
        PIDValues *gPD = [PIDValues new];
        gPD.p=P*1.3; gPD.i=Iv[j].doubleValue; gPD.d=D*0.7; gPD.ff=Fv[j].doubleValue;
        PIDReverseSolveResult *rPD = [solver solveFromTargetCurve:targets[j] initialGuess:gPD
                                                       mechConstants:mech
                                                            fitMask:PIDReverseFitP|PIDReverseFitD
                                                                 length:N duration:0.5];
        double pOP = rP ? [self pctErr:rP.solvedPID.p vs:P] : -1;
        double dOD = rD ? [self pctErr:rD.solvedPID.d vs:D] : -1;
        double pDP = rPD ? [self pctErr:rPD.solvedPID.p vs:P] : -1;
        if (rP) { pOnlyErrSum += pOP; pOnlyCnt++; }
        if (rD) { dOnlyErrSum += dOD; dOnlyCnt++; }
        if (rPD) { pDErrSum += pDP; pDCnt++; }
        [solve appendFormat:@"  %@[%@] P真=%.0f D真=%.0f | P=%6.2f(%5.1f) | D=%6.2f(%5.1f) | P=%6.2f(%5.1f)\n",
            names[j], grps[j], P, D,
            rP.solvedPID.p, pOP, rD.solvedPID.d, dOD, rPD.solvedPID.p, pDP];
    }

    double avgPO = pOnlyCnt>0 ? pOnlyErrSum/(double)pOnlyCnt : 0;
    double avgDO = dOnlyCnt>0 ? dOnlyErrSum/(double)dOnlyCnt : 0;
    double avgPD = pDCnt>0 ? pDErrSum/(double)pDCnt : 0;

    NSString *report = [NSString stringWithFormat:
        @"[3.3b-2f-诊断 单参灵敏度] 吴bbl 6条, K=110, 解析forward(无gyro链)\n"
        @"%@\n"
        @"平均误差: P-only=%.1f%% (n=%ld) | D-only=%.1f%% (n=%ld) | P+D对照=%.1f%% (n=%ld)\n"
        @"判定: %@",
        solve, avgPO, (long)pOnlyCnt, avgDO, (long)dOnlyCnt, avgPD, (long)pDCnt,
        (avgPO < 15.0)
            ? @"✅ P-only准确(<15%) → 共线是根因, Tikhonov对症(进2f-正则化)"
            : @"⚠️ P-only仍偏(>15%) → forward对P系统偏差, Tikhonov治不了, 需改模型"];
    [report writeToFile:@"/tmp/realsolve_wu6_perparam.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(valid, 0);
}

/// 🔬 阶段3.3b-2f-曲线诊断: 同组曲线形状对比 (定位反解不稳是否源于输入曲线)
///
/// 2f-诊断发现: A组515inch(P解3.8%) vs 51log(P解34.4%) 同飞机同PID却差30%
///   → 猜曲线提取(stackResponse提纯)对飞行风格/噪声敏感, 同PID应形状近但实际差异大
/// 本测试: 输出6条归一化曲线的形状采样(上升沿/稳态/超调), 同组对比
///   同组形状近 → 曲线OK, 反解不稳是forward问题
///   同组形状远 → 曲线提取是根因, 先治提纯再谈反解
- (void)testWuBBL_CurveShapeDiagnostic {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSDictionary<NSString *, NSString *> *> *specs = @[
        @{@"name":@"wu_515inch",   @"grp":@"A"},
        @{@"name":@"wu_51log",     @"grp":@"A"},
        @{@"name":@"wu_xxx5101",   @"grp":@"B"},
        @{@"name":@"wu_bde51_2_0", @"grp":@"C"},
        @{@"name":@"wu_bde51_3_0", @"grp":@"C"},
        @{@"name":@"wu_wu3",       @"grp":@"C"},
    ];

    NSMutableString *report = [NSMutableString stringWithString:
        @"[3.3b-2f 曲线形状诊断] 吴bbl 6条归一化avgCurve (稳态=1, 时间轴0~0.5s)\n"
        @"  name[grp]      | t=0.02 0.05 0.10 0.15 0.20 0.30 0.50 | 峰值 超调% 稳态t\n"];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *bbl = [bundle pathForResource:spec[@"name"] ofType:@"bbl"];
        if (!bbl) continue;
        double sr=0;
        NSArray<NSNumber *> *c = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!c || c.count < 100) continue;
        NSInteger N = (NSInteger)c.count;

        // 形状采样 (归一化曲线在 t=k/N*0.5 处的值)
        double ts[] = {0.02, 0.05, 0.10, 0.15, 0.20, 0.30, 0.50};
        int nT = (int)(sizeof(ts)/sizeof(ts[0]));
        NSMutableString *samp = [NSMutableString string];
        for (int k=0; k<nT; k++) {
            NSInteger idx = (NSInteger)(ts[k] / 0.5 * (N-1));
            if (idx >= N) idx = N-1;
            [samp appendFormat:@"%5.2f ", c[idx].doubleValue];
        }
        // 峰值 + 超调% (相对稳态1.0)
        double peak = 0;
        for (NSInteger k=0; k<N; k++) peak = MAX(peak, c[k].doubleValue);
        double overshoot = (peak - 1.0) * 100.0;
        // 稳态时间 (首次达0.9的时刻, 秒)
        double settleT = -1;
        for (NSInteger k=0; k<N; k++) {
            if (c[k].doubleValue >= 0.9) { settleT = (double)k/(N-1)*0.5; break; }
        }

        [report appendFormat:@"  %@[%@] | %@ | %.2f %5.1f %5.3f\n",
            spec[@"name"], spec[@"grp"], samp, peak, overshoot, settleT];
    }
    [report appendString:@"\n判定: 同组(A的两条/C的三条)形状近→曲线OK, 形状远→曲线提取是根因\n"];
    [report writeToFile:@"/tmp/realsolve_wu6_curveshape.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(specs.count, 0);
}

/// 🔬 阶段3.3b-2f-时间尺度诊断: avgCurve(target) vs forward(真PID) 形状叠加
///
/// 曲线诊断发现: avgCurve settleT=2-4ms (典型阶跃应50-200ms), 疑似时间尺度与forward不匹配.
/// 本测试: 取515inch(P解准)和51log(P偏)两条, 同图对比avgCurve与forward(真PID)形状采样.
///   时间尺度匹配 + 形状近 → 瓶颈在forward模型, 继续扩forward
///   时间尺度不匹配 / 形状差远 → 瓶颈在target(avgCurve语义), 扩forward无用, 需查avgCurve定义
- (void)testWuBBL_TargetVsForwardShape {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSString *> *names = @[@"wu_515inch", @"wu_51log"];
    NSMutableString *report = [NSMutableString stringWithString:
        @"[3.3b-2f 时间尺度诊断] avgCurve vs forward(真PID) 形状叠加 (K=110)\n"
        @"  t      | avgCurve采样 | forward采样 | 差值\n"];

    BFMechConstants *mech = [BFMechConstants withKPlant:110.0 tauM:0.010 dScale:0.0007];
    double ts[] = {0, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20, 0.50};
    int nT = (int)(sizeof(ts)/sizeof(ts[0]));

    for (NSString *name in names) {
        NSString *bbl = [bundle pathForResource:name ofType:@"bbl"];
        if (!bbl) continue;
        double sr=0;
        NSArray<NSNumber *> *avg = [self normalizedRollStepCurveFromBBL:bbl outSampleRate:&sr];
        if (!avg || avg.count < 100) continue;
        NSInteger N = (NSInteger)avg.count;

        double P=0,I=0,D=0,FF=0;
        [self readRealRollPIDFromBBL:bbl outP:&P outI:&I outD:&D outFF:&FF];
        PIDValues *pid = [PIDValues new];
        pid.p=P; pid.i=I; pid.d=D; pid.ff=FF;
        NSArray<NSNumber *> *fwd = [PIDReverseSolver forwardCurveWithPID:pid
                                                           mechConstants:mech
                                                                   length:N duration:0.5];
        if (!fwd) continue;

        [report appendFormat:@"\n%@ (P=%.0f D=%.0f FF=%.0f N=%ld):\n", name, P, D, FF, (long)N];
        for (int k=0; k<nT; k++) {
            NSInteger idx = (NSInteger)(ts[k] / 0.5 * (N-1));
            if (idx >= N) idx = N-1;
            double a = avg[idx].doubleValue, f = fwd[idx].doubleValue;
            [report appendFormat:@"  t=%.3fs | avg=%6.3f | fwd=%6.3f | Δ=%+.3f\n", ts[k], a, f, a-f];
        }
        // 时间尺度指标: avgCurve 与 forward 各自达0.5的时刻 (上升沿中点)
        double avgHalfT = -1, fwdHalfT = -1;
        for (NSInteger k=0; k<N; k++) {
            if (avgHalfT<0 && avg[k].doubleValue >= 0.5) avgHalfT = (double)k/(N-1)*0.5;
            if (fwdHalfT<0 && fwd[k].doubleValue >= 0.5) fwdHalfT = (double)k/(N-1)*0.5;
        }
        [report appendFormat:@"  达0.5时刻: avg=%.4fs fwd=%.4fs (比值=%.1fx)\n",
            avgHalfT, fwdHalfT, fwdHalfT>0 && avgHalfT>0 ? fwdHalfT/avgHalfT : -1];
    }
    [report appendString:@"\n判定: fwd/avg达0.5比值≈1→时间尺度匹配; >>1或<<1→不匹配(target语义问题)\n"];
    [report writeToFile:@"/tmp/realsolve_wu6_timescale.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"🎯 %@", report);
    XCTAssertGreaterThan(names.count, 0);
}

@end