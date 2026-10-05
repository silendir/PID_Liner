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

/**
 * 分析完成回调(分析管线走完即触发——无论是否存档到链:无 PID 元数据的 CSV
 * 不产生 record,但容器(工作台)仍需刷新 UI/解禁控件,故不挂在存档路径上)
 * block 内自行切主线程。
 */
@property (nonatomic, copy, nullable) void (^onAnalysisComplete)(void);

/**
 * 当前推荐 CLI 文本(随页内滑块/真值 toggle 取对应版本;未生成返回 nil)
 * 供容器(工作台「导出推荐值」弹窗)读取展示/复制
 */
- (nullable NSString *)currentRecommendationCLI;

/**
 * 取消进行中的分析(容器 pop/替换本 VC 时调用):
 * 后台各检查点静默中止,不再回主线程配图/存档/弹窗——避免离场后仍卡主线程
 */
- (void)cancelAnalysis;

#pragma mark 结果缓存与收养(传递曲线model)

/**
 * 🔖 最近一次分析完成的实例按 (路径+大小+修改时间) 全局单槽暂存。
 * 容器(工作台/独立分析)嵌入同一 CSV 时先查此缓存——命中直接收养,
 * 免 40s 重解析+重分析;曲线/特征/推荐/CLI 原样可用(精度滑块照常,显示时抽点)。
 */
+ (nullable instancetype)cachedAnalysisForCSVPath:(NSString *)csvPath;

/**
 * 把本 VC(连同已画好的图表)移入新容器——收养路径用,替代"new VC + startAnalysis"。
 * 已在新容器时为幂等 no-op(重复收养/返回恢复)。
 */
- (void)moveToParent:(UIViewController *)parent containerView:(UIView *)container;

/**
 * 收养为迭代模式(工作台):绑链+入链(指纹幂等,不堆假轮次)+刷新迭代 UI。
 * 历史虚线与已画内容不符时才重画(独立来源建方案=首轮无历史 → 零重画秒开)。
 */
- (void)adoptForChainId:(NSString *)chainId;

/**
 * 收养为独立模式(独立分析页):复位迭代标记;
 * 仅当曾画过迭代历史虚线时才重画为纯独立视图。
 */
- (void)adoptForIndependent;

@end

NS_ASSUME_NONNULL_END
