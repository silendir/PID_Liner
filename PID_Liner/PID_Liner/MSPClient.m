//
//  MSPClient.m — MSP v1 帧编解码 + 字节流状态机
//

#import "MSPClient.h"

// v1 帧固定头
static const uint8_t kMSPDollar = 0x24;  // '$'
static const uint8_t kMSPV1     = 0x4D;  // 'M'
static const uint8_t kMSPDirOut = 0x3C;  // '<' 请求
static const uint8_t kMSPDirIn  = 0x3E;  // '>' 响应

// 状态机状态(按 v1 帧字段顺序推进)
typedef NS_ENUM(NSUInteger, MSPParseState) {
    MSPParseStateIdle      = 0,  // 等待 '$'
    MSPParseStateProtoVer  = 1,  // 等待 'M'
    MSPParseStateDirection = 2,  // 等待 '>'
    MSPParseStateLength    = 3,  // 读 payload 长度
    MSPParseStateCommand   = 4,  // 读命令码
    MSPParseStatePayload   = 5,  // 收 payload
    MSPParseStateChecksum  = 6,  // 读校验并校验
};

@interface MSPClient ()
@property (nonatomic, assign) MSPParseState state;
@property (nonatomic, assign) uint8_t cmd;
@property (nonatomic, assign) uint8_t crc;          // 运行中的异或校验
@property (nonatomic, assign) uint8_t payloadLen;   // Length 阶段读到的长度
@property (nonatomic, assign) uint8_t received;     // 已收 payload 字节数
@property (nonatomic, strong) NSMutableData *payload;
@end

@implementation MSPClient

+ (NSData *)v1RequestWithCmd:(uint8_t)cmd payload:(NSData *)payload
{
    const uint8_t *bytes = payload.bytes;
    uint8_t size = (uint8_t)payload.length;
    uint8_t crc = (uint8_t)(size ^ cmd);
    for (NSUInteger i = 0; i < payload.length; i++)
        crc ^= bytes[i];

    NSMutableData *frame = [NSMutableData dataWithCapacity:5 + payload.length];
    uint8_t header[5] = {kMSPDollar, kMSPV1, kMSPDirOut, size, cmd};
    [frame appendBytes:header length:5];
    [frame appendData:payload];
    [frame appendBytes:&crc length:1];
    return frame;
}

- (instancetype)init
{
    self = [super init];
    if (self) [self reset];
    return self;
}

- (void)reset
{
    _state = MSPParseStateIdle;
    _payload = [NSMutableData data];
    _received = 0;
    _payloadLen = 0;
}

- (void)feedData:(NSData *)data onFrame:(MSPFrameHandler)onFrame
{
    if (!data.length || !onFrame)
        return;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [self consumeByte:bytes[i] onFrame:onFrame];
    }
}

/// 单字节推进状态机(帧跨 BLE 包时的粘包/断包都天然处理)
- (void)consumeByte:(uint8_t)b onFrame:(MSPFrameHandler)onFrame
{
    switch (_state) {
        case MSPParseStateIdle:
            if (b == kMSPDollar)
                _state = MSPParseStateProtoVer;
            break;

        case MSPParseStateProtoVer:
            _state = (b == kMSPV1) ? MSPParseStateDirection : MSPParseStateIdle;
            break;

        case MSPParseStateDirection:
            _state = (b == kMSPDirIn) ? MSPParseStateLength : MSPParseStateIdle;
            break;

        case MSPParseStateLength:
            _payloadLen = b;
            _crc = b;
            _received = 0;
            [_payload setLength:0];
            _state = (_payloadLen == 0) ? MSPParseStateChecksum : MSPParseStateCommand;
            break;

        case MSPParseStateCommand:
            _crc ^= b;
            _cmd = b;
            _state = MSPParseStatePayload;
            break;

        case MSPParseStatePayload:
            _crc ^= b;
            [_payload appendBytes:&b length:1];
            _received++;
            if (_received >= _payloadLen)
                _state = MSPParseStateChecksum;
            break;

        case MSPParseStateChecksum:
            if (b == _crc)
                onFrame(_cmd, [_payload copy]);
            // 校验失败静默丢弃(MSC 单命令场景,重发由上层超时兜底)
            [self reset];
            break;
    }
}

@end
