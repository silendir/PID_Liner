//
//  PIDAlgorithmVerifier.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  算法验证工具 - 对比iOS实现与Python参考结果
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PIDCSVData;
@class PIDResponseResult;
@class PIDSpectrumResult;

#pragma mark - 验证结果

/**
 * 算法验证结果
 */
@interface PIDVerificationResult : NSObject

// 验证是否通过
@property (nonatomic, assign) BOOL passed;

// 最大绝对误差
@property (nonatomic, assign) double maxAbsoluteError;

// 平均绝对误差
@property (nonatomic, assign) double meanAbsoluteError;

// 相对误差百分比
@property (nonatomic, assign) double maxRelativeError;

// 绝对误差容限
@property (nonatomic, assign) double absoluteTolerance;

// 错误详情
@property (nonatomic, copy, nullable) NSString *errorDetails;

// 验证的时间戳
@property (nonatomic, strong) NSDate *timestamp;

/**
 * 格式化的结果描述
 */
- (NSString *)formattedDescription;

@end

#pragma mark - 验证报告

/**
 * 验证报告
 */
@interface PIDVerificationReport : NSObject

// 总测试数
@property (nonatomic, assign) NSInteger totalTests;

// 通过的测试数
@property (nonatomic, assign) NSInteger passedTests;

// 失败的测试数
@property (nonatomic, assign) NSInteger failedTests;

// 各项验证结果
@property (nonatomic, strong) NSArray<PIDVerificationResult *> *results;

// 通过率
@property (nonatomic, readonly) double passRate;

/**
 * 生成文本报告
 */
- (NSString *)generateTextReport;

/**
 * 生成Markdown报告
 */
- (NSString *)generateMarkdownReport;

@end

#pragma mark - 性能测试结果

/**
 * 性能测试结果
 */
@interface PIDPerformanceResult : NSObject

// 测试名称
@property (nonatomic, copy) NSString *testName;

// 数据大小
@property (nonatomic, assign) NSInteger dataSize;

// 执行时间（秒）
@property (nonatomic, assign) double executionTime;

// 内存使用（字节）
@property (nonatomic, assign) NSInteger memoryUsage;

// 每秒处理点数
@property (nonatomic, readonly) double pointsPerSecond;

@end

#pragma mark - 算法验证器

/**
 * 算法验证器
 *
 * 用于验证iOS实现的算法精度是否与Python参考结果一致
 */
@interface PIDAlgorithmVerifier : NSObject

// 容差配置
@property (nonatomic, assign) double absoluteTolerance;    // 绝对误差容限 (默认: 1e-6)
@property (nonatomic, assign) double relativeTolerance;    // 相对误差容限 (默认: 1e-4)

/**
 * 默认初始化
 */
- (instancetype)init;

/**
 * 使用指定容差初始化
 */
- (instancetype)initWithAbsoluteTolerance:(double)absTol
                        relativeTolerance:(double)relTol;

#pragma mark - 数组对比验证

/**
 * 验证两个浮点数组的接近程度
 * @param actual 实际值（iOS计算结果）
 * @param expected 期望值（Python参考结果）
 * @return 验证结果
 */
- (PIDVerificationResult *)verifyArray:(NSArray<NSNumber *> *)actual
                            withExpected:(NSArray<NSNumber *> *)expected;

/**
 * 验证二维浮点数组的接近程度
 * @param actual 实际值
 * @param expected 期望值
 * @return 验证结果
 */
- (PIDVerificationResult *)verify2DArray:(NSArray<NSArray<NSNumber *> *> *)actual
                            withExpected:(NSArray<NSArray<NSNumber *> *> *)expected;

#pragma mark - 算法结果验证

/**
 * 验证阶跃响应结果
 * @param actual 实际响应结果
 * @param expectedReferenceData 期望的参考数据（JSON或CSV格式）
 * @return 验证结果
 */
- (PIDVerificationResult *)verifyResponseResult:(PIDResponseResult *)actual
                             referenceData:(NSDictionary *)expectedReferenceData;

/**
 * 验证频谱结果
 * @param actual 实际频谱结果
 * @param expectedReferenceData 期望的参考数据
 * @return 验证结果
 */
- (PIDVerificationResult *)verifySpectrumResult:(PIDSpectrumResult *)actual
                              referenceData:(NSDictionary *)expectedReferenceData;

#pragma mark - 批量验证

/**
 * 运行完整验证套件
 * @param testDataPath 测试数据目录路径
 * @return 验证报告
 */
- (PIDVerificationReport *)runVerificationSuite:(NSString *)testDataPath;

#pragma mark - 性能测试

/**
 * 运行性能测试
 * @param csvFilePath CSV文件路径
 * @return 性能测试结果
 */
- (PIDPerformanceResult *)runPerformanceTest:(NSString *)csvFilePath;

/**
 * 运行多次性能测试并统计
 * @param csvFilePath CSV文件路径
 * @param iterations 测试次数
 * @return 平均性能结果
 */
- (PIDPerformanceResult *)runPerformanceTest:(NSString *)csvFilePath
                                  iterations:(NSInteger)iterations;

@end

NS_ASSUME_NONNULL_END
