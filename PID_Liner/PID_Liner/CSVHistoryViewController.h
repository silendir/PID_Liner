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
@property (nonatomic, assign) BOOL shortClip;           // 短片段(<2秒):分析必失败,列表打标防误点

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

// CSV记录分组(V-B 账本:一组 = 一个 BBL 转换批次,卡头 = 批次名,子行 = 各 Session)
@interface CSVRecordGroup : NSObject

@property (nonatomic, strong) CSVRecord *parentRecord;   // 组内最小 sessionIndex 的记录(卡头展开后即 S1 行)
@property (nonatomic, strong) NSMutableArray<CSVRecord *> *childRecords; // 其余 Session(按 sessionIndex 升序)
@property (nonatomic, assign) BOOL isExpanded;           // 是否展开子行
@property (nonatomic, copy, nullable) NSString *groupKey; // 分组键 = sourceBBL(转换批次身份,重名落盘时已加序号)

@end

// CSV历史记录ViewController
@interface CSVHistoryViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<CSVRecord *> *csvRecords;

// 刷新数据
- (void)reloadData;

// 添加新记录
- (void)addRecord:(CSVRecord *)record;

/// 🔑 纯函数:按 sourceBBL 把记录聚成分组(供单元测试;父 = 最小 sessionIndex,子按序,组按父创建时间倒序)
+ (NSArray<CSVRecordGroup *> *)groupsFromRecords:(NSArray<CSVRecord *> *)records;

/// 从 CSV 文件名前缀恢复 BBL 身份:剥掉尾部的转换时间戳 `_(8位日期)_(6位时间)`
/// (时间戳是逐 Session 解码时刻,同一 BBL 跨秒解码后前缀会裂开,须按 BBL 本名聚合)
+ (NSString *)bblIdentityFromBaseName:(NSString *)baseName;

@end

NS_ASSUME_NONNULL_END
