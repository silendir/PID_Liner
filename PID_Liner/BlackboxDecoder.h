//
//  BlackboxDecoder.h
//  PID_Liner
//
//  Blackbox flight data decoder for iOS
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 前向声明
@class BBLLogHeader;

typedef NS_ENUM(NSInteger, BBLDecoderError) {
    BBLDecoderErrorNone = 0,
    BBLDecoderErrorFileNotFound,
    BBLDecoderErrorInvalidFormat,
    BBLDecoderErrorDecodingFailed,
    BBLDecoderErrorWriteFailed
};

typedef NS_ENUM(NSInteger, BBLFrameType) {
    BBLFrameTypeI = 'I',  // 完整帧
    BBLFrameTypeP = 'P',  // 部分帧
    BBLFrameTypeG = 'G',  // GPS帧
    BBLFrameTypeS = 'S',  // 慢帧
    BBLFrameTypeH = 'H',  // 头部帧
    BBLFrameTypeE = 'E'   // 事件帧
};

// 帧数据类 - 对应C程序的帧数据结构
// 注意: 数据类型必须与C程序一致
@interface BBLFrameData : NSObject
@property (nonatomic, strong) NSString *frameType;
@property (nonatomic, strong) NSArray<NSNumber *> *values;
@property (nonatomic, assign) int64_t timestampUs;      // 时间戳 (微秒，对应C程序的int64_t)
@property (nonatomic, assign) uint32_t iteration;       // 迭代次数 (对应C程序的uint32_t)
@end

// Session信息类 - 用于存储BBL文件中的飞行段落信息
// 对应C程序中的log信息
@interface BBLSessionInfo : NSObject
@property (nonatomic, assign) int logIndex;                // Log索引 (从0开始，对应C程序的logIndex)
@property (nonatomic, assign) size_t startOffset;          // 在文件中的起始偏移量 (对应C程序的offset)
@property (nonatomic, assign) size_t endOffset;            // 在文件中的结束偏移量
@property (nonatomic, assign) int64_t startTimeUs;         // 开始时间 (微秒，对应C程序的int64_t lastFrameTime)
@property (nonatomic, assign) int64_t endTimeUs;           // 结束时间 (微秒，对应C程序的int64_t)
@property (nonatomic, assign) int64_t durationUs;          // 持续时间 (微秒，对应C程序的int64_t)
@property (nonatomic, assign) int frameCount;              // 帧数量 (对应C程序的int类型)
@property (nonatomic, strong) BBLLogHeader *header;        // Session的头部信息
@property (nonatomic, strong) NSString *sessionDescription; // Session描述 (例如: "Log 1 of 2, 00:01.449")
@end

// Log Header类 - 对应C程序的flightLogHeader结构
// 注意: 数据类型必须与C程序一致
@interface BBLLogHeader : NSObject
@property (nonatomic, strong) NSString *product;
@property (nonatomic, strong) NSString *firmwareType;
@property (nonatomic, strong) NSString *firmwareRevision;
@property (nonatomic, strong) NSString *firmwareDate;
@property (nonatomic, strong) NSString *boardInformation;
@property (nonatomic, strong) NSString *craftName;
@property (nonatomic, assign) int64_t startDatetimeUs;      // 开始时间戳 (微秒，对应C程序的int64_t)
@property (nonatomic, strong) NSString *pIntervalStr;       // P帧间隔字符串 (用于解析)
@property (nonatomic, strong) NSString *pRatioStr;          // P帧比率字符串 (用于解析)
@property (nonatomic, strong) NSDictionary *fieldDefinitions;
@property (nonatomic, strong) NSDictionary *fieldPredictors;
@property (nonatomic, strong) NSDictionary *fieldEncodings;
@property (nonatomic, strong) NSArray<NSString *> *fieldNames;
@property (nonatomic, assign) int iInterval;                // I帧间隔 (对应C程序的int)
@property (nonatomic, assign) int pInterval;                // P帧间隔 (对应C程序的int)
@property (nonatomic, assign) int pRatio;                   // P帧比率 (对应C程序的int)
@property (nonatomic, assign) int looptime;                 // 循环时间 (对应C程序的int)
@property (nonatomic, strong) NSDictionary *configParameters;
@end

// ============================================================================
// BlackboxDecoder - 完全对应C程序blackbox_decode的iOS移植版本
// ============================================================================
//
// 设计原则: 一比一还原C语言程序的行为和数据类型
//
// C程序核心函数:
//   int decodeFlightLog(flightLog_t *log, const char *filename, int logIndex)
//
// C程序主流程:
//   for (logIndex = 0; logIndex < log->logCount; logIndex++)
//       decodeFlightLog(log, filename, logIndex);
//
// ============================================================================

@interface BlackboxDecoder : NSObject

// ============================================================================
// 配置选项 - 对应C程序的 decodeOptions_t 结构体
// ============================================================================
@property (nonatomic, assign) BOOL rawMode;           // 对应 options.raw
@property (nonatomic, assign) BOOL debugMode;         // 对应 options.debug
@property (nonatomic, assign) BOOL mergeGPS;          // 对应 options.mergeGPS
@property (nonatomic, assign) BOOL simulateIMU;       // 对应 options.simulateIMU
@property (nonatomic, strong) NSString *outputDirectory; // 对应 options.outputDir

// 错误信息
@property (nonatomic, assign) BBLDecoderError lastError;
@property (nonatomic, strong) NSString *lastErrorMessage;
@property (nonatomic, strong) BBLLogHeader *logHeader;

// ============================================================================
// 核心解码方法 - 对应C程序的 decodeFlightLog()
// ============================================================================
//
// 完全对应: int decodeFlightLog(flightLog_t *log, const char *filename, int logIndex)
//
// 参数:
//   filename: BBL文件路径 (对应 const char *filename)
//   logIndex: log索引，从0开始 (对应 int logIndex)
//
// 行为:
//   1. 生成CSV文件，命名: <basename>.<logIndex+1>.csv
//      例如: 003.bbl, logIndex=0 -> 003.01.csv
//            003.bbl, logIndex=1 -> 003.02.csv
//   2. 输出目录由 outputDirectory 属性指定
//
// 返回值:
//   成功返回0，失败返回-1 (完全对应C程序)
//
- (int)decodeFlightLog:(NSString *)filename logIndex:(int)logIndex;

// ============================================================================
// 辅助方法 - 获取log数量
// ============================================================================
//
// 对应: log->logCount
//
- (int)getLogCount:(NSString *)filename;

// ============================================================================
// 辅助方法 - 列出所有log信息
// ============================================================================
//
// 对应C程序显示的log列表
//
- (NSArray<BBLSessionInfo *> *)listLogs:(NSString *)filename;

@end

// 错误处理
@interface BBLDecoderErrorHandler : NSObject
+ (NSString *)errorMessageForCode:(BBLDecoderError)errorCode;
@end

NS_ASSUME_NONNULL_END