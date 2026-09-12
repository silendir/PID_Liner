//
//  DataflashDownloader.m — 蓝牙直下黑盒分块下载
//

#import "DataflashDownloader.h"
#import "FCBluetoothService.h"
#import "MSPClient.h"

/// 每块字节数(BF 配置器同款;固件按自身缓冲上限裁剪,以回帧 dataSize 为准)
static const uint16_t kChunkSize = 4096;
/// 每块失败自动重试次数(蓝牙桥偶发丢包,8MB 全程不能因一次抖动全废)
static const NSUInteger kChunkRetries = 1;

static uint32_t ReadLE32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static uint16_t ReadLE16(const uint8_t *b)
{
    return (uint16_t)(b[0] | (b[1] << 8));
}

@interface DataflashDownloader ()
@property (nonatomic, strong) FCBluetoothService *service;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) uint32_t address;     // 已下载到的闪存地址
@property (nonatomic, assign) uint32_t usedSize;    // 闪存已用字节(下载总量)
@property (nonatomic, strong) NSMutableData *acc;
@property (nonatomic, assign) NSUInteger retriesLeft;
@property (nonatomic, copy) void(^progressBlock)(double, NSString *);
@property (nonatomic, copy) void(^completionBlock)(NSURL *, NSString *);
@end

@implementation DataflashDownloader

- (instancetype)initWithService:(FCBluetoothService *)service
{
    self = [super init];
    if (self) _service = service;
    return self;
}

#pragma mark - 对外

- (void)startWithProgress:(void(^)(double fraction, NSString *text))progress
               completion:(void(^)(NSURL *_Nullable, NSString *_Nullable))completion
{
    self.running = YES;
    self.cancelled = NO;
    self.progressBlock = progress;
    self.completionBlock = completion;

    // 第 1 步:数据闪存汇总(小帧,v1 即可)
    __weak typeof(self) weakSelf = self;
    [self.service sendCommand:MSPCommandDataflashSummary payload:[NSData data] reply:^(NSData *p, NSString *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.cancelled) return;
        if (err) return [self fail:err];
        if (p.length < 13) return [self fail:@"数据闪存信息帧异常"];

        const uint8_t *b = p.bytes;
        uint8_t flags = b[0];
        uint32_t usedSize = ReadLE32(b + 9);
        if (!(flags & 0x02)) return [self fail:@"飞控没有 dataflash 黑盒"];
        if (!(flags & 0x01)) return [self fail:@"dataflash 尚未就绪"];
        if (usedSize == 0)   return [self fail:@"飞控闪存里没有黑盒数据"];

        s.usedSize = usedSize;
        s.address = 0;
        s.acc = [NSMutableData dataWithCapacity:usedSize];
        [s fetchNextChunk];
    }];
}

- (void)cancel
{
    if (!self.running) return;
    self.cancelled = YES;
    [self finishWithURL:nil error:@"已取消"];
}

#pragma mark - 下载循环

/// 串行取下一块(一问一答,上一块确认后才发下一块)
- (void)fetchNextChunk
{
    if (self.cancelled) return;
    if (self.address >= self.usedSize) return [self finishDownload];

    double fraction = (double)self.address / self.usedSize;
    if (self.progressBlock) {
        self.progressBlock(fraction, [NSString stringWithFormat:
            @"📡 蓝牙下载中 %.0f%%(%lu/%lu KB)",
            fraction * 100, (unsigned long)(self.address / 1024), (unsigned long)(self.usedSize / 1024)]);
    }

    // 请求:[地址u32LE][块大小u16LE][允许压缩=0]
    // 压缩=1 固件回哈夫曼数据(BF 配置器为慢串口优化);BLE 直下要原始字节,免实现解码器
    uint8_t req[7] = {
        (uint8_t)(self.address & 0xff), (uint8_t)(self.address >> 8),
        (uint8_t)(self.address >> 16), (uint8_t)(self.address >> 24),
        (uint8_t)(kChunkSize & 0xff), (uint8_t)(kChunkSize >> 8), 0
    };
    self.retriesLeft = kChunkRetries;

    __weak typeof(self) weakSelf = self;
    [self.service sendV2Command:MSPCommandDataflashRead payload:[NSData dataWithBytes:req length:7]
                          reply:^(NSData *p, NSString *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.cancelled) return;
        if (err) {
            // 蓝牙桥偶发丢包:当前块重试一次再放弃
            if (s.retriesLeft > 0) {
                s.retriesLeft--;
                NSLog(@"[BLE] 块 @%u 失败(%@),重试", s.address, err);
                [s fetchNextChunk];
                return;
            }
            return [self fail:[NSString stringWithFormat:@"下载中断:%@", err]];
        }
        // 响应:[地址回显u32][数据量u16][压缩类型u8][数据…]
        if (p.length < 7) return [self fail:@"数据块帧异常"];
        const uint8_t *b = p.bytes;
        uint32_t echoAddr = ReadLE32(b);
        uint16_t dataSize = ReadLE16(b + 4);
        uint8_t compression = b[6];
        // 地址错位=串行流里有旧回包插队,重发当前块即可(配置器同款:当作失败走重试)
        if (echoAddr != s.address || compression != 0 ||
            p.length < (NSUInteger)(7 + dataSize) ||
            (dataSize == 0 && s.address < s.usedSize)) {
            if (s.retriesLeft > 0) {
                s.retriesLeft--;
                NSLog(@"[BLE] 块 @%u 异常回包(地址/压缩/长度),重试", s.address);
                [s fetchNextChunk];
                return;
            }
            return [self fail:@"下载中断:数据块异常且重试已用尽"];
        }

        [s.acc appendBytes:b + 7 length:dataSize];
        s.address += dataSize;
        [s fetchNextChunk];
    }];
}

/// 全部块到位 → 落盘 Documents
- (void)finishDownload
{
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"ble_%@.bbl", [fmt stringFromDate:[NSDate date]]];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [docs stringByAppendingPathComponent:fileName];

    NSError *error = nil;
    if (![self.acc writeToFile:path options:NSDataWritingAtomic error:&error]) {
        return [self fail:error.localizedDescription ?: @"保存文件失败"];
    }
    NSLog(@"[BLE] ✅ 下载完成 %@(%lu 字节)", fileName, (unsigned long)self.acc.length);
    [self finishWithURL:[NSURL fileURLWithPath:path] error:nil];
}

- (void)fail:(NSString *)message
{
    [self finishWithURL:nil error:message];
}

- (void)finishWithURL:(NSURL *)fileURL error:(NSString *)errorMessage
{
    if (!self.running) return;
    self.running = NO;
    void(^block)(NSURL *, NSString *) = self.completionBlock;
    self.completionBlock = nil;
    self.progressBlock = nil;
    if (block) block(fileURL, errorMessage);
}

@end
