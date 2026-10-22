//
//  CSVBBLGroupingTests.m
//  PID_LinerTests
//
//  CSV 列表页两项逻辑的单元测试(全部用临时目录与内存记录,不碰生产 Documents/bundle):
//  1. 存储前重名防御:同名 BBL 落盘自动加序号(吴总→吴总1→吴总2),保留两者
//  2. BBL 批次分组:改名后的批次(吴总1)与前一批(吴总)各自成组,不串组
//

#import <XCTest/XCTest.h>
#import "BBLImportService.h"
#import "CSVHistoryViewController.h"

@interface CSVBBLGroupingTests : XCTestCase
@property (nonatomic, copy) NSString *tempDir;
@end

@implementation CSVBBLGroupingTests

- (void)setUp {
    [super setUp];
    _tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"CSVGroupingTests_%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:_tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:_tempDir error:nil];
    [super tearDown];
}

/// 在临时目录种一个指定名文件(空内容即可,查重只看存在性)
- (void)plantFileNamed:(NSString *)name {
    [@"" writeToFile:[_tempDir stringByAppendingPathComponent:name]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 重名防御(吴总 → 吴总1 → 吴总2)

- (void)test无重名时保持原名 {
    NSString *r = [BBLImportService uniqueBaseName:@"吴总" extension:@"bbl" inDirectory:_tempDir];
    XCTAssertTrue([r isEqualToString:@"吴总"], @"无重名应保持原名,实际:%@", r);
}

- (void)test同名第二次加序号1 {
    [self plantFileNamed:@"吴总.bbl"];
    NSString *r = [BBLImportService uniqueBaseName:@"吴总" extension:@"bbl" inDirectory:_tempDir];
    XCTAssertTrue([r isEqualToString:@"吴总1"], @"第二次导入应为 吴总1,实际:%@", r);
}

- (void)test同名第三次加序号2 {
    [self plantFileNamed:@"吴总.bbl"];
    [self plantFileNamed:@"吴总1.bbl"];
    NSString *r = [BBLImportService uniqueBaseName:@"吴总" extension:@"bbl" inDirectory:_tempDir];
    XCTAssertTrue([r isEqualToString:@"吴总2"], @"第三次导入应为 吴总2,实际:%@", r);
}

- (void)test不同扩展名不参与查重 {
    // 已有 吴总.csv(转换产物)不影响新 吴总.bbl 落盘
    [self plantFileNamed:@"吴总.csv"];
    NSString *r = [BBLImportService uniqueBaseName:@"吴总" extension:@"bbl" inDirectory:_tempDir];
    XCTAssertTrue([r isEqualToString:@"吴总"], @"不同扩展名不应触发查重,实际:%@", r);
}

#pragma mark - BBL 批次分组(含改名后场景)

- (CSVRecord *)record:(NSString *)fileName sourceBBL:(NSString *)bbl session:(NSInteger)session {
    CSVRecord *r = [[CSVRecord alloc] initWithFileName:fileName
                                              filePath:[@"/tmp" stringByAppendingPathComponent:fileName]
                                             sourceBBL:bbl
                                          sessionIndex:session];
    r.fileSize = 1024;
    r.lineCount = 100;
    return r;
}

- (void)test同一BBL的多个Session聚为一组 {
    // 同一次转换:前缀相同(含转换时间戳) → 一组
    NSArray<CSVRecord *> *records = @[
        [self record:@"吴总_20261022_100000_session1.csv" sourceBBL:@"吴总_20261022_100000" session:1],
        [self record:@"吴总_20261022_100000_session2.csv" sourceBBL:@"吴总_20261022_100000" session:2],
    ];
    NSArray<CSVRecordGroup *> *groups = [CSVHistoryViewController groupsFromRecords:records];
    XCTAssertEqual(groups.count, 1u, @"同批应聚为一组");
    XCTAssertEqual(groups.firstObject.childRecords.count, 1u, @"2 个 Session = 父行 + 1 子行");
    XCTAssertEqual(groups.firstObject.parentRecord.sessionIndex, 1, "父行 = 最小 sessionIndex");
}

- (void)test改名后的批次独立成组不串组 {
    // 吴总.bbl 重名 → 落盘为 吴总1.bbl → 转换前缀带 吴总1 → 与原 吴总 组互不串
    NSArray<CSVRecord *> *records = @[
        [self record:@"吴总_20261022_100000_session1.csv" sourceBBL:@"吴总_20261022_100000" session:1],
        [self record:@"吴总1_20261022_113000_session1.csv" sourceBBL:@"吴总1_20261022_113000" session:1],
    ];
    NSArray<CSVRecordGroup *> *groups = [CSVHistoryViewController groupsFromRecords:records];
    XCTAssertEqual(groups.count, 2u, @"改名批次应独立成组,实际:%lu", (unsigned long)groups.count);
}

- (void)testheader里的SourceBBL优先于文件名前缀 {
    // 新管线:文件头写了 "# Source BBL:吴总1",即便文件名仍是旧前缀,也按 header 分组
    NSArray<CSVRecord *> *records = @[
        [self record:@"legacy_prefix_session1.csv" sourceBBL:@"吴总1" session:1],
        [self record:@"吴总_20261022_100000_session1.csv" sourceBBL:@"吴总" session:1],
    ];
    NSArray<CSVRecordGroup *> *groups = [CSVHistoryViewController groupsFromRecords:records];
    XCTAssertEqual(groups.count, 2u, @"header 身份与旧前缀各成一组");
    BOOL hasWu1 = NO, hasWu = NO;
    for (CSVRecordGroup *g in groups) {
        if ([g.groupKey isEqualToString:@"吴总1"]) hasWu1 = YES;
        if ([g.groupKey isEqualToString:@"吴总"]) hasWu = YES;
    }
    XCTAssertTrue(hasWu1 && hasWu, "组键应为 header 提供的批次身份");
}

- (void)test组按父记录创建时间倒序 {
    CSVRecord *old = [self record:@"old_session1.csv" sourceBBL:@"old" session:1];
    old.createTime = [NSDate dateWithTimeIntervalSinceNow:-86400];
    CSVRecord *newer = [self record:@"new_session1.csv" sourceBBL:@"new" session:1];
    newer.createTime = [NSDate date];
    NSArray<CSVRecordGroup *> *groups = [CSVHistoryViewController groupsFromRecords:@[old, newer]];
    XCTAssertEqualObjects(groups.firstObject.groupKey, @"new", @"最新转换的组应排最前");
}

#pragma mark - 时间戳剥离(真机实锤:逐 Session 解码跨秒导致前缀裂开)

- (void)test同一BBL跨秒转换的前缀聚为一组 {
    // 25mini.BBL 真机案例:5 个 Session 解码时刻 121050~121053,前缀裂成 4 个
    // 扫描层剥掉尾部时间戳后,5 个 Session 应回到「25mini」一组
    NSArray<CSVRecord *> *records = @[
        [self record:@"25mini_20261014_121050_session2.csv" sourceBBL:@"25mini" session:2],
        [self record:@"25mini_20261014_121051_session3.csv" sourceBBL:@"25mini" session:3],
        [self record:@"25mini_20261014_121052_session4.csv" sourceBBL:@"25mini" session:4],
        [self record:@"25mini_20261014_121052_session5.csv" sourceBBL:@"25mini" session:5],
        [self record:@"25mini_20261014_121053_session6.csv" sourceBBL:@"25mini" session:6],
    ];
    NSArray<CSVRecordGroup *> *groups = [CSVHistoryViewController groupsFromRecords:records];
    XCTAssertEqual(groups.count, 1u, @"同一 BBL 跨秒转换应聚为一组,实际 %lu 组", (unsigned long)groups.count);
    XCTAssertEqual(groups.firstObject.childRecords.count + 1, 5u, @"组内应含全部 5 个 Session");
    XCTAssertEqualObjects(groups.firstObject.groupKey, @"25mini", "组键 = BBL 本名(无时间戳)");
}

- (void)test时间戳剥离正则 {
    XCTAssertEqualObjects([CSVHistoryViewController bblIdentityFromBaseName:@"吴2.5单独_20261018_143107"], @"吴2.5单独");
    XCTAssertEqualObjects([CSVHistoryViewController bblIdentityFromBaseName:@"25mini_20261014_121053"], @"25mini");
    XCTAssertEqualObjects([CSVHistoryViewController bblIdentityFromBaseName:@"测试机_BETAFPVG473__20261022_150000"], @"测试机_BETAFPVG473", @"BBL 本名自带的下划线也裁掉");
    XCTAssertEqualObjects([CSVHistoryViewController bblIdentityFromBaseName:@"吴25第二轮"], @"吴25第二轮", @"无时间戳则原样返回");
}

@end
