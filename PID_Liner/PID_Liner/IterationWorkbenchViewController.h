//
//  IterationWorkbenchViewController.h
//  PID_Liner
//
//  方案迭代工作台 (任务#28 阶段0.4c)
//
//  以迭代链(chainId)为单位的多轮闭环调参工作台。
//  数据源:IterationChainManager(链 CRUD)+ PIDAnalysisViewController(响应图,嵌入子VC)
//
//  业务决策(Q1-Q7 全定稿,见记忆 iteration-build-open-questions):
//    Q1 不判定收敛,无限堆叠   Q2 方案名手动+board占位   Q3 加入方案弹新建/追加
//    Q4 CLI 默认滑块+toggle   Q5 推荐=PIDRecommendationEngine   Q6 质量门只警告
//    Q7 只删最新轮+硬删+确认框
//
//  0.4c-1(本版):链头 + 轮次链 + 响应图嵌入 + 撤销最新轮(Q7) + 导入下一轮占位
//  0.4c-2(待做):推荐区(Q5)+ CLI 区(Q4)+ 导入下一轮 inline loading→Session sheet 三选一 + Q3 桥接
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IterationWorkbenchViewController : UIViewController

/// 用迭代链 ID 初始化
- (instancetype)initWithChainId:(NSString *)chainId;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
