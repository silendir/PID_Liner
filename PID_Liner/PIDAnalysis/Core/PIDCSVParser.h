//
//  PIDCSVParser.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  CSV文件解析器 - 流式读取支持大文件
//

#ifndef PIDCSVParser_h
#define PIDCSVParser_h

#import <Foundation/Foundation.h>

@class PIDCSVData;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 解析配置

/**
 * CSV解析配置
 */
@interface PIDCSVParserConfig : NSObject

// 最大读取行数（0表示不限制）
@property (nonatomic, assign) NSInteger maxRows;

// 是否跳过空值
@property (nonatomic, assign) BOOL skipEmptyValues;

// 缓冲区大小（字节）
@property (nonatomic, assign) NSInteger bufferSize;

@end

#pragma mark - CSV解析器

/**
 * CSV文件解析器
 * 负责解析Blackbox解码生成的CSV文件
 * 特性：
 * - 流式读取，支持大文件（几万行以上）
 * - 按需解析，只提取需要的字段
 * - 错误处理和日志记录
 */
@interface PIDCSVParser : NSObject

// 解析配置
@property (nonatomic, strong) PIDCSVParserConfig *config;

// 最后错误信息
@property (nonatomic, readonly, copy, nullable) NSString *lastErrorMessage;

// 是否使用详细日志
@property (nonatomic, assign) BOOL verboseLogging;

/**
 * 便捷初始化方法
 */
+ (instancetype)parser;

/**
 * 使用指定配置初始化
 */
- (instancetype)initWithConfig:(PIDCSVParserConfig *)config;

/**
 * 解析CSV文件
 * @param filePath CSV文件完整路径
 * @return 解析后的数据对象，失败返回nil
 */
- (nullable PIDCSVData *)parseCSV:(NSString *)filePath;

/**
 * 解析CSV文件（带进度回调）
 * @param filePath CSV文件完整路径
 * @param progressHandler 进度回调 (当前行/总行数)
 * @return 解析后的数据对象，失败返回nil
 */
- (nullable PIDCSVData *)parseCSV:(NSString *)filePath
                  progressHandler:(nullable void(^)(NSInteger currentRow, NSInteger totalRows))progressHandler;

/**
 * 获取CSV文件预估行数（用于进度显示）
 * @param filePath CSV文件路径
 * @return 预估行数（-1表示无法确定）
 */
- (NSInteger)estimateRowCount:(NSString *)filePath;

/**
 * 验证CSV文件格式是否有效
 * @param filePath CSV文件路径
 * @return YES表示格式有效，NO表示无效
 */
- (BOOL)validateCSVFormat:(NSString *)filePath;

#pragma mark - 字段映射

/**
 * Python PID-Analyzer需要的字段列表
 * 对应源码中的wanted数组
 */
+ (NSArray<NSString *> *)requiredFields;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDCSVParser_h */
