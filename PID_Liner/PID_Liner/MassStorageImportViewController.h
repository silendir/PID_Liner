//
//  MassStorageImportViewController.h
//  PID_Liner
//
//  蓝牙取数(蓝牙分支):BLE 连飞控 → 激活大容量存储(MSC) → USB 线传文件
//  五态状态机:扫描 → 连接中 → 已连接 → 已激活(插线引导) → 导入结果
//  与现有 isIterationMode/迭代链逻辑零交集(独立入口,只产出 .bbl 导入)。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MassStorageImportViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
