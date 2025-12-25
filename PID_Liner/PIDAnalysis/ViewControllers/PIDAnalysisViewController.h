//
//  PIDAnalysisViewController.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID分析主界面 - 集成响应图和噪声图
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PIDCSVData;

/**
 * PID分析主界面
 *
 * 功能：
 * - 解析CSV数据
 * - 执行PID分析
 * - Tab切换显示响应图/噪声图
 */
@interface PIDAnalysisViewController : UIViewController

// CSV文件路径
@property (nonatomic, copy) NSString *csvFilePath;

// CSV数据（可选，如果已解析）
@property (nonatomic, strong, nullable) PIDCSVData *csvData;

/**
 * 使用CSV文件路径初始化
 */
- (instancetype)initWithCSVFilePath:(NSString *)filePath;

/**
 * 使用已解析的CSV数据初始化
 */
- (instancetype)initWithCSVData:(PIDCSVData *)data;

/**
 * 开始分析
 */
- (void)startAnalysis;

@end

NS_ASSUME_NONNULL_END
