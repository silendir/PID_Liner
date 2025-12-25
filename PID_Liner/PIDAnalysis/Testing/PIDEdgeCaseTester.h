//
//  PIDEdgeCaseTester.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  边界情况测试工具
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PIDCSVParser;
@class PIDTraceAnalyzer;
@class PIDCSVData;

/**
 * 边界测试结果
 */
@interface PIDEdgeCaseResult : NSObject

// 测试名称
@property (nonatomic, copy) NSString *testName;

// 是否通过
@property (nonatomic, assign) BOOL passed;

// 错误信息（失败时）
@property (nonatomic, copy, nullable) NSString *errorMessage;

// 执行时间（秒）
@property (nonatomic, assign) double executionTime;

@end

/**
 * 边界情况测试器
 *
 * 测试各种异常输入情况下的系统稳定性
 */
@interface PIDEdgeCaseTester : NSObject

/**
 * 默认初始化
 */
- (instancetype)init;

#pragma mark - 单元测试

/**
 * 测试空数据处理
 * 验证解析器能正确处理空CSV文件
 */
- (PIDEdgeCaseResult *)testEmptyData;

/**
 * 测试单行数据
 * 验证只有一行数据的情况
 */
- (PIDEdgeCaseResult *)testSingleRowData;

/**
 * 测试超大文件处理
 * 验证流式读取是否能处理大文件
 */
- (PIDEdgeCaseResult *)testLargeFile:(NSInteger)targetRows;

/**
 * 测试缺失字段
 * 验证某些字段缺失时的处理
 */
- (PIDEdgeCaseResult *)testMissingFields;

/**
 * 测试异常值
 * 验证包含NaN/Inf值的处理
 */
- (PIDEdgeCaseResult *)testAbnormalValues;

/**
 * 测试不同采样率
 * 验证不同采样率的数据处理
 */
- (PIDEdgeCaseResult *)testSampleRates;

/**
 * 测试PID极端值
 * 验证P/I/D参数为0或很大时的处理
 */
- (PIDEdgeCaseResult *)testExtremePIDValues;

/**
 * 测试数据长度不一致
 * 验证不同字段数组长度不一致的情况
 */
- (PIDEdgeCaseResult *)testMismatchedArrayLengths;

#pragma mark - 批量测试

/**
 * 运行所有边界测试
 * @return 测试结果数组
 */
- (NSArray<PIDEdgeCaseResult *> *)runAllEdgeCaseTests;

/**
 * 生成测试报告
 * @param results 测试结果数组
 * @return 格式化的报告字符串
 */
- (NSString *)generateReport:(NSArray<PIDEdgeCaseResult *> *)results;

#pragma mark - 测试数据生成

/**
 * 生成测试CSV文件
 * @param rowCount 行数
 * @param includeHeaders 是否包含头部
 * @param filePath 保存路径
 * @return 是否成功
 */
- (BOOL)generateTestCSVWithRows:(NSInteger)rowCount
                  includeHeaders:(BOOL)includeHeaders
                        toPath:(NSString *)filePath;

/**
 * 生成包含异常值的测试CSV
 * @param filePath 保存路径
 * @return 是否成功
 */
- (BOOL)generateAbnormalValueCSV:(NSString *)filePath;

/**
 * 清理所有测试文件
 */
- (void)cleanupTestFiles;

@end

NS_ASSUME_NONNULL_END
