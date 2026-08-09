//
//  HomeViewController.h
//  PID_Liner
//
//  首页 · Y 型三入口 (任务#28 阶段0.3)
//  - 🛩️ 独立分析  (isIter=NO,0.3 指向现有 CSVHistory 选记录分析;0.4 三态状态机)
//  - 🎯 方案迭代  (isIter=YES,0.3 指向现有 CSVHistory 方案列表;0.4 IterationWorkbench)
//  - 🩺 炸机诊断  (PRO,0.3 指向现有 CSVHistory 选记录诊断;0.4 独立屏)
//  「我的方案」= IterationChainManager.allChains;左上 ☰ → CSVHistory(总列表/原始记录仓库)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HomeViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
