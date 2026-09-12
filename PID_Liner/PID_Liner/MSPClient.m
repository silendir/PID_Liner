//
//  MSPClient.m — MSP v1/v2 帧编解码 + 字节流状态机
//
//  v1(小命令): $ M < size cmd payload crc8(XOR)
//  v2(大 payload): $ X < flag cmdLE16 lenLE16 payload crc8_dvb_s2
//  两版响应帧分别以 'M'/'X' 区分,解码器自动识别(帧可跨 BLE 包,流式重组)。
//  v2 格式照 BF 配置器 msp.js encode_message_v2 / CHECKSUM_V2 状态机实现。
//

#import "MSPClient.h"

static const uint8_t kMSPDollar = 0x24;  // '$'
static const uint8_t kMSPProtoV1 = 0x4D; // 'M'
static const uint8_t kMSPProtoV2 = 0x58; // 'X'
static const uint8_t kMSPDirOut  = 0x3C; // '<' 请求
static const uint8_t kMSPDirIn   = 0x3E; // '>' 响应
static const uint8_t kMSPDirUnsup = 0x21; // '!' 命令不支持(响应空 payload)

/// crc8_dvb_s2(BF MSPv2 校验,多项式 0xD5,初值 0)
static uint8_t CRC8DvbS2(uint8_t crc, uint8_t byte)
{
    crc ^= byte;
    for (int i = 0; i < 8; i++)
        crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0xD5) : (uint8_t)(crc << 1);
    return crc;
}

// 状态机状态(按各版本帧字段顺序推进)
typedef NS_ENUM(NSUInteger, MSPParseState) {
    MSPParseStateIdle        = 0,  // 等待 '$'
    MSPParseStateProto       = 1,  // 'M'=v1 / 'X'=v2
    // v1 路径
    MSPParseStateV1Direction = 2,
    MSPParseStateV1Length    = 3,
    MSPParseStateV1Command   = 4,
    MSPParseStateV1Payload   = 5,
    MSPParseStateV1Checksum  = 6,
    // v2 路径
    MSPParseStateV2Direction = 7,
    MSPParseStateV2Flag      = 8,
    MSPParseStateV2CmdLo     = 9,
    MSPParseStateV2CmdHi     = 10,
    MSPParseStateV2LenLo     = 11,
    MSPParseStateV2LenHi     = 12,
    MSPParseStateV2Payload   = 13,
    MSPParseStateV2Checksum  = 14,
};

@interface MSPClient ()
@property (nonatomic, assign) MSPParseState state;
@property (nonatomic, assign) BOOL v2Unsupported;    // v2 '!' 方向:命令不被固件支持
@property (nonatomic, assign) uint16_t rxCmd;        // 收到的命令码(不可用 _cmd:与 ObjC 隐式 SEL 参数撞名)
@property (nonatomic, assign) uint8_t crc;           // 运行中的校验(v1 XOR / v2 dvb_s2)
@property (nonatomic, assign) uint16_t payloadLen;   // Length 阶段读到的长度(v2 为 16 位)
@property (nonatomic, assign) uint16_t received;     // 已收 payload 字节数
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
    uint8_t header[5] = {kMSPDollar, kMSPProtoV1, kMSPDirOut, size, cmd};
    [frame appendBytes:header length:5];
    [frame appendData:payload];
    [frame appendBytes:&crc length:1];
    return frame;
}

+ (NSData *)v2RequestWithCmd:(uint16_t)cmd payload:(NSData *)payload
{
    uint16_t len = (uint16_t)payload.length;
    NSMutableData *frame = [NSMutableData dataWithCapacity:9 + payload.length];
    uint8_t header[8] = {kMSPDollar, kMSPProtoV2, kMSPDirOut, 0x00,  // flag 恒 0
                         (uint8_t)(cmd & 0xff), (uint8_t)(cmd >> 8),
                         (uint8_t)(len & 0xff), (uint8_t)(len >> 8)};
    [frame appendBytes:header length:8];
    [frame appendData:payload];
    // crc 覆盖 flag 起到 payload 末尾(msp.js: crc8_dvb_s2_data(buf, 3, size-1))
    const uint8_t *bytes = frame.bytes;
    uint8_t crc = 0;
    for (NSUInteger i = 3; i < 8 + payload.length; i++)
        crc = CRC8DvbS2(crc, bytes[i]);
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
    _v2Unsupported = NO;
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
                _state = MSPParseStateProto;
            break;

        case MSPParseStateProto:
            if (b == kMSPProtoV1)      _state = MSPParseStateV1Direction;
            else if (b == kMSPProtoV2) _state = MSPParseStateV2Direction;
            else                       _state = MSPParseStateIdle;
            break;

        // ---------- v1 ----------
        case MSPParseStateV1Direction:
            _state = (b == kMSPDirIn) ? MSPParseStateV1Length : MSPParseStateIdle;
            break;

        case MSPParseStateV1Length:
            _payloadLen = b;
            _crc = b;
            _received = 0;
            [_payload setLength:0];
            _state = (_payloadLen == 0) ? MSPParseStateV1Checksum : MSPParseStateV1Command;
            break;

        case MSPParseStateV1Command:
            _crc ^= b;
            _rxCmd = b;
            _state = MSPParseStateV1Payload;
            break;

        case MSPParseStateV1Payload:
            _crc ^= b;
            [_payload appendBytes:&b length:1];
            _received++;
            if (_received >= _payloadLen)
                _state = MSPParseStateV1Checksum;
            break;

        case MSPParseStateV1Checksum:
            if (b == _crc)
                [self dispatchCmd:onFrame];
            // 校验失败静默丢弃(重发由上层超时兜底)
            [self reset];
            break;

        // ---------- v2 ----------
        case MSPParseStateV2Direction:
            if (b == kMSPDirIn) {
                _v2Unsupported = NO;
                _state = MSPParseStateV2Flag;
            } else if (b == kMSPDirUnsup) {
                _v2Unsupported = YES;  // 同 BF 配置器:'!' 仍派发,空 payload 由上层判
                _state = MSPParseStateV2Flag;
            } else {
                _state = MSPParseStateIdle;
            }
            break;

        case MSPParseStateV2Flag:
            _crc = CRC8DvbS2(0, b);   // crc 从 flag 开始
            _state = MSPParseStateV2CmdLo;
            break;

        case MSPParseStateV2CmdLo:
            _crc = CRC8DvbS2(_crc, b);
            _rxCmd = b;
            _state = MSPParseStateV2CmdHi;
            break;

        case MSPParseStateV2CmdHi:
            _crc = CRC8DvbS2(_crc, b);
            _rxCmd |= (uint16_t)(b << 8);
            _state = MSPParseStateV2LenLo;
            break;

        case MSPParseStateV2LenLo:
            _crc = CRC8DvbS2(_crc, b);
            _payloadLen = b;
            _state = MSPParseStateV2LenHi;
            break;

        case MSPParseStateV2LenHi:
            _crc = CRC8DvbS2(_crc, b);
            _payloadLen |= (uint16_t)(b << 8);
            _received = 0;
            [_payload setLength:0];
            _state = (_payloadLen > 0) ? MSPParseStateV2Payload : MSPParseStateV2Checksum;
            break;

        case MSPParseStateV2Payload:
            _crc = CRC8DvbS2(_crc, b);
            [_payload appendBytes:&b length:1];
            _received++;
            if (_received >= _payloadLen)
                _state = MSPParseStateV2Checksum;
            break;

        case MSPParseStateV2Checksum:
            if (b == _crc)
                [self dispatchCmd:onFrame];
            [self reset];
            break;
    }
}

/// 派发完整帧;v2 '!'(命令不支持)统一派发空 payload,上层按 0 长度判错
- (void)dispatchCmd:(MSPFrameHandler)onFrame
{
    NSData *pl = _v2Unsupported ? [NSData data] : [_payload copy];
    onFrame((uint8_t)(_rxCmd & 0xff), pl);
}

@end
