//
//  PIDEdgeCaseTester.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  边界情况测试工具实现
//

#import "PIDEdgeCaseTester.h"
#import "PIDCSVParser.h"
#import "PIDTraceAnalyzer.h"
#import "PIDDataModels.h"

@implementation PIDEdgeCaseResult

@end

#pragma mark - PIDEdgeCaseTester Implementation

@interface PIDEdgeCaseTester ()

@property (nonatomic, strong) NSMutableArray<NSString *> *generatedTestFiles;

@end

@implementation PIDEdgeCaseTester

- (instancetype)init {
    self = [super init];
    if (self) {
        _generatedTestFiles = [NSMutableArray array];
    }
    return self;
}

#pragma mark - 单元测试

- (PIDEdgeCaseResult *)testEmptyData {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"空数据测试";

    NSDate *start = [NSDate date];

    @try {
        // 创建空CSV
        NSString *emptyPath = [self testFilePath:@"test_empty.csv"];
        [self writeString:@"" toPath:emptyPath];

        // 尝试解析
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:emptyPath];

        result.passed = (data == nil || data.timeSeconds.count == 0);

        if (!result.passed) {
            result.errorMessage = @"空数据应该返回nil或空数组";
        }

        // 清理
        [[NSFileManager defaultManager] removeItemAtPath:emptyPath error:nil];

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testSingleRowData {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"单行数据测试";

    NSDate *start = [NSDate date];

    @try {
        // 创建单行CSV（只有头部）
        NSString *singlePath = [self testFilePath:@"test_single.csv"];
        NSString *content = @"time (us),rcCommand[0],rcCommand[1],rcCommand[2],rcCommand[3]";
        [self writeString:content toPath:singlePath];

        // 尝试解析
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:singlePath];

        // 单行应该只返回头部信息，没有数据
        result.passed = (data != nil && data.timeSeconds.count == 0);

        if (!result.passed) {
            result.errorMessage = [NSString stringWithFormat:
                @"单行数据应该返回空数据，实际: %ld 行",
                (long)data.timeSeconds.count];
        }

        // 清理
        [[NSFileManager defaultManager] removeItemAtPath:singlePath error:nil];

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testLargeFile:(NSInteger)targetRows {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = [NSString stringWithFormat:@"大文件测试 (%ld行)", (long)targetRows];

    NSDate *start = [NSDate date];

    @try {
        // 生成大CSV文件
        NSString *largePath = [self testFilePath:@"test_large.csv"];
        [self generateTestCSVWithRows:targetRows includeHeaders:YES toPath:largePath];

        // 尝试解析
        PIDCSVParser *parser = [PIDCSVParser parser];
        parser.config.maxRows = 0;  // 不限制

        PIDCSVData *data = [parser parseCSV:largePath];

        result.passed = (data != nil && data.timeSeconds.count > 0);

        if (!result.passed) {
            result.errorMessage = @"大文件解析失败";
        }

        // 清理
        [[NSFileManager defaultManager] removeItemAtPath:largePath error:nil];

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testMissingFields {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"缺失字段测试";

    NSDate *start = [NSDate date];

    @try {
        // 创建缺少某些字段的CSV
        NSString *missingPath = [self testFilePath:@"test_missing.csv"];
        NSMutableString *content = [NSMutableString string];
        [content appendString:@"time (us),rcCommand[0]\n"];  // 缺少其他rcCommand字段
        [content appendString:@"1000,500\n"];
        [content appendString:@"2000,510\n"];
        [self writeString:content toPath:missingPath];

        // 尝试解析
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:missingPath];

        // 缺失字段应该填充为0或默认值
        result.passed = (data != nil);

        if (!result.passed) {
            result.errorMessage = @"缺失字段时解析失败";
        }

        // 清理
        [[NSFileManager defaultManager] removeItemAtPath:missingPath error:nil];

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testAbnormalValues {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"异常值测试 (NaN/Inf)";

    NSDate *start = [NSDate date];

    @try {
        NSString *abnormalPath = [self testFilePath:@"test_abnormal.csv"];
        [self generateAbnormalValueCSV:abnormalPath];

        // 尝试解析
        PIDCSVParser *parser = [PIDCSVParser parser];
        PIDCSVData *data = [parser parseCSV:abnormalPath];

        // 异常值应该被过滤或替换
        result.passed = (data != nil);

        if (!result.passed) {
            result.errorMessage = @"异常值处理失败";
        }

        // 清理
        [[NSFileManager defaultManager] removeItemAtPath:abnormalPath error:nil];

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testSampleRates {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"采样率测试";

    NSDate *start = [NSDate date];

    @try {
        // 测试不同采样间隔
        NSArray<NSNumber *> *testIntervals = @[@125, @250, @500, @1000];  // 微秒

        BOOL allPassed = YES;
        for (NSNumber *interval in testIntervals) {
            NSString *path = [self testFilePath:[NSString stringWithFormat:@"test_sr_%.0f.csv", [interval doubleValue]]];
            [self generateTestCSVWithInterval:[interval integerValue] toPath:path];

            PIDCSVParser *parser = [PIDCSVParser parser];
            PIDCSVData *data = [parser parseCSV:path];

            if (!data || data.timeSeconds.count == 0) {
                allPassed = NO;
                break;
            }

            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        result.passed = allPassed;

        if (!result.passed) {
            result.errorMessage = @"部分采样率解析失败";
        }

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testExtremePIDValues {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"PID极端值测试";

    NSDate *start = [NSDate date];

    @try {
        // 测试PID计算对极端值的处理
        PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];

        // 测试除以0情况
        double result1 = [analyzer pidInWithPVal:100.0 gyro:200.0 pidP:0.0];
        BOOL zeroPidOK = !isnan(result1) && !isinf(result1);

        // 测试极大P值
        double result2 = [analyzer pidInWithPVal:100.0 gyro:200.0 pidP:1e9];
        BOOL largePidOK = !isnan(result2) && !isinf(result2);

        result.passed = zeroPidOK && largePidOK;

        if (!result.passed) {
            result.errorMessage = [NSString stringWithFormat:
                @"极端PID值处理失败: zeroPid=%.2f, largePid=%.2f", result1, result2];
        }

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

- (PIDEdgeCaseResult *)testMismatchedArrayLengths {
    PIDEdgeCaseResult *result = [[PIDEdgeCaseResult alloc] init];
    result.testName = @"数组长度不一致测试";

    NSDate *start = [NSDate date];

    @try {
        // 创建不同长度数组的测试数据
        NSArray<NSNumber *> *pval = @[@1, @2, @3, @4, @5];
        NSArray<NSNumber *> *gyro = @[@100, @200, @300];  // 长度不一致

        PIDTraceAnalyzer *analyzer = [[PIDTraceAnalyzer alloc] init];
        NSArray<NSNumber *> *calcResult = [analyzer pidInWithPValArray:pval
                                                           gyroArray:gyro
                                                                pidP:45.0];

        // 应该返回空数组或截断到较短长度
        result.passed = (calcResult.count == MIN(pval.count, gyro.count));

        if (!result.passed) {
            result.errorMessage = [NSString stringWithFormat:
                @"长度不一致处理错误: pval=%ld, gyro=%ld, calcResult=%ld",
                (long)pval.count, (long)gyro.count, (long)calcResult.count];
        }

    } @catch (NSException *exception) {
        result.passed = NO;
        result.errorMessage = exception.reason;
    }

    result.executionTime = [[NSDate date] timeIntervalSinceDate:start];
    return result;
}

#pragma mark - 批量测试

- (NSArray<PIDEdgeCaseResult *> *)runAllEdgeCaseTests {
    NSMutableArray<PIDEdgeCaseResult *> *results = [NSMutableArray array];

    NSLog(@"🧪 开始边界测试...");

    [results addObject:[self testEmptyData]];
    [results addObject:[self testSingleRowData]];
    [results addObject:[self testLargeFile:10000]];  // 1万行
    [results addObject:[self testMissingFields]];
    [results addObject:[self testAbnormalValues]];
    [results addObject:[self testSampleRates]];
    [results addObject:[self testExtremePIDValues]];
    [results addObject:[self testMismatchedArrayLengths]];

    NSInteger passed = 0;
    for (PIDEdgeCaseResult *r in results) {
        if (r.passed) passed++;
        NSLog(@"  %@: %@ (%.3fs)",
              r.passed ? @"✅" : @"❌", r.testName, r.executionTime);
    }

    NSLog(@"🧪 边界测试完成: %ld/%ld 通过", (long)passed, (long)results.count);

    return [results copy];
}

- (NSString *)generateReport:(NSArray<PIDEdgeCaseResult *> *)results {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"=== 边界测试报告 ===\n\n"];

    NSInteger passed = 0;
    for (PIDEdgeCaseResult *r in results) {
        if (r.passed) passed++;
        [report appendFormat:@"%@ %@\n", r.passed ? @"✅" : @"❌", r.testName];
        if (!r.passed && r.errorMessage) {
            [report appendFormat:@"   错误: %@\n", r.errorMessage];
        }
    }

    [report appendFormat:@"\n通过率: %.1f%% (%ld/%ld)\n",
        100.0 * passed / results.count, (long)passed, (long)results.count];

    return [report copy];
}

#pragma mark - 测试数据生成

- (BOOL)generateTestCSVWithRows:(NSInteger)rowCount
                includeHeaders:(BOOL)includeHeaders
                      toPath:(NSString *)filePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [filePath stringByDeletingLastPathComponent];

    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSMutableString *content = [NSMutableString string];

    if (includeHeaders) {
        [content appendString:@"time (us),rcCommand[0],rcCommand[1],rcCommand[2],rcCommand[3],"
         "axisP[0],axisP[1],axisP[2],"
         "axisI[0],axisI[1],axisI[2],"
         "axisD[0],axisD[1],axisD[2],"
         "gyroADC[0],gyroADC[1],gyroADC[2],"
         "debug[0],debug[1],debug[2],debug[3]\n"];
    }

    // 生成测试数据
    for (NSInteger i = 0; i < rowCount; i++) {
        NSInteger time = 1000 + i * 125;  // 8kHz采样

        [content appendFormat:@"%ld", (long)time];

        // rcCommand (500-1500)
        for (NSInteger j = 0; j < 4; j++) {
            [content appendFormat:@",%d", 500 + (int)(i % 1000)];
        }

        // axisP (30-60)
        for (NSInteger j = 0; j < 3; j++) {
            [content appendFormat:@",%d", 30 + (int)(i % 30)];
        }

        // axisI (30-60)
        for (NSInteger j = 0; j < 3; j++) {
            [content appendFormat:@",%d", 30 + (int)(i % 30)];
        }

        // axisD (10-40)
        for (NSInteger j = 0; j < 3; j++) {
            [content appendFormat:@",%d", 10 + (int)(i % 30)];
        }

        // gyroADC (-500 to 500)
        for (NSInteger j = 0; j < 3; j++) {
            [content appendFormat:@",%d", -250 + (int)(i % 500)];
        }

        // debug (0-100)
        for (NSInteger j = 0; j < 4; j++) {
            [content appendFormat:@",%d", (int)(i % 100)];
        }

        [content appendString:@"\n"];
    }

    return [self writeString:content toPath:filePath];
}

- (BOOL)generateAbnormalValueCSV:(NSString *)filePath {
    NSMutableString *content = [NSMutableString string];

    [content appendString:@"time (us),rcCommand[0],gyroADC[0],axisP[0]\n"];
    [content appendString:@"1000,500,0,45\n"];                     // 正常值
    [content appendString:@"2000,NaN,100,45\n"];                   // NaN
    [content appendString:@"3000,Inf,-200,45\n"];                  // Inf
    [content appendString:@"4000,-Inf,50,45\n"];                  // -Inf
    [content appendString:@"5000,600,1e308,45\n"];                // 接近浮点上限
    [content appendString:@"6000,-600,-1e308,45\n"];              // 接近浮点下限

    return [self writeString:content toPath:filePath];
}

- (void)cleanupTestFiles {
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *path in _generatedTestFiles) {
        [fm removeItemAtPath:path error:nil];
    }

    [_generatedTestFiles removeAllObjects];
}

#pragma mark - Helper Methods

- (BOOL)generateTestCSVWithInterval:(NSInteger)intervalUs
                              toPath:(NSString *)filePath {
    NSMutableString *content = [NSMutableString string];

    [content appendString:@"time (us),rcCommand[0],rcCommand[1],rcCommand[2],rcCommand[3],"
         "gyroADC[0],gyroADC[1],gyroADC[2]\n"];

    for (NSInteger i = 0; i < 100; i++) {
        [content appendFormat:@"%ld,%d,%d,%d,%d,%d,%d,%d\n",
            (long)(1000 + i * intervalUs),
            500 + (int)(i % 1000),
            500 + (int)(i % 1000),
            500 + (int)(i % 1000),
            500 + (int)(i % 1000),
            (int)(i % 100) - 50,
            (int)(i % 100) - 50,
            (int)(i % 100) - 50];
    }

    return [self writeString:content toPath:filePath];
}

- (NSString *)testFilePath:(NSString *)fileName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDir = [paths firstObject];
    NSString *testDir = [cachesDir stringByAppendingPathComponent:@"pid_tests"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:testDir]) {
        [fm createDirectoryAtPath:testDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *path = [testDir stringByAppendingPathComponent:fileName];
    [_generatedTestFiles addObject:path];
    return path;
}

- (BOOL)writeString:(NSString *)string toPath:(NSString *)path {
    NSError *error = nil;
    BOOL success = [string writeToFile:path
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:&error];
    if (!success) {
        NSLog(@"❌ 写入文件失败: %@", error.localizedDescription);
    }
    return success;
}

@end
