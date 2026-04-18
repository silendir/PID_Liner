//
//  CSVHistoryViewController.h
//  PID_Liner
//
//  CSV转换历史记录页面 - 使用TableView展示
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// CSV记录模型
@interface CSVRecord : NSObject

@property (nonatomic, strong) NSString *fileName;       // CSV文件名（实际文件名）
@property (nonatomic, strong) NSString *filePath;       // CSV完整路径
@property (nonatomic, strong) NSString *sourceBBL;      // 源BBL文件名
@property (nonatomic, assign) NSInteger sessionIndex;   // Session索引
@property (nonatomic, strong) NSDate *createTime;       // 创建时间
@property (nonatomic, assign) NSInteger fileSize;       // 文件大小(字节)
@property (nonatomic, assign) NSInteger lineCount;      // 行数

// 🔥 别名系统属性
@property (nonatomic, copy) NSString *displayName;      // 显示名称（有别名用别名，无别名用原文件名）
@property (nonatomic, assign) BOOL hasCustomName;       // 是否有自定义名称

// 🔥 更新显示名称（从别名管理器加载）
- (void)updateDisplayName;

// 便捷初始化方法
- (instancetype)initWithFileName:(NSString *)fileName
                        filePath:(NSString *)filePath
                       sourceBBL:(NSString *)sourceBBL
                    sessionIndex:(NSInteger)sessionIndex;

// 格式化文件大小
- (NSString *)formattedFileSize;

// 格式化创建时间
- (NSString *)formattedCreateTime;

@end

// CSV历史记录ViewController
@interface CSVHistoryViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<CSVRecord *> *csvRecords;

// 刷新数据
- (void)reloadData;

// 添加新记录
- (void)addRecord:(CSVRecord *)record;

@end

NS_ASSUME_NONNULL_END
