//
//  CSVRenameView.h
//  PID_Liner
//
//  CSV 文件重命名弹窗 View
//

#import <UIKit/UIKit.h>

@class CSVRecord;

/**
 * 重命名完成回调
 * @param alias 用户输入的别名（可能为空字符串，表示还原）
 */
typedef void (^CSVRenameCompletion)(NSString *alias);

/**
 * 取消回调
 */
typedef void (^CSVRenameCancelCompletion)(void);

@interface CSVRenameView : UIView

/**
 * 显示重命名弹窗
 * @param record CSV 记录
 * @param completion 完成回调
 * @param cancelCompletion 取消回调
 */
+ (void)showWithRecord:(CSVRecord *)record
             completion:(CSVRenameCompletion)completion
        cancelCompletion:(CSVRenameCancelCompletion)cancelCompletion;

/**
 * 隐藏弹窗
 */
- (void)dismiss;

@end
