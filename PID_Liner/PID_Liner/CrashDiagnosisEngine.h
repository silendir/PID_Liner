//
//  CrashDiagnosisEngine.h
//  PID_Liner
//
//  炸机诊断引擎 — 本地异常检测 + GLM-4.7-Flash AI 诊断
//  从 BBL/CSV 飞行数据中检测失步、烧电机、缺相等异常
//

#import <Foundation/Foundation.h>

@class PIDCSVData;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 异常指标

/// 单项异常指标
@interface CrashAnomalyIndicator : NSObject

@property (nonatomic, copy) NSString *type;         // 异常类型标识
@property (nonatomic, assign) BOOL detected;          // 是否检测到
@property (nonatomic, copy) NSString *severity;       // "high" / "medium" / "low"
@property (nonatomic, copy) NSString *axis;           // "roll" / "pitch" / "yaw" / nil
@property (nonatomic, copy) NSString *detail;         // 具体数值描述
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *events; // 事件时间点列表

/// 时间线属性（飞行进度百分比 0~1）
@property (nonatomic, assign) double firstOccurrenceRatio;  // 首次出现（0=起飞, 1=结束）
@property (nonatomic, assign) double peakOccurrenceRatio;   // 最严重时刻
@property (nonatomic, assign) double lastOccurrenceRatio;   // 最后出现

/// 因果链属性
@property (nonatomic, assign) BOOL isRootCause;            // 是否为根因（vs 结果）
@property (nonatomic, copy, nullable) NSString *causedBy;   // 被哪个 type 触发

@end

#pragma mark - 诊断结果

/// 完整诊断结果
@interface CrashDiagnosisResult : NSObject

@property (nonatomic, copy) NSString *reportText;                        // AI 诊断报告（中文）
@property (nonatomic, strong) NSArray<CrashAnomalyIndicator *> *localIndicators; // 本地检测指标
@property (nonatomic, assign) BOOL fromCache;                            // 是否来自缓存
@property (nonatomic, strong, nullable) NSError *error;                  // 错误信息

@end

#pragma mark - 诊断引擎

/// 炸机诊断引擎
@interface CrashDiagnosisEngine : NSObject

/// 单例
+ (instancetype)shared;

/// 开始诊断
/// @param csvPath CSV 文件路径
/// @param completion 回调（主线程）
- (void)diagnoseCSVAtPath:(NSString *)csvPath
               completion:(void(^)(CrashDiagnosisResult *result))completion;

/// 使用已解析数据诊断
/// @param csvData 已解析的 CSV 数据
/// @param completion 回调（主线程）
- (void)diagnoseWithData:(PIDCSVData *)csvData
              completion:(void(^)(CrashDiagnosisResult *result))completion;

/// 取消当前诊断请求
- (void)cancelCurrentRequest;

/// Worker 代理地址
@property (nonatomic, copy) NSString *workerURL;

/// 用户自定义上下文（附加到 AI 请求中，可用于输入额外规则或偏好）
/// 持久化到 NSUserDefaults，跨会话保留
@property (nonatomic, copy, nullable) NSString *userContext;

/// 流式输出回调（每收到一段文本就调用，主线程）
@property (nonatomic, copy, nullable) void(^onStreamingText)(NSString *partialText);

@end

NS_ASSUME_NONNULL_END
