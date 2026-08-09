//
//  CrashDiagnosisViewController.h
//  PID_Liner
//
//  炸机诊断独立屏 (任务#28 阶段0.4a)
//
//  三态状态机(条件渲染):
//    付费墙(IAP 占位)→ 流式加载(glm-4-flash SSE)→ 报告 + localIndicators 可视化
//
//  数据源:CrashDiagnosisEngine(AI 报告 + 本地异常指标)
//  入口:CSVHistory 选记录 → ActionSheet 🩺 → push 本屏
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CrashDiagnosisViewController : UIViewController

/// 用 CSV 路径初始化
/// @param csvPath 飞行记录 CSV 路径(传给 CrashDiagnosisEngine)
/// @param title   导航栏标题(记录显示名,可空 → 默认「炸机诊断」)
- (instancetype)initWithCSVPath:(NSString *)csvPath title:(nullable NSString *)title;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
