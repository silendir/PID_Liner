//
//  BBLImportService.h
//  PID_Liner
//
//  BBL → CSV 统一导入管线 (任务#28 阶段0.4b)
//
//  收口 CSVHistoryViewController.m:224 的 TODO:
//    「抽 BBLImportService 统一 ViewController 与 demo 的 BBL→CSV 管线(消除重复)」
//
//  统一三处重复的解码+元数据注入逻辑:
//    - ViewController.convertBBLToCSV / injectCraftNameToCSV(老 BBL 工具页,含 motorKV)
//    - CSVHistory.loadDemoBBLAndReload / injectDemoMetadataToCSV(demo 精简版,无 motorKV)
//    - 独立分析三态(0.4b 新增导入入口)
//
//  线程安全:实例方法可在后台队列调用;内部每次调用 new 一个 BlackboxDecoder,无共享可变状态。
//  元数据注入顺序:craftName → flightTime → firmware → PID(r/p/y) → motorKV(可选)
//

#import <Foundation/Foundation.h>

@class BBLSessionInfo;

NS_ASSUME_NONNULL_BEGIN

/// 单个 BBL 的转换结果(批量转换时用)
@interface BBLImportCSVResult : NSObject
@property (nonatomic, copy, nullable) NSString *csvPath;              // 成功=CSV 绝对路径;失败=nil
@property (nonatomic, assign) int logIndex;                          // Session 的 logIndex(从 0 开始)
@property (nonatomic, copy, nullable) NSString *sessionDescription;  // "Log 1 of 2, 00:01.449"
@property (nonatomic, copy, nullable) NSString *errorMessage;        // 失败原因(成功=nil)
@property (nonatomic, readonly, getter=isSuccess) BOOL success;
@end


/// BBL → CSV 统一导入服务
@interface BBLImportService : NSObject

+ (instancetype)shared;

/// 列出 BBL 的所有 Session(读 header,轻量;可在主线程调用)
/// @param bblPath  BBL 绝对路径
/// @param error    文件不存在 / 解析失败时填充
/// @return Session 列表;失败返回 nil
- (nullable NSArray<BBLSessionInfo *> *)listSessionsForBBL:(NSString *)bblPath
                                                     error:(NSError **)error;

/// 转换单个 Session 为 CSV(注入元数据 + 可选 motorKV)
/// @param bblPath   BBL 绝对路径
/// @param logIndex  Session 的 logIndex(BBLSessionInfo.logIndex,从 0 开始)
/// @param motorKV   可选电机 KV(注入 "# Motor KV:XXX" 行;nil/空跳过)
/// @param error     失败时填充
/// @return 生成的 CSV 绝对路径;失败返回 nil 并填 error
- (nullable NSString *)convertBBL:(NSString *)bblPath
                         logIndex:(int)logIndex
                          motorKV:(nullable NSString *)motorKV
                            error:(NSError **)error;

/// 批量转换全部 Session(每完成一个回调进度,后台队列调用)
/// @param bblPath   BBL 绝对路径
/// @param motorKV   可选电机 KV
/// @param progress  每完成一个 Session 回调(completed/total);后台队列,UI 需切主线程
/// @param error     整体性错误(如 listSessions 失败)填充;单个 Session 失败仅记录在结果里
/// @return 所有 Session 的转换结果(成功与失败都在内);空 BBL 返回空数组
- (NSArray<BBLImportCSVResult *> *)convertAllSessionsForBBL:(NSString *)bblPath
                                                    motorKV:(nullable NSString *)motorKV
                                                   progress:(nullable void(^)(NSInteger completed, NSInteger total))progress
                                                      error:(NSError **)error;

/// Documents 沙盒目录(转换产物落盘位置;与 ViewController/CSVHistory 一致)
+ (NSString *)documentsDirectory;

@end

NS_ASSUME_NONNULL_END
