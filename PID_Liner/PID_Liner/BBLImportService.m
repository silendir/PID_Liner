//
//  BBLImportService.m
//  PID_Liner
//
//  BBL → CSV 统一导入管线实现 (任务#28 阶段0.4b)
//

#import "BBLImportService.h"
#import "BlackboxDecoder.h"

NSString * const BBLImportErrorDomain = @"BBLImportErrorDomain";

typedef NS_ENUM(NSInteger, BBLImportErrorCode) {
    BBLImportErrorCodeFileNotFound   = 1,
    BBLImportErrorCodeNoSessions     = 2,
    BBLImportErrorCodeDecodeFailed   = 3,
    BBLImportErrorCodeCSVNotFound    = 4,  // decode 成功但找不到产物
};

#pragma mark - BBLImportCSVResult

@implementation BBLImportCSVResult

- (BOOL)isSuccess {
    return self.csvPath.length > 0 && self.errorMessage.length == 0;
}

@end

#pragma mark - BBLImportService

@implementation BBLImportService

+ (instancetype)shared {
    static BBLImportService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BBLImportService alloc] init];
    });
    return instance;
}

+ (NSString *)documentsDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

+ (BOOL)hasAnyCSVRecord {
    return [self latestCSVInDocuments] != nil;
}

+ (nullable NSString *)latestCSVInDocuments {
    NSString *docs = [self documentsDirectory];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil];
    NSString *latest = nil;
    NSDate *latestDate = nil;
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"csv"]) continue;
        NSString *p = [docs stringByAppendingPathComponent:f];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        NSDate *mod = attrs[NSFileModificationDate];
        if (mod && (!latestDate || [mod compare:latestDate] == NSOrderedDescending)) {
            latestDate = mod;
            latest = p;
        }
    }
    return latest;
}

#pragma mark - 示例数据(空态兜底)

/// 加入示例 BBL(空态统一入口):copy bundle 001.bbl → 沙盒 → 转 CSV(注入元数据)
+ (void)loadDemoBBLWithCompletion:(void(^)(NSString *_Nullable csvPath, NSError *_Nullable error))completion {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"001" ofType:@"bbl"];
    if (!bundlePath) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:BBLImportErrorDomain code:0
                                              userInfo:@{NSLocalizedDescriptionKey: @"bundle 内找不到 001.bbl"}]);
            });
        }
        return;
    }

    NSString *docs = [self documentsDirectory];
    NSString *destBBL = [docs stringByAppendingPathComponent:@"001.bbl"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:destBBL]) {
        [fm removeItemAtPath:destBBL error:nil];
    }
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:bundlePath toPath:destBBL error:&copyErr]) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, copyErr); });
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *convErr = nil;
        NSString *csvPath = [[BBLImportService shared] convertBBL:destBBL
                                                          logIndex:0
                                                           motorKV:nil
                                                             error:&convErr];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(csvPath, convErr);
        });
    });
}

#pragma mark - 列出 Session

- (nullable NSArray<BBLSessionInfo *> *)listSessionsForBBL:(NSString *)bblPath error:(NSError **)error {
    if (![self bblExists:bblPath error:error]) return nil;

    BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
    NSArray<BBLSessionInfo *> *sessions = [decoder listLogs:bblPath];
    if (sessions.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:BBLImportErrorDomain
                                         code:BBLImportErrorCodeNoSessions
                                     userInfo:@{NSLocalizedDescriptionKey: @"BBL 内无可用 Session"}];
        }
        return nil;
    }
    return sessions;
}

#pragma mark - 转换单个 Session

/// 转换单个 Session:decode → 重命名标准名 → 注入元数据
- (nullable NSString *)convertBBL:(NSString *)bblPath
                         logIndex:(int)logIndex
                          motorKV:(nullable NSString *)motorKV
                            error:(NSError **)error {
    if (![self bblExists:bblPath error:error]) return nil;

    NSString *outputDir = [BBLImportService documentsDirectory];
    NSString *baseName = [[bblPath lastPathComponent] stringByDeletingPathExtension];

    BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
    decoder.outputDirectory = outputDir;

    // 先 listLogs 拿到该 Session 的 header(用于注入元数据;decode 后 header 也填充,但 list 更稳妥)
    NSArray<BBLSessionInfo *> *sessions = [decoder listLogs:bblPath];
    BBLSessionInfo *targetSession = nil;
    for (BBLSessionInfo *s in sessions) {
        if (s.logIndex == logIndex) { targetSession = s; break; }
    }
    if (!targetSession) {
        if (error) {
            *error = [NSError errorWithDomain:BBLImportErrorDomain
                                         code:BBLImportErrorCodeNoSessions
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"找不到 logIndex=%d 的 Session", logIndex]}];
        }
        return nil;
    }

    // 解码(生成 {basename}.{logIndex+1}.csv 到 outputDir)
    int result = [decoder decodeFlightLog:bblPath logIndex:logIndex];
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:BBLImportErrorDomain
                                         code:BBLImportErrorCodeDecodeFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                     decoder.lastErrorMessage ?: @"解码失败"}];
        }
        return nil;
    }

    // 定位 decode 产物
    NSString *origName = [NSString stringWithFormat:@"%@.%02d.csv", baseName, logIndex + 1];
    NSString *origPath = [outputDir stringByAppendingPathComponent:origName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:origPath]) {
        if (error) {
            *error = [NSError errorWithDomain:BBLImportErrorDomain
                                         code:BBLImportErrorCodeCSVNotFound
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"解码成功但找不到产物 %@", origName]}];
        }
        return nil;
    }

    // 重命名为标准 {源}_{时间戳}_session{N}.csv(与 ViewController/CSVHistory 命名一致)
    NSString *ts = [self timestampString];
    NSString *csvName = [NSString stringWithFormat:@"%@_%@_session%d.csv", baseName, ts, logIndex + 1];
    NSString *csvPath = [outputDir stringByAppendingPathComponent:csvName];
    if ([fm fileExistsAtPath:csvPath]) {
        [fm removeItemAtPath:csvPath error:nil];
    }
    NSError *mvErr = nil;
    if (![fm moveItemAtPath:origPath toPath:csvPath error:&mvErr]) {
        // 重命名失败:降级用原文件名(不阻断,与现有行为一致)
        NSLog(@"⚠️ [BBLImport] 重命名失败,保留原名: %@", mvErr.localizedDescription);
        csvPath = origPath;
    }

    // 注入元数据注释行(craftName/fw/PID/flightTime + 可选 motorKV)
    [self injectMetadataIntoCSV:csvPath header:targetSession.header motorKV:motorKV];

    return csvPath;
}

#pragma mark - 批量转换

- (NSArray<BBLImportCSVResult *> *)convertAllSessionsForBBL:(NSString *)bblPath
                                                    motorKV:(nullable NSString *)motorKV
                                                   progress:(nullable void(^)(NSInteger, NSInteger))progress
                                                      error:(NSError **)error {
    NSArray<BBLSessionInfo *> *sessions = [self listSessionsForBBL:bblPath error:error];
    if (!sessions) return @[];

    NSInteger total = sessions.count;
    NSMutableArray<BBLImportCSVResult *> *results = [NSMutableArray arrayWithCapacity:total];

    for (NSInteger i = 0; i < total; i++) {
        BBLSessionInfo *session = sessions[i];
        BBLImportCSVResult *r = [[BBLImportCSVResult alloc] init];
        r.logIndex = session.logIndex;
        r.sessionDescription = session.sessionDescription;

        NSError *e = nil;
        NSString *csv = [self convertBBL:bblPath logIndex:session.logIndex motorKV:motorKV error:&e];
        if (csv) {
            r.csvPath = csv;
        } else {
            r.errorMessage = e.localizedDescription ?: @"未知错误";
            NSLog(@"❌ [BBLImport] Session logIndex=%d 转换失败: %@", session.logIndex, r.errorMessage);
        }
        [results addObject:r];

        if (progress) {
            progress(i + 1, total);
        }
    }
    return [results copy];
}

#pragma mark - 私有辅助

/// 校验 BBL 文件存在(不存在则填 error 返回 NO)
- (BOOL)bblExists:(NSString *)bblPath error:(NSError **)error {
    if (bblPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:bblPath]) {
        if (error) {
            *error = [NSError errorWithDomain:BBLImportErrorDomain
                                         code:BBLImportErrorCodeFileNotFound
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                     [NSString stringWithFormat:@"BBL 文件不存在: %@", bblPath]}];
        }
        return NO;
    }
    return YES;
}

/// 时间戳 yyyyMMdd_HHmmss(统一 CSV 命名)
- (NSString *)timestampString {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}

/// 向 CSV 头部注入 BBL 元数据注释行(供 PIDCSVParser 解析)
/// 顺序:craftName → flightTime → firmware → PID(roll/pitch/yaw) → motorKV(可选)
- (void)injectMetadataIntoCSV:(NSString *)csvPath
                       header:(BBLLogHeader *)header
                      motorKV:(nullable NSString *)motorKV {
    if (!csvPath || !header) return;

    NSError *readErr = nil;
    NSString *content = [NSString stringWithContentsOfFile:csvPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&readErr];
    if (readErr || !content) {
        NSLog(@"⚠️ [BBLImport] 读取 CSV 失败(跳过注入): %@", readErr.localizedDescription);
        return;
    }

    NSMutableString *prefix = [NSMutableString string];

    // craftName
    if (header.craftName.length > 0) {
        [prefix appendFormat:@"# Craft name:%@\n", header.craftName];
    }
    // flightTime(微秒)
    if (header.startDatetimeUs > 0) {
        [prefix appendFormat:@"# Flight time:%lld\n", header.startDatetimeUs];
    }
    // firmware version code(405=BF4.5)
    NSInteger fw = header.firmwareVersionCode;
    if (fw > 0) {
        [prefix appendFormat:@"# Firmware version:%ld\n", (long)fw];
    }
    // PID roll/pitch/yaw(p,i,d,ff)
    NSDictionary *pidValues = header.currentPIDValues;
    for (NSString *axis in @[@"roll", @"pitch", @"yaw"]) {
        NSDictionary *axisPID = pidValues[axis];
        if (![axisPID isKindOfClass:[NSDictionary class]]) continue;
        int p = [axisPID[@"p"] intValue];
        int i = [axisPID[@"i"] intValue];
        int d = [axisPID[@"d"] intValue];
        int ff = [axisPID[@"ff"] intValue];
        if (p > 0 || i > 0 || d > 0 || ff > 0) {
            [prefix appendFormat:@"# PID %@:%d,%d,%d,%d\n", axis, p, i, d, ff];
        }
    }
    // motorKV(可选)
    if (motorKV.length > 0) {
        [prefix appendFormat:@"# Motor KV:%@\n", motorKV];
    }

    if (prefix.length == 0) return;

    NSString *newContent = [prefix stringByAppendingString:content];
    NSError *writeErr = nil;
    if (![newContent writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        NSLog(@"⚠️ [BBLImport] 注入元数据写入失败: %@", writeErr.localizedDescription);
    }
}

@end
