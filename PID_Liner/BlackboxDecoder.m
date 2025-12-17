//
//  BlackboxDecoder.m
//  PID_Liner
//
//  Blackbox flight data decoder implementation for iOS
//  支持 iOS 真机和模拟器，使用静态库实现
//

#import "BlackboxDecoder.h"
#import <TargetConditionals.h>
#include <string.h>

// 导入 C 桥接头文件
#import "blackbox_bridge.h"

#pragma mark - BBLSessionInfo Implementation

@implementation BBLSessionInfo

// 重写description方法以提供可读的log信息
// 对应C程序的输出格式: "Log 1 of 2, start 02:59.995, end 03:01.444, duration 00:01.449"
- (NSString *)description {
    NSLog(@"description() - 生成log描述信息");

    // 如果已经设置了sessionDescription，直接返回
    if (_sessionDescription) {
        return _sessionDescription;
    }

    // 将微秒转换为 分:秒.毫秒 格式 (对应C程序的时间格式)
    // 使用int64_t避免溢出 (C程序也用int64_t)
    int64_t durationMs = _durationUs / 1000;  // 转换为毫秒
    uint32_t minutes = (uint32_t)(durationMs / 60000);
    uint32_t seconds = (uint32_t)((durationMs % 60000) / 1000);
    uint32_t milliseconds = (uint32_t)(durationMs % 1000);

    // 格式: "Log X: MM:SS.mmm (N frames)"
    return [NSString stringWithFormat:@"Log %d: %02u:%02u.%03u (%d frames)",
            _logIndex + 1,  // C程序显示从1开始
            minutes,
            seconds,
            milliseconds,
            _frameCount];
}

@end

// 内部数据结构
@interface BBLStreamReader : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) NSUInteger position;
@property (nonatomic, assign) NSUInteger bitPosition;
@property (nonatomic, assign) BOOL eof;
- (instancetype)initWithData:(NSData *)data;
- (uint8_t)readByte;
- (uint32_t)readBits:(NSInteger)count;
- (int32_t)readSignedVB;
- (void)alignByte;
@end

// 帧数据实现
@implementation BBLFrameData
@end

// 日志头实现
@implementation BBLLogHeader
@end

// 流读取器实现
@implementation BBLStreamReader

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        _data = data;
        _position = 0;
        _bitPosition = 0;
        _eof = NO;
    }
    return self;
}

- (uint8_t)readByte {
    if (_position >= _data.length) {
        _eof = YES;
        return 0;
    }
    uint8_t byte = ((uint8_t *)_data.bytes)[_position];
    _position++;
    _bitPosition = 0;
    return byte;
}

- (uint32_t)readBits:(NSInteger)count {
    uint32_t result = 0;
    for (NSInteger i = 0; i < count; i++) {
        if (_position >= _data.length) {
            _eof = YES;
            return 0;
        }
        
        uint8_t currentByte = ((uint8_t *)_data.bytes)[_position];
        BOOL bit = (currentByte >> (7 - _bitPosition)) & 0x01;
        result = (result << 1) | bit;
        
        _bitPosition++;
        if (_bitPosition >= 8) {
            _position++;
            _bitPosition = 0;
        }
    }
    return result;
}

- (int32_t)readSignedVB {
    int32_t result = 0;
    int8_t byte;
    NSInteger shift = 0;
    
    do {
        if (_position >= _data.length) {
            _eof = YES;
            return 0;
        }
        byte = (int8_t)[self readByte];
        result |= (int32_t)(byte & 0x7F) << shift;
        shift += 7;
    } while (byte & 0x80);
    
    // ZigZag解码
    return (result >> 1) ^ (-(result & 1));
}

- (void)alignByte {
    if (_bitPosition != 0) {
        _bitPosition = 0;
        _position++;
    }
}

// 黑盒解码算法移植
- (void)readTag2_3S32:(int64_t *)values {
    uint8_t leadByte = [self readByte];
    
    // 根据前两位选择字段布局
    switch (leadByte >> 6) {
        case 0: {
            // 2位字段
            values[0] = [self signExtend2Bit:(leadByte >> 4) & 0x03];
            values[1] = [self signExtend2Bit:(leadByte >> 2) & 0x03];
            values[2] = [self signExtend2Bit:leadByte & 0x03];
            break;
        }
        case 1: {
            // 4位字段
            values[0] = [self signExtend4Bit:leadByte & 0x0F];
            
            leadByte = [self readByte];
            values[1] = [self signExtend4Bit:leadByte >> 4];
            values[2] = [self signExtend4Bit:leadByte & 0x0F];
            break;
        }
        case 2: {
            // 6位字段
            values[0] = [self signExtend6Bit:leadByte & 0x3F];
            
            leadByte = [self readByte];
            values[1] = [self signExtend6Bit:leadByte & 0x3F];
            
            leadByte = [self readByte];
            values[2] = [self signExtend6Bit:leadByte & 0x3F];
            break;
        }
        case 3: {
            // 8位、16位或24位字段
            for (int i = 0; i < 3; i++) {
                switch (leadByte & 0x03) {
                    case 0: {
                        // 8位
                        uint8_t byte1 = [self readByte];
                        values[i] = (int8_t)byte1;
                        break;
                    }
                    case 1: {
                        // 16位
                        uint8_t byte1 = [self readByte];
                        uint8_t byte2 = [self readByte];
                        values[i] = (int16_t)(byte1 | (byte2 << 8));
                        break;
                    }
                    case 2: {
                        // 24位
                        uint8_t byte1 = [self readByte];
                        uint8_t byte2 = [self readByte];
                        uint8_t byte3 = [self readByte];
                        uint32_t value = byte1 | (byte2 << 8) | (byte3 << 16);
                        values[i] = [self signExtend24Bit:value];
                        break;
                    }
                    case 3: {
                        // 32位
                        uint8_t byte1 = [self readByte];
                        uint8_t byte2 = [self readByte];
                        uint8_t byte3 = [self readByte];
                        uint8_t byte4 = [self readByte];
                        values[i] = (int32_t)(byte1 | (byte2 << 8) | (byte3 << 16) | (byte4 << 24));
                        break;
                    }
                }
                leadByte >>= 2;
            }
            break;
        }
    }
}

- (void)readTag8_4S16_v1:(int64_t *)values {
    uint8_t selector = [self readByte];
    
    // 读取4个值
    for (int i = 0; i < 4; i++) {
        switch (selector & 0x03) {
            case 0: // FIELD_ZERO
                values[i] = 0;
                break;
            case 1: { // FIELD_4BIT (两个4位字段)
                uint8_t combinedChar = [self readByte];
                values[i] = [self signExtend4Bit:combinedChar & 0x0F];
                
                i++;
                selector >>= 2;
                values[i] = [self signExtend4Bit:combinedChar >> 4];
                break;
            }
            case 2: // FIELD_8BIT
                values[i] = (int8_t)[self readByte];
                break;
            case 3: { // FIELD_16BIT
                uint8_t char1 = [self readByte];
                uint8_t char2 = [self readByte];
                values[i] = (int16_t)(char1 | (char2 << 8));
                break;
            }
        }
        selector >>= 2;
    }
}

- (void)readTag8_4S16_v2:(int64_t *)values {
    uint8_t selector = [self readByte];
    uint8_t buffer = 0;
    int nibbleIndex = 0;
    
    // 读取4个值
    for (int i = 0; i < 4; i++) {
        switch (selector & 0x03) {
            case 0: // FIELD_ZERO
                values[i] = 0;
                break;
            case 1: { // FIELD_4BIT
                if (nibbleIndex == 0) {
                    buffer = [self readByte];
                    values[i] = [self signExtend4Bit:buffer >> 4];
                    nibbleIndex = 1;
                } else {
                    values[i] = [self signExtend4Bit:buffer & 0x0F];
                    nibbleIndex = 0;
                }
                break;
            }
            case 2: { // FIELD_8BIT
                if (nibbleIndex == 0) {
                    values[i] = (int8_t)[self readByte];
                } else {
                    uint8_t char1 = buffer << 4;
                    buffer = [self readByte];
                    char1 |= buffer >> 4;
                    values[i] = (int8_t)char1;
                }
                break;
            }
            case 3: { // FIELD_16BIT
                if (nibbleIndex == 0) {
                    uint8_t char1 = [self readByte];
                    uint8_t char2 = [self readByte];
                    values[i] = (int16_t)((char1 << 8) | char2);
                } else {
                    uint8_t char1 = [self readByte];
                    uint8_t char2 = [self readByte];
                    values[i] = (int16_t)((buffer << 12) | (char1 << 4) | (char2 >> 4));
                    buffer = char2;
                }
                break;
            }
        }
        selector >>= 2;
    }
}

- (uint32_t)readEliasDeltaU32 {
    uint32_t result = 1;
    uint32_t len = 1;
    
    // 读取长度编码
    while ([self readBits:1] == 0) {
        len++;
    }
    
    // 读取数值部分
    if (len > 1) {
        result = [self readBits:len - 1] | (1 << (len - 1));
    }
    
    return result;
}

- (int32_t)readEliasDeltaS32 {
    return [self zigzagDecode:[self readEliasDeltaU32]];
}

- (uint32_t)readEliasGammaU32 {
    uint32_t len = 0;
    
    // 读取前导零
    while ([self readBits:1] == 0) {
        len++;
    }
    
    // 读取剩余位
    if (len == 0) {
        return 1;
    }
    
    return [self readBits:len] | (1 << len);
}

- (int32_t)readEliasGammaS32 {
    return [self zigzagDecode:[self readEliasGammaU32]];
}

// 辅助函数
- (int32_t)signExtend2Bit:(uint8_t)value {
    return (value & 0x02) ? (int32_t)(int8_t)(value | 0xFC) : value;
}

- (int32_t)signExtend4Bit:(uint8_t)value {
    return (value & 0x08) ? (int32_t)(int8_t)(value | 0xF0) : value;
}

- (int32_t)signExtend6Bit:(uint8_t)value {
    return (value & 0x20) ? (int32_t)(int8_t)(value | 0xC0) : value;
}

- (int32_t)signExtend24Bit:(uint32_t)value {
    return (value & 0x800000) ? (int32_t)(value | 0xFF000000) : (int32_t)value;
}

- (int32_t)zigzagDecode:(uint32_t)value {
    return (value >> 1) ^ -(int32_t)(value & 1);
}

@end

// 错误处理实现
@implementation BBLDecoderErrorHandler

+ (NSString *)errorMessageForCode:(BBLDecoderError)errorCode {
    switch (errorCode) {
        case BBLDecoderErrorNone:
            return @"No error";
        case BBLDecoderErrorFileNotFound:
            return @"File not found";
        case BBLDecoderErrorInvalidFormat:
            return @"Invalid file format";
        case BBLDecoderErrorDecodingFailed:
            return @"Decoding failed";
        case BBLDecoderErrorWriteFailed:
            return @"Failed to write output file";
        default:
            return @"Unknown error";
    }
}

@end

// 主解码器实现
@interface BlackboxDecoder ()
@property (nonatomic, strong) BBLStreamReader *streamReader;
@property (nonatomic, strong) NSMutableArray<BBLFrameData *> *frameBuffer;
@property (nonatomic, strong) NSMutableDictionary *fieldDefinitions;
@property (nonatomic, assign) NSInteger currentFrameIndex;
@end

@implementation BlackboxDecoder

- (instancetype)init {
    self = [super init];
    if (self) {
        _frameBuffer = [NSMutableArray array];
        _fieldDefinitions = [NSMutableDictionary dictionary];
        _currentFrameIndex = 0;
        _rawMode = NO;
        _debugMode = NO;
        _mergeGPS = NO;
        _simulateIMU = NO;
        _lastError = BBLDecoderErrorNone;
        _lastErrorMessage = @"";
    }
    return self;
}

#pragma mark - Public Methods

#pragma mark - Session Management

// ============================================================================
// listLogs() - 列出BBL文件中的所有log
// 对应C程序: 扫描log->logBegin数组，获取所有log的信息
// ============================================================================
- (NSArray<BBLSessionInfo *> *)listLogs:(NSString *)filename {
    NSLog(@"listLogs() - 开始扫描log，对应C程序的log->logCount");

    // 检查文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:filename]) {
        NSLog(@"❌ 文件不存在: %@", filename);
        return @[];
    }

    // 读取文件数据
    NSData *fileData = [NSData dataWithContentsOfFile:filename];
    if (!fileData || fileData.length == 0) {
        NSLog(@"❌ 无法读取文件或文件为空");
        return @[];
    }

    NSLog(@"✅ 文件大小: %lu bytes", (unsigned long)fileData.length);

    // LOG_START_MARKER - 对应C程序的定义
    // #define LOG_START_MARKER "H Product:Blackbox flight data recorder by Nicholas Sherlock\n"
    NSString *logStartMarker = @"H Product:Blackbox flight data recorder by Nicholas Sherlock\n";
    NSData *markerData = [logStartMarker dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableArray<BBLSessionInfo *> *logs = [NSMutableArray array];

    // 对应C程序: for (logIndex = 0; logIndex < FLIGHT_LOG_MAX_LOGS_IN_FILE && logSearchStart < ...; logIndex++)
    size_t fileSize = fileData.length;
    size_t searchStart = 0;  // 对应C程序的 logSearchStart
    int logIndex = 0;

    // 搜索所有log的起始位置
    // 对应C程序: log->logBegin[logIndex] = memmem(logSearchStart, ...)
    while (searchStart < fileSize) {
        // 在剩余数据中搜索标记
        NSRange searchRange = NSMakeRange(searchStart, fileSize - searchStart);
        NSRange foundRange = [fileData rangeOfData:markerData
                                           options:0
                                             range:searchRange];

        if (foundRange.location == NSNotFound) {
            // 没有找到更多log
            break;
        }

        size_t logStartOffset = foundRange.location;  // 对应C程序的 log->logBegin[logIndex]
        NSLog(@"✅ 找到Log %d at offset %zu", logIndex, logStartOffset);

        // 创建log信息对象
        BBLSessionInfo *logInfo = [[BBLSessionInfo alloc] init];
        logInfo.logIndex = logIndex;
        logInfo.startOffset = logStartOffset;

        // 解析Header
        BBLStreamReader *reader = [[BBLStreamReader alloc] initWithData:fileData];
        reader.position = logStartOffset;
        logInfo.header = [self parseHeaderFromReader:reader];

        // 计算log的结束位置（下一个log的开始位置或文件末尾）
        // 对应C程序: logSearchStart = log->logBegin[logIndex] + strlen(LOG_START_MARKER)
        searchStart = logStartOffset + markerData.length;

        // 查找下一个log的起始位置
        NSRange nextSearchRange = NSMakeRange(searchStart, fileSize - searchStart);
        NSRange nextFoundRange = [fileData rangeOfData:markerData
                                               options:0
                                                 range:nextSearchRange];

        size_t logEndOffset;
        if (nextFoundRange.location != NSNotFound) {
            logEndOffset = nextFoundRange.location;  // 下一个log的开始
        } else {
            logEndOffset = fileSize;  // 文件末尾
        }

        logInfo.endOffset = logEndOffset;

        // 扫描该log的所有帧，统计信息
        reader.position = logStartOffset;
        [self parseHeaderFromReader:reader];  // 跳过header

        int frameCount = 0;
        int64_t startTimeUs = 0;
        int64_t endTimeUs = 0;
        BOOL firstFrame = YES;

        while (reader.position < logEndOffset && !reader.eof) {
            uint8_t frameByte = [reader readByte];
            if (reader.eof) break;

            char frameType = (char)frameByte;

            // 统计帧数
            if (frameType == 'I' || frameType == 'P' || frameType == 'G' ||
                frameType == 'S' || frameType == 'E') {
                frameCount++;

                if (firstFrame) {
                    startTimeUs = 0;
                    firstFrame = NO;
                }
                endTimeUs = frameCount * 1000;  // 简化：假设每帧1ms
            }
        }

        logInfo.frameCount = frameCount;
        logInfo.startTimeUs = startTimeUs;
        logInfo.endTimeUs = endTimeUs;
        logInfo.durationUs = endTimeUs - startTimeUs;

        NSLog(@"  - 帧数: %d", frameCount);
        NSLog(@"  - 持续时间: %lld us (%.3f秒)", logInfo.durationUs, logInfo.durationUs / 1000000.0);

        [logs addObject:logInfo];
        logIndex++;
    }

    NSLog(@"✅ 共找到 %d 个log (对应C程序的log->logCount)", (int)logs.count);
    return [logs copy];
}

// ============================================================================
// getLogCount() - 获取log数量
// 对应C程序: log->logCount
// 使用静态库实现
// ============================================================================
- (int)getLogCount:(NSString *)filename {
    NSLog(@"getLogCount() - 使用静态库获取log数量");

    // 检查文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:filename]) {
        NSLog(@"❌ 文件不存在: %@", filename);
        return 0;
    }

    // 调用静态库函数获取session数量
    int sessionCount = 0;
    DecodeStatus status = blackbox_list_sessions([filename UTF8String], &sessionCount);

    if (status != DECODE_SUCCESS) {
        NSLog(@"❌ 获取session数量失败");
        return 0;
    }

    NSLog(@"✅ 找到 %d 个log (使用静态库)", sessionCount);
    return sessionCount;
}

#pragma mark - Decoding Methods

// ============================================================================
// decodeFlightLog() - 核心解码方法
// 完全对应C程序: int decodeFlightLog(flightLog_t *log, const char *filename, int logIndex)
// ============================================================================
//
// 使用静态库实现，支持 iOS 真机和模拟器
//
- (int)decodeFlightLog:(NSString *)filename logIndex:(int)logIndex {
    NSLog(@"decodeFlightLog() - 使用静态库解码log %d", logIndex);

    // 步骤1: 检查文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:filename]) {
        NSLog(@"❌ 文件不存在: %@", filename);
        self.lastError = BBLDecoderErrorFileNotFound;
        self.lastErrorMessage = [BBLDecoderErrorHandler errorMessageForCode:self.lastError];
        return -1;
    }

    // 步骤2: 确定输出目录
    NSString *outputDir;
    if (self.outputDirectory) {
        outputDir = self.outputDirectory;
    } else {
        // 输出到输入文件同目录
        outputDir = [filename stringByDeletingLastPathComponent];
    }

    NSLog(@"  输入文件: %@", filename);
    NSLog(@"  输出目录: %@", outputDir);
    NSLog(@"  log索引: %d (对应CSV文件后缀: %02d)", logIndex, logIndex + 1);

    // 步骤3: 调用静态库函数解码
    DecodeResult result;
    memset(&result, 0, sizeof(result));

    DecodeStatus status = blackbox_decode_to_csv_with_index(
        [filename UTF8String],
        logIndex,
        &result
    );

    if (status != DECODE_SUCCESS) {
        NSLog(@"❌ 解码失败，状态码: %d", (int)status);
        NSLog(@"❌ 错误信息: %s", result.errorMessage);
        self.lastError = BBLDecoderErrorDecodingFailed;
        self.lastErrorMessage = [NSString stringWithUTF8String:result.errorMessage];
        blackbox_free_decode_result(&result);
        return -1;
    }

    NSLog(@"✅ 解码成功，帧数: %d", result.frameCount);

    // 步骤4: 将CSV数据写入文件
    NSString *basename = [[filename lastPathComponent] stringByDeletingPathExtension];
    NSString *csvFilename = [NSString stringWithFormat:@"%@.%02d.csv", basename, logIndex + 1];
    NSString *outputPath = [outputDir stringByAppendingPathComponent:csvFilename];

    // 写入CSV文件
    if (result.data && result.dataLength > 0) {
        NSData *csvData = [NSData dataWithBytes:result.data length:result.dataLength];
        NSError *writeError;
        BOOL writeSuccess = [csvData writeToFile:outputPath options:NSDataWritingAtomic error:&writeError];

        if (!writeSuccess) {
            NSLog(@"❌ 写入CSV文件失败: %@", writeError.localizedDescription);
            self.lastError = BBLDecoderErrorWriteFailed;
            self.lastErrorMessage = writeError.localizedDescription;
            blackbox_free_decode_result(&result);
            return -1;
        }

        NSLog(@"✅ CSV文件已生成: %@", outputPath);
    } else {
        NSLog(@"❌ 解码结果为空");
        self.lastError = BBLDecoderErrorDecodingFailed;
        self.lastErrorMessage = @"Decode result is empty";
        blackbox_free_decode_result(&result);
        return -1;
    }

    // 步骤5: 清理资源
    blackbox_free_decode_result(&result);

    // 返回0表示成功 (对应C程序)
    return 0;
}

// ============================================================================
// 旧的方法保留用于兼容性，但不推荐使用
// ============================================================================

// decodeFile:outputPath:sessionIndex: - 已废弃，请使用decodeFlightLog:logIndex:
- (BOOL)decodeFile:(NSString *)inputPath
        outputPath:(NSString *)outputPath
      sessionIndex:(NSInteger)sessionIndex {
    NSLog(@"⚠️  decodeFile:outputPath:sessionIndex: 已废弃，请使用decodeFlightLog:logIndex:");

    // 为了兼容性，调用新方法
    int result = [self decodeFlightLog:inputPath logIndex:(int)sessionIndex];
    return (result == 0);
}

// decodeFile:outputPath:sessionIndexes: - 已废弃
- (BOOL)decodeFile:(NSString *)inputPath
        outputPath:(NSString *)outputPath
    sessionIndexes:(NSArray<NSNumber *> *)sessionIndexes {
    NSLog(@"⚠️  decodeFile:outputPath:sessionIndexes: 已废弃");

    // C程序不支持这种模式，返回失败
    self.lastError = BBLDecoderErrorInvalidFormat;
    self.lastErrorMessage = @"This method is deprecated. C program does not support decoding multiple logs to one file.";
    return NO;
}

// decodeFile:outputPath: - 已废弃
- (BOOL)decodeFile:(NSString *)inputPath outputPath:(NSString *)outputPath {
    NSLog(@"⚠️  decodeFile:outputPath: 已废弃");

    // C程序不支持这种模式，返回失败
    self.lastError = BBLDecoderErrorInvalidFormat;
    self.lastErrorMessage = @"This method is deprecated. Please use decodeFlightLog:logIndex: for each log.";
    return NO;
}

// ============================================================================
// decodeData() - 内部解码方法
// 对应C程序的核心解码逻辑
// ============================================================================
- (BOOL)decodeData:(NSData *)inputData outputPath:(NSString *)outputPath {
    NSLog(@"decodeData:outputPath: - 内部解码方法，对应C程序的解码流程");

    if (!inputData || inputData.length == 0) {
        NSLog(@"❌ 输入数据为空");
        self.lastError = BBLDecoderErrorInvalidFormat;
        self.lastErrorMessage = @"Input data is empty";
        return NO;
    }
    @try {
        // 初始化流读取器
        self.streamReader = [[BBLStreamReader alloc] initWithData:inputData];
        
        // 解析头部信息
        if (![self parseHeader]) {
            return NO;
        }
        
        // 解析数据帧
        if (![self parseFrames]) {
            return NO;
        }
        
        // 写入CSV文件
        if (![self writeCSVToFile:outputPath]) {
            return NO;
        }
        
        self.lastError = BBLDecoderErrorNone;
        self.lastErrorMessage = @"";
        return YES;
        
    } @catch (NSException *exception) {
        self.lastError = BBLDecoderErrorDecodingFailed;
        self.lastErrorMessage = [NSString stringWithFormat:@"Decoding error: %@", exception.reason];
        return NO;
    }
}

- (NSArray<BBLFrameData *> *)getFrameData:(NSString *)filePath {
    if ([self decodeFile:filePath outputPath:@"/dev/null"]) {
        return [self.frameBuffer copy];
    }
    return @[];
}

- (BBLFrameData *)getNextFrame {
    if (self.currentFrameIndex < self.frameBuffer.count) {
        BBLFrameData *frame = self.frameBuffer[self.currentFrameIndex];
        self.currentFrameIndex++;
        return frame;
    }
    return nil;
}

#pragma mark - Private Methods

// parseHeaderFromReader: - 从指定的reader解析Header（用于Session扫描）
- (BBLLogHeader *)parseHeaderFromReader:(BBLStreamReader *)reader {
    NSLog(@"parseHeaderFromReader() - 开始解析Header");

    BBLLogHeader *header = [[BBLLogHeader alloc] init];
    NSMutableString *headerString = [NSMutableString string];
    NSMutableArray *fieldNames = [NSMutableArray array];

    while (!reader.eof) {
        uint8_t byte = [reader readByte];

        if (byte == '\n') {
            NSString *line = [headerString copy];
            [headerString setString:@""];

            // 解析头部行
            if ([line hasPrefix:@"H "]) {
                // 解析基本信息
                NSString *content = [line substringFromIndex:2];
                if ([content hasPrefix:@"Product:"]) {
                    header.product = [[content substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            } else if ([line hasPrefix:@"Field I "]) {
                // 记录字段定义
                [fieldNames addObject:line];
            } else if (line.length == 0) {
                // 空行表示Header结束
                break;
            }
        } else {
            [headerString appendFormat:@"%c", byte];
        }
    }

    header.fieldNames = [fieldNames copy];

    NSLog(@"✅ Header解析完成: Product=%@, Fields=%lu",
          header.product, (unsigned long)fieldNames.count);

    return header.product.length > 0 ? header : nil;
}

- (BOOL)parseHeader {
    NSMutableString *headerString = [NSMutableString string];
    NSMutableDictionary *fieldDefinitions = [NSMutableDictionary dictionary];
    NSMutableArray *fieldNames = [NSMutableArray array];
    
    if (!self.logHeader) {
        self.logHeader = [[BBLLogHeader alloc] init];
    }
    
    while (!self.streamReader.eof) {
        uint8_t byte = [self.streamReader readByte];
        
        if (byte == '\n') {
            NSString *line = [headerString copy];
            [headerString setString:@""];
            
            // 解析头部行
            if ([line hasPrefix:@"H "]) {
                [self parseHeaderLine:line];
            } else if ([line hasPrefix:@"Field I "]) {
                // 解析内帧字段定义
                [self parseFieldDefinition:line type:@"I" fieldNames:fieldNames fieldDefs:fieldDefinitions];
            } else if ([line hasPrefix:@"Field P "]) {
                // 解析预测帧字段定义
                [self parseFieldDefinition:line type:@"P" fieldNames:fieldNames fieldDefs:fieldDefinitions];
            } else if ([line hasPrefix:@"Field G "]) {
                // 解析GPS帧字段定义
                [self parseFieldDefinition:line type:@"G" fieldNames:fieldNames fieldDefs:fieldDefinitions];
            } else if ([line hasPrefix:@"Field S "]) {
                // 解析慢帧字段定义
                [self parseFieldDefinition:line type:@"S" fieldNames:fieldNames fieldDefs:fieldDefinitions];
            } else if ([line hasPrefix:@"I "] || [line hasPrefix:@"P "] || [line hasPrefix:@"G "] || [line hasPrefix:@"S "]) {
                // 重置位置到数据开始
                self.streamReader.position -= (line.length + 1);
                break;
            }
        } else {
            [headerString appendFormat:@"%c", byte];
        }
        
        if (headerString.length > 10000) { // 防止无限循环
            break;
        }
    }
    
    // 设置字段定义
    self.logHeader.fieldNames = fieldNames;
    self.fieldDefinitions = fieldDefinitions;
    
    return self.logHeader.product.length > 0;
}

- (void)parseHeaderLine:(NSString *)line {
    // 移除头部标记
    NSString *content = [line substringFromIndex:2];
    
    if ([content hasPrefix:@"Product:"]) {
        self.logHeader.product = [[content substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([content hasPrefix:@"Firmware revision:"]) {
        self.logHeader.firmwareRevision = [[content substringFromIndex:18] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([content hasPrefix:@"Firmware date:"]) {
        self.logHeader.firmwareDate = [[content substringFromIndex:14] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([content hasPrefix:@"Log start datetime:"]) {
        // 解析开始时间 - 转换为int64_t微秒时间戳 (对应C程序)
        NSString *dateStr = [[content substringFromIndex:19] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSDate *date = [formatter dateFromString:dateStr];
        if (date) {
            self.logHeader.startDatetimeUs = (int64_t)([date timeIntervalSince1970] * 1000000);
        } else {
            self.logHeader.startDatetimeUs = 0;
        }
    } else if ([content hasPrefix:@"Craft name:"]) {
        self.logHeader.craftName = [[content substringFromIndex:11] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([content hasPrefix:@"P interval:"]) {
        self.logHeader.pIntervalStr = [[content substringFromIndex:11] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else if ([content hasPrefix:@"P ratio:"]) {
        self.logHeader.pRatioStr = [[content substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
}

- (void)parseFieldDefinition:(NSString *)line type:(NSString *)type 
                  fieldNames:(NSMutableArray *)fieldNames 
                   fieldDefs:(NSMutableDictionary *)fieldDefs {
    // 解析字段定义，格式类似: "Field I name,signed,encoding, predictor"
    NSString *content = [line substringFromIndex:7]; // 移除 "Field X "
    NSArray *parts = [content componentsSeparatedByString:@","];
    
    if (parts.count >= 1) {
        NSString *fieldName = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [fieldNames addObject:fieldName];
        
        NSMutableDictionary *fieldInfo = [NSMutableDictionary dictionary];
        fieldInfo[@"type"] = type;
        fieldInfo[@"name"] = fieldName;
        
        if (parts.count > 1) {
            fieldInfo[@"signed"] = @([parts[1] isEqualToString:@"signed"]);
        }
        if (parts.count > 2) {
            fieldInfo[@"encoding"] = parts[2];
        }
        if (parts.count > 3) {
            fieldInfo[@"predictor"] = parts[3];
        }
        
        fieldDefs[fieldName] = fieldInfo;
    }
}

- (BOOL)parseFrames {
    // 简化的帧解析
    while (!self.streamReader.eof) {
        BBLFrameData *frame = [self parseNextFrame];
        if (frame) {
            [self.frameBuffer addObject:frame];
        } else {
            break;
        }
    }
    
    return self.frameBuffer.count > 0;
}

- (BBLFrameData *)parseNextFrame {
    if (self.streamReader.eof) {
        return nil;
    }
    
    BBLFrameData *frame = [[BBLFrameData alloc] init];
    
    // 读取帧类型
    uint8_t frameType = [self.streamReader readByte];
    frame.frameType = [NSString stringWithFormat:@"%c", frameType];
    
    // 根据帧类型选择解码方法
    NSMutableArray *values = [NSMutableArray array];
    
    switch (frameType) {
        case 'I': { // 内帧 (Intra frame)
            int64_t tag2_3Values[3];
            [self.streamReader readTag2_3S32:tag2_3Values];
            
            // 添加解码的值
            for (int i = 0; i < 3; i++) {
                [values addObject:@(tag2_3Values[i])];
            }
            
            // 读取更多数据
            while (!self.streamReader.eof && values.count < 50) {
                int32_t value = [self.streamReader readSignedVB];
                [values addObject:@(value)];
            }
            break;
        }
        case 'P': { // 预测帧 (Predicted frame)
            int64_t tag8_4Values[4];
            [self.streamReader readTag8_4S16_v1:tag8_4Values];
            
            // 添加解码的值
            for (int i = 0; i < 4; i++) {
                [values addObject:@(tag8_4Values[i])];
            }
            
            // 读取更多数据
            while (!self.streamReader.eof && values.count < 30) {
                int32_t value = [self.streamReader readSignedVB];
                [values addObject:@(value)];
            }
            break;
        }
        case 'G': { // GPS帧
            int64_t tag8_4Values[4];
            [self.streamReader readTag8_4S16_v2:tag8_4Values];
            
            // 添加GPS数据
            for (int i = 0; i < 4; i++) {
                [values addObject:@(tag8_4Values[i])];
            }
            
            // 读取经纬度等数据
            for (int i = 0; i < 6 && !self.streamReader.eof; i++) {
                int32_t value = [self.streamReader readEliasDeltaS32];
                [values addObject:@(value)];
            }
            break;
        }
        case 'S': { // 慢帧 (Slow frame)
            // 使用Elias Gamma编码
            int32_t value = [self.streamReader readEliasGammaS32];
            [values addObject:@(value)];
            
            // 读取更多慢数据
            while (!self.streamReader.eof && values.count < 20) {
                int32_t nextValue = [self.streamReader readEliasGammaS32];
                [values addObject:@(nextValue)];
            }
            break;
        }
        default: {
            // 未知帧类型，使用默认解码
            for (int i = 0; i < 10 && !self.streamReader.eof; i++) {
                int32_t value = [self.streamReader readSignedVB];
                [values addObject:@(value)];
            }
            break;
        }
    }
    
    frame.values = [values copy];

    // 时间戳 - 使用int64_t微秒时间戳 (对应C程序)
    frame.timestampUs = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000000);

    // 迭代次数 - 使用uint32_t (对应C程序)
    frame.iteration = (uint32_t)self.frameBuffer.count;

    return frame;
}

- (BOOL)writeCSVToFile:(NSString *)outputPath {
    @try {
        NSMutableString *csvContent = [NSMutableString string];
        
        // 写入CSV头部 - 基于实际的飞行数据字段
        NSMutableArray *headers = [NSMutableArray arrayWithObjects:
            @"loopIteration", @"time (us)", @"frameType", nil];
        
        // 根据头部信息添加字段定义
        if (self.logHeader && self.logHeader.fieldNames && self.logHeader.fieldNames.count > 0) {
            [headers addObjectsFromArray:self.logHeader.fieldNames];
        } else {
            // 默认字段名
            [headers addObjectsFromArray:@[
                @"axisP[0]", @"axisP[1]", @"axisP[2]",
                @"axisI[0]", @"axisI[1]", @"axisI[2]",
                @"axisD[0]", @"axisD[1]", @"axisD[2]",
                @"axisF[0]", @"axisF[1]", @"axisF[2]",
                @"rcCommand[0]", @"rcCommand[1]", @"rcCommand[2]", @"rcCommand[3]",
                @"gyroADC[0]", @"gyroADC[1]", @"gyroADC[2]",
                @"accSmooth[0]", @"accSmooth[1]", @"accSmooth[2]",
                @"motor[0]", @"motor[1]", @"motor[2]", @"motor[3]"
            ]];
        }
        
        [csvContent appendFormat:@"%@\n", [headers componentsJoinedByString:@","]];
        
        // 写入帧数据
        NSInteger frameIndex = 0;
        for (BBLFrameData *frame in self.frameBuffer) {
            NSMutableArray *rowData = [NSMutableArray array];
            
            // 基本信息 (对应C程序的CSV输出格式)
            [rowData addObject:@(frame.iteration)]; // loopIteration (uint32_t)
            [rowData addObject:@(frame.timestampUs)]; // time (us) - 已经是微秒，直接使用int64_t
            [rowData addObject:frame.frameType]; // frameType
            
            // 添加帧数据值
            for (NSNumber *value in frame.values) {
                [rowData addObject:[value stringValue]];
            }
            
            // 填充缺失的字段
            while (rowData.count < headers.count) {
                [rowData addObject:@"0"];
            }
            
            [csvContent appendFormat:@"%@\n", [rowData componentsJoinedByString:@","]];
            frameIndex++;
        }
        
        // 写入文件
        NSError *error;
        BOOL success = [csvContent writeToFile:outputPath 
                                    atomically:YES 
                                      encoding:NSUTF8StringEncoding 
                                         error:&error];
        
        if (!success) {
            self.lastError = BBLDecoderErrorWriteFailed;
            self.lastErrorMessage = [NSString stringWithFormat:@"Failed to write CSV file: %@", error.localizedDescription];
            return NO;
        }
        
        return YES;
        
    } @catch (NSException *exception) {
        self.lastError = BBLDecoderErrorWriteFailed;
        self.lastErrorMessage = [NSString stringWithFormat:@"Write error: %@", exception.reason];
        return NO;
    }
}

@end