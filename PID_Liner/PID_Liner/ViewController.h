//
//  ViewController.h
//  PID_Liner
//
//  Created by 梁隽 on 2025/11/13.
//

#import <UIKit/UIKit.h>

@class BBLSessionInfo;

@interface ViewController : UIViewController <UIDocumentPickerDelegate>

// UI控件
@property (nonatomic, strong) UIButton *convertButton;       // 转换按钮
@property (nonatomic, strong) UIButton *sessionSelectButton; // Session选择按钮（下拉选择）
@property (nonatomic, strong) UIButton *importButton;        // 导入BBL文件按钮
@property (nonatomic, strong) UILabel *statusLabel;          // 状态标签
@property (nonatomic, strong) UITextView *logTextView;       // 日志显示
@property (nonatomic, strong) UIProgressView *progressView;  // 进度条

// 数据
@property (nonatomic, strong) NSString *currentBBLPath;              // 当前BBL文件路径
@property (nonatomic, strong) NSArray<BBLSessionInfo *> *sessions;   // Session列表
@property (nonatomic, assign) NSInteger selectedSessionIndex;        // 选中的Session索引（-1表示全部）
@property (nonatomic, assign) BOOL isUsingImportedFile;              // 是否使用导入的文件

@end
