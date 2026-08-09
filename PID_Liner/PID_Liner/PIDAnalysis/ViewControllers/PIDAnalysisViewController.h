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

/**
 * 响应图完全摊开所需的总高度(3轴图 + 控件 + tabBar)
 * 容器(如工作台)据此设高度,可让内部 scrollView 不滚动,只剩外层一套 scroll (任务#28 0.4c-1.3)
 */
+ (CGFloat)fullyExpandedRequiredHeight;

/**
 * 容器(工作台)嵌入时调用:绑定为迭代模式,关联指定链
 * 预填该链历史,供 startAnalysis 画历史预测虚线 + toggle
 */
- (void)configureForIterationWithChainId:(NSString *)chainId;

/**
 * 容器嵌入时设 YES:隐藏内置「导入新一轮 BBL」按钮
 * 工作台/独立分析有自己的导入/不入方案流程,避免重复按钮 + 入口隔离
 */
@property (nonatomic, assign) BOOL hidesBuiltinImportButton;

@end

NS_ASSUME_NONNULL_END
