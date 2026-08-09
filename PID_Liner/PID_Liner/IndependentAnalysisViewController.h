//
//  IndependentAnalysisViewController.h
//  PID_Liner
//
//  独立分析 · 单屏三态状态机 (任务#28 阶段0.4b)
//
//  三态条件渲染(绝不平铺):
//    ① 空态    导入 BBL + ⏮ 继续上次(会话级缓存,不入迭代链)
//    ② 处理中  BBL→CSV 不可逆中间态(线性进度 + 阶段文案)
//    ③ 结果态  Session chip 横滚 + 嵌入 PIDAnalysisViewController 显示图表
//
//  isIter=NO:不复用迭代链,纯 1对1 看曲线(右路 1.1 前干净版)
//  数据源:BBLImportService(转换)+ PIDAnalysisViewController(分析+图表)
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IndependentAnalysisViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
