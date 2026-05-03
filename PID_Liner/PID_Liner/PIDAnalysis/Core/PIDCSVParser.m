//
//  PIDCSVParser.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  CSV文件解析器实现 - 流式读取支持大文件
//

#import "PIDCSVParser.h"
#import "PIDDataModels.h"

// 默认缓冲区大小：8KB
static const NSInteger kDefaultBufferSize = 8 * 1024;

// 默认最大读取行数（防止内存溢出）
static const NSInteger kDefaultMaxRows = 100000;

#pragma mark - PIDCSVParserConfig Implementation

@implementation PIDCSVParserConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxRows = kDefaultMaxRows;          // 默认限制10万行
        _skipEmptyValues = YES;
        _bufferSize = kDefaultBufferSize;
    }
    return self;
}

@end

#pragma mark - PIDCSVParser Implementation

@interface PIDCSVParser ()

@property (nonatomic, copy, readwrite) NSString *lastErrorMessage;

// 字段索引映射（字段名 -> 列索引）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *fieldIndexes;

// 数据缓存（解析过程中使用）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *dataCache;

// 读取缓冲区（保存跨行的剩余数据）
@property (nonatomic, strong) NSMutableData *readBuffer;

@end

@implementation PIDCSVParser

#pragma mark - Lifecycle

+ (instancetype)parser {
    PIDCSVParserConfig *config = [[PIDCSVParserConfig alloc] init];
    return [[self alloc] initWithConfig:config];
}

- (instancetype)initWithConfig:(PIDCSVParserConfig *)config {
    self = [super init];
    if (self) {
        _config = config ?: [[PIDCSVParserConfig alloc] init];
        _fieldIndexes = [NSMutableDictionary dictionary];
        _dataCache = [NSMutableDictionary dictionary];
        _verboseLogging = YES;
    }
    return self;
}

#pragma mark - Public Methods

+ (NSArray<NSString *> *)requiredFields {
    // 对应Python PID-Analyzer源码中的wanted数组
    // 源文件: PID-Analyzer.py line 679-691
    // 注意：同时包含 "time (us)" 和 "time" 以支持不同的CSV格式
    return @[
        @"time",           // 优先使用（真机解码生成的CSV使用此字段名）
        @"time (us)",      // 备用字段名（标准格式）
        @"rcCommand[0]", @"rcCommand[1]", @"rcCommand[2]", @"rcCommand[3]",
        @"axisP[0]", @"axisP[1]", @"axisP[2]",
        @"axisI[0]", @"axisI[1]", @"axisI[2]",
        @"axisD[0]", @"axisD[1]", @"axisD[2]",
        @"gyroADC[0]", @"gyroADC[1]", @"gyroADC[2]",
        @"debug[0]", @"debug[1]", @"debug[2]", @"debug[3]"
    ];
}

- (NSInteger)estimateRowCount:(NSString *)filePath {
    @try {
        NSError *error = nil;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
        if (!attrs) {
            return -1;
        }

        // 估算：假设平均每行100字节
        unsigned long long fileSize = [attrs fileSize];
        NSInteger estimatedRows = (NSInteger)(fileSize / 100);

        if (self.verboseLogging) {
            NSLog(@"📊 估算CSV行数: 文件大小=%llu bytes, 预估约%ld行", fileSize, (long)estimatedRows);
        }

        return estimatedRows;
    } @catch (NSException *exception) {
        NSLog(@"❌ 估算行数失败: %@", exception.reason);
        return -1;
    }
}

- (BOOL)validateCSVFormat:(NSString *)filePath {
    @try {
        // 检查文件是否存在
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            self.lastErrorMessage = [NSString stringWithFormat:@"文件不存在: %@", filePath];
            return NO;
        }

        // 读取第一行验证表头
        NSError *error = nil;
        NSString *firstLine = [self readFirstLine:filePath error:&error];
        if (!firstLine) {
            self.lastErrorMessage = [NSString stringWithFormat:@"读取文件失败: %@", error.localizedDescription];
            return NO;
        }

        // 解析表头
        NSArray<NSString *> *headers = [self parseCSVLine:firstLine];
        if (headers.count == 0) {
            self.lastErrorMessage = @"CSV表头为空";
            return NO;
        }

        // 检查必需字段是否存在
        NSArray<NSString *> *requiredFields = [[self class] requiredFields];
        NSMutableSet<NSString *> *missingFields = [NSMutableSet setWithArray:requiredFields];

        for (NSString *header in headers) {
            [missingFields removeObject:header];
        }

        if (missingFields.count > 0) {
            NSString *missingStr = [[missingFields allObjects] componentsJoinedByString:@", "];
            self.lastErrorMessage = [NSString stringWithFormat:@"缺少必需字段: %@", missingStr];
            if (self.verboseLogging) {
                NSLog(@"⚠️ CSV验证警告: %@", self.lastErrorMessage);
            }
            // 不返回NO，因为某些字段可能确实不存在于某些日志中
        }

        if (self.verboseLogging) {
            NSLog(@"✅ CSV格式验证通过: %lu个字段", (unsigned long)headers.count);
        }

        return YES;
    } @catch (NSException *exception) {
        self.lastErrorMessage = [NSString stringWithFormat:@"验证异常: %@", exception.reason];
        NSLog(@"❌ validateCSVFormat异常: %@", exception);
        return NO;
    }
}

- (nullable NSString *)extractCraftNameFromCSV:(NSString *)filePath {
    NSString *craftName = nil;
    [self readFirstNonCommentLine:filePath error:nil extractedCraftName:&craftName extractedFlightTime:nil extractedFwVersion:nil extractedPIDConfig:nil extractedMotorKV:nil extractedChainId:nil extractedChainIteration:nil];
    return craftName;
}

- (nullable PIDCSVData *)parseCSV:(NSString *)filePath {
    return [self parseCSV:filePath progressHandler:nil];
}

- (nullable PIDCSVData *)parseCSV:(NSString *)filePath
                progressHandler:(nullable void(^)(NSInteger, NSInteger))progressHandler {
    @try {
        NSLog(@"📝 开始解析CSV: %@", filePath);

        // 验证文件格式
        if (![self validateCSVFormat:filePath]) {
            NSLog(@"❌ CSV格式验证失败: %@", self.lastErrorMessage);
            return nil;
        }

        // 重置缓存
        [self resetDataCache];

        // 流式读取文件
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
        if (!fileHandle) {
            self.lastErrorMessage = @"无法打开文件";
            return nil;
        }

        // 读取并解析表头（跳过注释行，提取元数据）
        NSString *parsedCraftName = nil;
        NSString *parsedFlightTimeStr = nil;
        NSInteger parsedFwVersion = 0;
        NSDictionary *parsedPIDConfig = nil;
        NSInteger parsedMotorKV = 0;
        NSString *parsedChainId = nil;
        NSInteger parsedChainIteration = 0;
        NSString *headerLine = [self readFirstNonCommentLine:filePath
                                                       error:nil
                                        extractedCraftName:&parsedCraftName
                                        extractedFlightTime:&parsedFlightTimeStr
                                        extractedFwVersion:&parsedFwVersion
                                          extractedPIDConfig:&parsedPIDConfig
                                            extractedMotorKV:&parsedMotorKV
                                              extractedChainId:&parsedChainId
                                        extractedChainIteration:&parsedChainIteration];
        NSArray<NSString *> *headers = [self parseCSVLine:headerLine];
        [self buildFieldIndexes:headers];

        // 解析数据行
        NSInteger currentRow = 0;
        NSInteger totalRows = [self estimateRowCount:filePath];
        NSString *line;
        BOOL hasMoreData = YES;

        // 跳过注释行+表头行，计算总偏移量
        NSUInteger headerOffset = [self headerOffsetForFile:filePath];
        [fileHandle seekToFileOffset:headerOffset];

        while (hasMoreData && (self.config.maxRows == 0 || currentRow < self.config.maxRows)) {
            @autoreleasepool {
                line = [self readNextLineFromFile:fileHandle];
                if (!line || line.length == 0) {
                    hasMoreData = NO;
                    break;
                }

                // 解析数据行
                [self parseDataLine:line];

                currentRow++;

                // 进度回调（每100行或总行数的1%触发一次）
                if (progressHandler && (currentRow % 100 == 0 || currentRow % (totalRows / 100 + 1) == 0)) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progressHandler(currentRow, totalRows);
                    });
                }
            }
        }

        [fileHandle closeFile];

        // 构建结果对象
        PIDCSVData *result = [self buildResult];
        result.dataLength = currentRow;
        result.craftName = parsedCraftName;  // 🔧 传递 craftName

        // 🔧 传递 flightTime（从 # Flight time:XXX 微秒时间戳转换）
        if (parsedFlightTimeStr.length > 0) {
            int64_t flightTimeUs = [parsedFlightTimeStr longLongValue];
            if (flightTimeUs > 0) {
                result.flightTime = [NSDate dateWithTimeIntervalSince1970:flightTimeUs / 1000000.0];
            }
        }

        // 🔧 传递固件版本、PID配置和电机KV
        result.firmwareVersionCode = parsedFwVersion;
        result.currentPIDFromHeader = parsedPIDConfig;
        result.motorKV = parsedMotorKV;
        result.chainId = parsedChainId;
        result.chainIteration = parsedChainIteration;

        // 计算采样率
        if (result.timeUs.count > 1) {
            int64_t timeDiff = [result.timeUs[1] longLongValue] - [result.timeUs[0] longLongValue];
            result.sampleRate = timeDiff > 0 ? 1000000.0 / timeDiff : 8000.0;
        }

        NSLog(@"✅ CSV解析完成: %ld行, 采样率=%.0fHz", (long)currentRow, result.sampleRate);

        return result;

    } @catch (NSException *exception) {
        self.lastErrorMessage = [NSString stringWithFormat:@"解析异常: %@", exception.reason];
        NSLog(@"❌ parseCSV异常: %@", exception);
        return nil;
    }
}

#pragma mark - Private Methods - 数据缓存管理

- (void)resetDataCache {
    // 初始化所有字段的数组
    self.dataCache = [NSMutableDictionary dictionary];

    NSArray<NSString *> *requiredFields = [[self class] requiredFields];
    for (NSString *field in requiredFields) {
        self.dataCache[field] = [NSMutableArray array];
    }

    // 清空字段索引
    [self.fieldIndexes removeAllObjects];

    // 初始化读取缓冲区
    self.readBuffer = [NSMutableData data];
}

- (void)buildFieldIndexes:(NSArray<NSString *> *)headers {
    [self.fieldIndexes removeAllObjects];

    for (NSInteger i = 0; i < headers.count; i++) {
        NSString *header = headers[i];
        self.fieldIndexes[header] = @(i);

        if (self.verboseLogging) {
            NSLog(@"📋 字段[%ld] = %@", (long)i, header);
        }
    }
}

- (PIDCSVData *)buildResult {
    PIDCSVData *data = [[PIDCSVData alloc] init];

    // 使用KVC或直接方法调用来设置属性值
    // 时间字段 - 优先使用 "time"（真机格式），备用 "time (us)"（标准格式）
    data.timeUs = [self arrayFromFields:@[@"time", @"time (us)"]];

    // 🔧 调试日志：检查时间数据读取
    if (self.verboseLogging) {
        NSLog(@"🔍 timeUs读取结果: %lu个数据点", (unsigned long)data.timeUs.count);
        if (data.timeUs.count > 0) {
            NSLog(@"🔍 timeUs[0]=%@, timeUs[1]=%@", data.timeUs[0], data.timeUs.count > 1 ? data.timeUs[1] : @"N/A");
        }
        NSLog(@"🔍 dataCache中time字段数: %lu", (unsigned long)self.dataCache[@"time"].count);
        NSLog(@"🔍 dataCache中time (us)字段数: %lu", (unsigned long)self.dataCache[@"time (us)"].count);
    }

    // 转换为秒
    NSMutableArray<NSNumber *> *timeSeconds = [NSMutableArray arrayWithCapacity:data.timeUs.count];
    for (NSNumber *us in data.timeUs) {
        double seconds = [us doubleValue] * 1e-6;
        [timeSeconds addObject:@(seconds)];
    }
    data.timeSeconds = timeSeconds;

    if (self.verboseLogging && timeSeconds.count > 0) {
        NSLog(@"🔍 timeSeconds[0]=%@, timeSeconds[1]=%@", timeSeconds[0], timeSeconds.count > 1 ? timeSeconds[1] : @"N/A");
    }

    // 遥控命令
    data.rcCommand0 = [self arrayFromFields:@[@"rcCommand[0]"]];
    data.rcCommand1 = [self arrayFromFields:@[@"rcCommand[1]"]];
    data.rcCommand2 = [self arrayFromFields:@[@"rcCommand[2]"]];
    data.rcCommand3 = [self arrayFromFields:@[@"rcCommand[3]"]];

    // 油门是rcCommand[3]
    data.throttle = data.rcCommand3;

    // PID参数
    data.axisP0 = [self arrayFromFields:@[@"axisP[0]"]];
    data.axisP1 = [self arrayFromFields:@[@"axisP[1]"]];
    data.axisP2 = [self arrayFromFields:@[@"axisP[2]"]];

    data.axisI0 = [self arrayFromFields:@[@"axisI[0]"]];
    data.axisI1 = [self arrayFromFields:@[@"axisI[1]"]];
    data.axisI2 = [self arrayFromFields:@[@"axisI[2]"]];

    data.axisD0 = [self arrayFromFields:@[@"axisD[0]"]];
    data.axisD1 = [self arrayFromFields:@[@"axisD[1]"]];
    data.axisD2 = [self arrayFromFields:@[@"axisD[2]"]];

    // 陀螺仪数据
    data.gyroADC0 = [self arrayFromFields:@[@"gyroADC[0]"]];
    data.gyroADC1 = [self arrayFromFields:@[@"gyroADC[1]"]];
    data.gyroADC2 = [self arrayFromFields:@[@"gyroADC[2]"]];

    // Debug数据
    data.debug0 = [self arrayFromFields:@[@"debug[0]"]];
    data.debug1 = [self arrayFromFields:@[@"debug[1]"]];
    data.debug2 = [self arrayFromFields:@[@"debug[2]"]];
    data.debug3 = [self arrayFromFields:@[@"debug[3]"]];

    return data;
}

/**
 * 从缓存中获取数组
 * @param fields 源字段名列表
 * @return 数组副本
 */
- (NSArray<NSNumber *> *)arrayFromFields:(NSArray<NSString *> *)fields {
    for (NSString *field in fields) {
        NSMutableArray<NSNumber *> *cached = self.dataCache[field];
        if (cached && cached.count > 0) {
            // 检查数据是否有效（不只是全是NaN）
            BOOL hasValidData = NO;
            for (NSNumber *num in cached) {
                if (!isnan([num doubleValue])) {
                    hasValidData = YES;
                    break;
                }
            }
            if (hasValidData) {
                return [cached copy];
            }
        }
    }
    // 如果没有数据，返回空数组
    return @[];
}

#pragma mark - Private Methods - CSV解析

/**
 * 读取文件第一行
 */
- (nullable NSString *)readFirstLine:(NSString *)filePath error:(NSError **)error {
    return [self readFirstNonCommentLine:filePath error:error extractedCraftName:nil extractedFlightTime:nil extractedFwVersion:nil extractedPIDConfig:nil extractedMotorKV:nil extractedChainId:nil extractedChainIteration:nil];
}

/**
 * 读取文件第一个非注释行（跳过 # 开头的注释行）
 * @param filePath 文件路径
 * @param error 错误输出
 * @param craftName 输出 craftName（如果CSV头包含 `# Craft name:XXX`）
 * @param flightTimeStr 输出飞行时间字符串（如果CSV头包含 `# Flight time:XXX`）
 */
- (nullable NSString *)readFirstNonCommentLine:(NSString *)filePath
                                         error:(NSError **)error
                          extractedCraftName:(NSString **)craftName
                       extractedFlightTime:(NSString **)flightTimeStr
                   extractedFwVersion:(NSInteger *)fwVersionOut
                     extractedPIDConfig:(NSDictionary **)pidConfigOut
                        extractedMotorKV:(NSInteger *)motorKVOut
                          extractedChainId:(NSString **)chainIdOut
                    extractedChainIteration:(NSInteger *)chainIterationOut {
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData || fileData.length == 0) {
        return nil;
    }

    // 按行拆分，找第一个非注释行
    NSString *content = [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
    if (!content) return nil;

    // 用于收集PID配置
    NSMutableDictionary *pidConfig = [NSMutableDictionary dictionary];

    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;

        if ([trimmed hasPrefix:@"#"]) {
            // 注释行 — 提取元数据
            if ([trimmed hasPrefix:@"# Craft name:"] && craftName) {
                *craftName = [[trimmed substringFromIndex:13]
                              stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            }
            if ([trimmed hasPrefix:@"# Flight time:"] && flightTimeStr) {
                *flightTimeStr = [[trimmed substringFromIndex:14]
                                  stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
            }
            // 固件版本: # Firmware version:405
            if ([trimmed hasPrefix:@"# Firmware version:"] && fwVersionOut) {
                NSString *verStr = [[trimmed substringFromIndex:19]
                                   stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
                *fwVersionOut = [verStr integerValue];
            }
            // 电机KV: # Motor KV:2300
            if ([trimmed hasPrefix:@"# Motor KV:"] && motorKVOut) {
                NSString *kvStr = [[trimmed substringFromIndex:11]
                                  stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
                *motorKVOut = [kvStr integerValue];
            }
            // 迭代链标记: # Chain ID:uuid-string
            if ([trimmed hasPrefix:@"# Chain ID:"] && chainIdOut) {
                *chainIdOut = [[trimmed substringFromIndex:11]
                               stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            }
            // 迭代轮次: # Chain Iteration:2
            if ([trimmed hasPrefix:@"# Chain Iteration:"] && chainIterationOut) {
                NSString *iterStr = [[trimmed substringFromIndex:18]
                                    stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]];
                *chainIterationOut = [iterStr integerValue];
            }
            // PID配置: # PID roll:42,85,35,65 (p,i,d,ff)
            if ([trimmed hasPrefix:@"# PID "]) {
                NSString *pidLine = [trimmed substringFromIndex:6]; // "roll:42,85,35,65"
                NSRange colonRange = [pidLine rangeOfString:@":"];
                if (colonRange.location != NSNotFound) {
                    NSString *axis = [[pidLine substringToIndex:colonRange.location]
                                     stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceCharacterSet]];
                    NSString *values = [[pidLine substringFromIndex:colonRange.location + 1]
                                       stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceCharacterSet]];
                    NSArray<NSString *> *parts = [values componentsSeparatedByString:@","];
                    if (parts.count >= 4) {
                        pidConfig[axis] = @{
                            @"p": @([parts[0] doubleValue]),
                            @"i": @([parts[1] doubleValue]),
                            @"d": @([parts[2] doubleValue]),
                            @"ff": @([parts[3] doubleValue])
                        };
                    }
                }
            }
            continue;
        }

        // 找到第一个非注释、非空行 = 表头行
        // 传递收集的PID配置
        if (pidConfigOut && pidConfig.count > 0) {
            *pidConfigOut = [pidConfig copy];
        }
        return trimmed;
    }
    return nil;
}

/**
 * 计算从文件开头到数据行开始的字节偏移（跳过注释行+表头行）
 */
- (NSUInteger)headerOffsetForFile:(NSString *)filePath {
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData) return 0;

    NSString *content = [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
    if (!content) return 0;

    NSUInteger byteOffset = 0;
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];
        NSUInteger lineBytes = [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1; // +1 for \n
        byteOffset += lineBytes;

        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;  // 跳过空行和注释行
        }
        // 找到表头行，跳过它后返回偏移
        break;
    }
    return byteOffset;
}

/**
 * 从文件句柄读取下一行（支持跨缓冲区读取，使用缓冲区避免数据丢失）
 */
- (nullable NSString *)readNextLineFromFile:(NSFileHandle *)fileHandle {
    NSMutableData *lineData = [NSMutableData data];
    BOOL foundNewline = NO;

    // 先处理缓冲区中的剩余数据
    if (self.readBuffer.length > 0) {
        NSRange newlineRange = [self.readBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                                     options:0
                                                       range:NSMakeRange(0, self.readBuffer.length)];

        if (newlineRange.location != NSNotFound) {
            // 缓冲区中已有完整行
            [lineData appendData:[self.readBuffer subdataWithRange:NSMakeRange(0, newlineRange.location)]];

            // 保留剩余部分到缓冲区
            NSInteger remainingStart = newlineRange.location + 1; // +1 跳过换行符
            if (remainingStart < self.readBuffer.length) {
                NSData *remaining = [self.readBuffer subdataWithRange:NSMakeRange(remainingStart, self.readBuffer.length - remainingStart)];
                self.readBuffer = [NSMutableData dataWithData:remaining];
            } else {
                [self.readBuffer setLength:0];
            }

            if (lineData.length > 0) {
                return [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            }
        }
    }

    // 缓冲区没有完整行，需要读取新数据
    while (!foundNewline) {
        NSData *chunk = [fileHandle readDataOfLength:4096]; // 使用4KB块提高效率
        if (!chunk || chunk.length == 0) {
            // EOF，返回缓冲区剩余的所有数据
            if (self.readBuffer.length > 0) {
                [lineData appendData:self.readBuffer];
                [self.readBuffer setLength:0];
            } else if (lineData.length == 0) {
                return nil;
            }
            break;
        }

        // 将新数据追加到缓冲区
        [self.readBuffer appendData:chunk];

        // 在缓冲区中查找换行符
        NSRange newlineRange = [self.readBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                                     options:0
                                                       range:NSMakeRange(0, self.readBuffer.length)];

        if (newlineRange.location != NSNotFound) {
            // 找到完整行
            [lineData appendData:[self.readBuffer subdataWithRange:NSMakeRange(0, newlineRange.location)]];

            // 保留剩余部分到缓冲区
            NSInteger remainingStart = newlineRange.location + 1; // +1 跳过换行符
            if (remainingStart < self.readBuffer.length) {
                NSData *remaining = [self.readBuffer subdataWithRange:NSMakeRange(remainingStart, self.readBuffer.length - remainingStart)];
                self.readBuffer = [NSMutableData dataWithData:remaining];
            } else {
                [self.readBuffer setLength:0];
            }

            foundNewline = YES;
        } else {
            // 还没找到换行符，继续读取
            // 避免无限增长（防止恶意文件）
            if (self.readBuffer.length > 1024 * 1024) { // 1MB单行限制
                NSLog(@"⚠️ 单行数据超过1MB，强制截断");
                [lineData appendData:self.readBuffer];
                [self.readBuffer setLength:0];
                break;
            }
        }
    }

    if (lineData.length == 0) {
        return nil;
    }

    return [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
}

/**
 * 解析CSV行（处理逗号分隔）
 * 简化版本：不处理引号包裹的字段
 */
- (NSArray<NSString *> *)parseCSVLine:(NSString *)line {
    if (!line || line.length == 0) {
        return @[];
    }

    // 简单的逗号分割（适用于当前CSV格式）
    NSArray<NSString *> *components = [line componentsSeparatedByString:@","];

    // 去除首尾空白
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:components.count];
    for (NSString *component in components) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [result addObject:trimmed];
    }

    return result;
}

/**
 * 解析数据行并填充缓存
 */
- (void)parseDataLine:(NSString *)line {
    NSArray<NSString *> *values = [self parseCSVLine:line];

    NSArray<NSString *> *requiredFields = [[self class] requiredFields];
    for (NSString *field in requiredFields) {
        NSNumber *indexNum = self.fieldIndexes[field];
        if (!indexNum) {
            // 字段不存在，填入NaN
            [self addValue:@(NAN) forField:field];
            continue;
        }

        NSInteger index = [indexNum integerValue];
        if (index >= values.count) {
            [self addValue:@(NAN) forField:field];
            continue;
        }

        NSString *valueStr = values[index];
        if (valueStr.length == 0) {
            // 空值
            if (self.config.skipEmptyValues) {
                [self addValue:@(NAN) forField:field];
            } else {
                [self addValue:@0 forField:field];
            }
        } else {
            double value = [valueStr doubleValue];
            [self addValue:@(value) forField:field];
        }
    }
}

/**
 * 添加值到缓存
 */
- (void)addValue:(NSNumber *)value forField:(NSString *)field {
    NSMutableArray<NSNumber *> *array = self.dataCache[field];
    if (!array) {
        array = [NSMutableArray array];
        self.dataCache[field] = array;
    }
    [array addObject:value];
}

@end
