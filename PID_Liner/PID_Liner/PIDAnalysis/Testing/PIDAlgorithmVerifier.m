//
//  PIDAlgorithmVerifier.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  算法验证工具实现
//

#import "PIDAlgorithmVerifier.h"
#import "PIDCSVParser.h"
#import "PIDTraceAnalyzer.h"
#import "PIDDataModels.h"
#import <mach/mach.h>

#pragma mark - PIDVerificationResult

@implementation PIDVerificationResult

- (NSString *)formattedDescription {
    if (_passed) {
        return [NSString stringWithFormat:@"✅ 通过 | 最大误差: %.2e, 平均误差: %.2e",
                _maxAbsoluteError, _meanAbsoluteError];
    } else {
        return [NSString stringWithFormat:@"❌ 失败 | 最大误差: %.2e (超过容限 %.2e)\n%@",
                _maxAbsoluteError, _absoluteTolerance, _errorDetails];
    }
}

@end

#pragma mark - PIDVerificationReport

@implementation PIDVerificationReport

- (double)passRate {
    if (_totalTests == 0) return 0.0;
    return (double)_passedTests / (double)_totalTests;
}

- (NSString *)generateTextReport {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"=== PID算法验证报告 ===\n\n"];
    [report appendFormat:@"总测试数: %ld\n", (long)_totalTests];
    [report appendFormat:@"通过: %ld\n", (long)_passedTests];
    [report appendFormat:@"失败: %ld\n", (long)_failedTests];
    [report appendFormat:@"通过率: %.1f%%\n\n", self.passRate * 100];

    if (_results.count > 0) {
        [report appendString:@"详细结果:\n"];
        for (NSInteger i = 0; i < _results.count; i++) {
            PIDVerificationResult *result = _results[i];
            [report appendFormat:@"%2ld. %@\n", (long)(i + 1), [result formattedDescription]];
        }
    }

    return [report copy];
}

- (NSString *)generateMarkdownReport {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"# PID算法验证报告\n\n"];
    [report appendFormat:@"- **总测试数**: %ld\n", (long)_totalTests];
    [report appendFormat:@"- **通过**: %ld\n", (long)_passedTests];
    [report appendFormat:@"- **失败**: %ld\n", (long)_failedTests];
    [report appendFormat:@"- **通过率**: %.1f%%\n\n", self.passRate * 100];

    if (_results.count > 0) {
        [report appendString:@"## 详细结果\n\n"];
        [report appendString:@"| # | 状态 | 最大误差 | 平均误差 | 详情 |\n"];
        [report appendString:@"|---|------|----------|----------|------|\n"];

        for (NSInteger i = 0; i < _results.count; i++) {
            PIDVerificationResult *result = _results[i];
            NSString *status = result.passed ? @"✅" : @"❌";
            NSString *details = result.errorDetails ?: @"-";

            [report appendFormat:@"| %ld | %@ | %.2e | %.2e | %@ |\n",
                    (long)(i + 1), status,
                    result.maxAbsoluteError,
                    result.meanAbsoluteError,
                    details];
        }
    }

    return [report copy];
}

@end

#pragma mark - PIDPerformanceResult

@implementation PIDPerformanceResult

- (double)pointsPerSecond {
    if (_executionTime < 1e-9) return 0.0;
    return (double)_dataSize / _executionTime;
}

@end

#pragma mark - PIDAlgorithmVerifier

@interface PIDAlgorithmVerifier ()

@property (nonatomic, strong) NSMutableArray<PIDVerificationResult *> *verificationResults;

@end

@implementation PIDAlgorithmVerifier

- (instancetype)init {
    return [self initWithAbsoluteTolerance:1e-6 relativeTolerance:1e-4];
}

- (instancetype)initWithAbsoluteTolerance:(double)absTol
                        relativeTolerance:(double)relTol {
    self = [super init];
    if (self) {
        _absoluteTolerance = absTol;
        _relativeTolerance = relTol;
        _verificationResults = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 数组对比验证

- (PIDVerificationResult *)verifyArray:(NSArray<NSNumber *> *)actual
                            withExpected:(NSArray<NSNumber *> *)expected {
    PIDVerificationResult *result = [[PIDVerificationResult alloc] init];
    result.timestamp = [NSDate date];

    if (!actual || !expected) {
        result.passed = NO;
        result.errorDetails = @"数据为空";
        return result;
    }

    if (actual.count != expected.count) {
        result.passed = NO;
        result.errorDetails = [NSString stringWithFormat:
            @"数组长度不匹配: 实际=%ld, 期望=%ld",
            (long)actual.count, (long)expected.count];
        return result;
    }

    if (actual.count == 0) {
        result.passed = YES;
        result.maxAbsoluteError = 0.0;
        result.meanAbsoluteError = 0.0;
        return result;
    }

    double maxError = 0.0;
    double maxRelError = 0.0;
    double sumError = 0.0;
    NSInteger mismatchCount = 0;
    NSMutableArray<NSNumber *> *errorLocations = [NSMutableArray array];

    for (NSInteger i = 0; i < actual.count; i++) {
        double a = [actual[i] doubleValue];
        double e = [expected[i] doubleValue];

        double absError = fabs(a - e);
        double relError = (fabs(e) > 1e-9) ? fabs(absError / e) : 0.0;

        if (absError > maxError) maxError = absError;
        if (relError > maxRelError) maxRelError = relError;
        sumError += absError;

        // 检查是否超出容差
        BOOL withinAbsTol = (absError <= _absoluteTolerance);
        BOOL withinRelTol = (relError <= _relativeTolerance);
        BOOL withinTol = (withinAbsTol || withinRelTol);

        if (!withinTol) {
            mismatchCount++;
            if (errorLocations.count < 10) {  // 最多记录10个错误位置
                [errorLocations addObject:@(i)];
            }
        }
    }

    result.maxAbsoluteError = maxError;
    result.meanAbsoluteError = sumError / actual.count;
    result.maxRelativeError = maxRelError;

    // 判断是否通过（错误率低于5%且最大误差在合理范围内）
    double errorRate = (double)mismatchCount / actual.count;
    result.passed = (errorRate < 0.05) && (maxError < _absoluteTolerance * 100);

    if (!result.passed) {
        NSMutableString *details = [NSMutableString string];
        [details appendFormat:@"错误率: %.1f%% (%ld/%ld)",
              errorRate * 100, (long)mismatchCount, (long)actual.count];
        if (errorLocations.count > 0) {
            [details appendString:@"\n错误位置: "];
            [details appendFormat:@"%@", errorLocations];
        }
        result.errorDetails = [details copy];
    }

    [_verificationResults addObject:result];
    return result;
}

- (PIDVerificationResult *)verify2DArray:(NSArray<NSArray<NSNumber *> *> *)actual
                            withExpected:(NSArray<NSArray<NSNumber *> *> *)expected {
    PIDVerificationResult *result = [[PIDVerificationResult alloc] init];
    result.timestamp = [NSDate date];

    if (!actual || !expected) {
        result.passed = NO;
        result.errorDetails = @"数据为空";
        return result;
    }

    if (actual.count != expected.count) {
        result.passed = NO;
        result.errorDetails = [NSString stringWithFormat:
            @"行数不匹配: 实际=%ld, 期望=%ld",
            (long)actual.count, (long)expected.count];
        return result;
    }

    double maxError = 0.0;
    double sumError = 0.0;
    NSInteger totalCount = 0;

    for (NSInteger i = 0; i < actual.count; i++) {
        NSArray<NSNumber *> *actualRow = actual[i];
        NSArray<NSNumber *> *expectedRow = expected[i];

        if (!actualRow || !expectedRow) continue;

        for (NSInteger j = 0; j < actualRow.count && j < expectedRow.count; j++) {
            double a = [actualRow[j] doubleValue];
            double e = [expectedRow[j] doubleValue];

            double error = fabs(a - e);
            if (error > maxError) maxError = error;
            sumError += error;
            totalCount++;
        }
    }

    result.maxAbsoluteError = maxError;
    result.meanAbsoluteError = totalCount > 0 ? sumError / totalCount : 0.0;
    result.maxRelativeError = 0.0;
    result.passed = (maxError < _absoluteTolerance * 10);  // 二维数组允许更大误差

    if (!result.passed) {
        result.errorDetails = [NSString stringWithFormat:
            @"二维数组最大误差: %.2e", maxError];
    }

    [_verificationResults addObject:result];
    return result;
}

#pragma mark - 算法结果验证

- (PIDVerificationResult *)verifyResponseResult:(PIDResponseResult *)actual
                             referenceData:(NSDictionary *)expectedReferenceData {
    PIDVerificationResult *result = [[PIDVerificationResult alloc] init];
    result.timestamp = [NSDate date];

    // 这里需要从参考数据中提取期望值进行对比
    // 实际应用中，参考数据可能来自JSON文件或Python输出

    NSArray<NSNumber *> *expectedStepResponse = expectedReferenceData[@"stepResponse"];

    if (expectedStepResponse && actual.stepResponse.count > 0) {
        // 验证第一个窗口的阶跃响应
        NSArray<NSNumber *> *actualStep = actual.stepResponse[0];
        return [self verifyArray:actualStep withExpected:expectedStepResponse];
    }

    result.passed = NO;
    result.errorDetails = @"缺少参考数据";
    return result;
}

- (PIDVerificationResult *)verifySpectrumResult:(PIDSpectrumResult *)actual
                              referenceData:(NSDictionary *)expectedReferenceData {
    PIDVerificationResult *result = [[PIDVerificationResult alloc] init];
    result.timestamp = [NSDate date];

    // 验证频率数组
    NSArray<NSNumber *> *expectedFreqs = expectedReferenceData[@"frequencies"];
    if (expectedFreqs) {
        PIDVerificationResult *freqResult = [self verifyArray:actual.frequencies
                                                withExpected:expectedFreqs];
        if (!freqResult.passed) {
            return freqResult;
        }
    }

    // 验证频谱数据
    NSArray<NSArray<NSNumber *> *> *expectedSpectrum = expectedReferenceData[@"spectrum"];
    if (expectedSpectrum) {
        return [self verify2DArray:actual.spectrum withExpected:expectedSpectrum];
    }

    result.passed = NO;
    result.errorDetails = @"缺少参考数据";
    return result;
}

#pragma mark - 批量验证

- (PIDVerificationReport *)runVerificationSuite:(NSString *)testDataPath {
    PIDVerificationReport *report = [[PIDVerificationReport alloc] init];
    [_verificationResults removeAllObjects];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;

    if (![fm fileExistsAtPath:testDataPath isDirectory:&isDir] || !isDir) {
        NSLog(@"❌ 测试数据目录不存在: %@", testDataPath);
        return report;
    }

    // 查找所有参考数据文件
    NSArray *files = [fm contentsOfDirectoryAtPath:testDataPath error:nil];
    NSMutableArray<NSString *> *referenceFiles = [NSMutableArray array];

    for (NSString *file in files) {
        if ([file hasSuffix:@"_reference.json"] || [file hasSuffix:@"_reference.csv"]) {
            [referenceFiles addObject:[testDataPath stringByAppendingPathComponent:file]];
        }
    }

    report.totalTests = referenceFiles.count;

    // 运行每个测试
    for (NSString *refFile in referenceFiles) {
        NSLog(@"🧪 运行测试: %@", [refFile lastPathComponent]);

        // 加载参考数据
        NSDictionary *refData = [self loadReferenceData:refFile];

        if (refData) {
            // 运行对应的验证
            NSString *testType = refData[@"testType"];

            if ([testType isEqualToString:@"response"]) {
                // 验证响应分析
                // 这里需要实际的分析数据，暂时跳过
            } else if ([testType isEqualToString:@"spectrum"]) {
                // 验证频谱分析
                // 这里需要实际的分析数据，暂时跳过
            }
        }
    }

    report.results = [_verificationResults copy];
    report.passedTests = 0;
    report.failedTests = 0;

    for (PIDVerificationResult *result in _verificationResults) {
        if (result.passed) {
            report.passedTests++;
        } else {
            report.failedTests++;
        }
    }

    return report;
}

/**
 * 加载参考数据
 */
- (NSDictionary *)loadReferenceData:(NSString *)filePath {
    if ([filePath hasSuffix:@".json"]) {
        NSData *data = [NSData dataWithContentsOfFile:filePath];
        if (data) {
            return [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:nil];
        }
    } else if ([filePath hasSuffix:@".csv"]) {
        // CSV格式的参考数据
        // 这里需要解析CSV，暂时返回空字典
        return @{};
    }

    return nil;
}

#pragma mark - 性能测试

- (PIDPerformanceResult *)runPerformanceTest:(NSString *)csvFilePath {
    PIDPerformanceResult *result = [[PIDPerformanceResult alloc] init];
    result.testName = [csvFilePath lastPathComponent];

    // 获取文件大小
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:csvFilePath error:nil];
    result.dataSize = [attrs[NSFileSize] integerValue];

    // 记录初始内存
    NSInteger initialMemory = [self getCurrentMemoryUsage];

    // 计时开始
    NSDate *startTime = [NSDate date];

    // 执行解析和分析
    @autoreleasepool {
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:csvFilePath];

        if (data && data.timeSeconds.count > 0) {
            // 执行分析
            PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];
            // 这里可以添加更多分析操作
            result.dataSize = data.timeSeconds.count;
        }
    }

    // 计时结束
    result.executionTime = [[NSDate date] timeIntervalSinceDate:startTime];

    // 记录最终内存
    NSInteger finalMemory = [self getCurrentMemoryUsage];
    result.memoryUsage = finalMemory - initialMemory;

    NSLog(@"⏱️ 性能测试: %@ | 数据点: %ld | 耗时: %.3fs | 内存: %ld KB",
          result.testName, (long)result.dataSize,
          result.executionTime, (long)(result.memoryUsage / 1024));

    return result;
}

- (PIDPerformanceResult *)runPerformanceTest:(NSString *)csvFilePath
                                  iterations:(NSInteger)iterations {
    NSMutableArray<PIDPerformanceResult *> *results = [NSMutableArray arrayWithCapacity:iterations];

    for (NSInteger i = 0; i < iterations; i++) {
        PIDPerformanceResult *result = [self runPerformanceTest:csvFilePath];
        [results addObject:result];
    }

    // 计算平均值
    PIDPerformanceResult *avgResult = [[PIDPerformanceResult alloc] init];
    avgResult.testName = [NSString stringWithFormat:@"%@ (平均)", [csvFilePath lastPathComponent]];

    double totalTime = 0;
    for (PIDPerformanceResult *r in results) {
        totalTime += r.executionTime;
    }
    avgResult.executionTime = totalTime / iterations;
    avgResult.dataSize = results.firstObject.dataSize;

    return avgResult;
}

/**
 * 获取当前内存使用量（字节）
 */
- (NSInteger)getCurrentMemoryUsage {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(),
                                   MACH_TASK_BASIC_INFO,
                                   (task_info_t)&info,
                                   &size);
    if (kerr == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

@end
