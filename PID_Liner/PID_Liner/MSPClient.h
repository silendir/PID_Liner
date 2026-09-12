//
//  MSPClient.h
//  PID_Liner
//
//  MSP v1 协议编解码（蓝牙分支 · clean-room 重实现）
//  协议事实来源:BetaFlight 固件 msp.c 的公开线格式(v1 XOR 校验):
//    请求: $ M < size cmd payload... crc   (crc = size^cmd^payload 逐字节异或)
//    响应: $ M > size cmd payload... crc
//  MSC 路径只用 1 字节小 payload,不需要 v2 帧(>255 字节才必须)。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MSP 命令码(仅本功能用到的)
typedef NS_ENUM(uint8_t, MSPCommand) {
    MSPCommandApiVersion      = 1,   // MSP_API_VERSION,响应[协议版本,API主,API次],链路探测用
    MSPCommandSetReboot       = 68,  // MSP_SET_REBOOT,payload[0]=rebootType
    MSPCommandDataflashSummary = 70, // 响应[flags,扇区u32,总容量u32,已用u32],13字节
    MSPCommandDataflashRead    = 71, // 蓝牙直下黑盒:4KB块必须走 v2 帧(v1 长度字段1字节装不下)
};

/// MSP_SET_REBOOT 的 rebootType
typedef NS_ENUM(uint8_t, MSPRebootType) {
    MSPRebootTypeFirmware   = 0,
    MSPRebootTypeBootloader = 1,
    MSPRebootTypeMSC        = 2,   // 大容量存储模式(激活后飞控变 U 盘,断电还原)
};

/// 解析完一帧的回调(cmd + 原始 payload)
typedef void (^MSPFrameHandler)(uint8_t cmd, NSData *payload);

@interface MSPClient : NSObject

/// 构造 MSP v1 请求帧(方向 '<')
+ (NSData *)v1RequestWithCmd:(uint8_t)cmd payload:(NSData *)payload;

/// 构造 MSP v2 请求帧(方向 '<',大 payload 用;格式照 BF 配置器 msp.js encode_message_v2)
+ (NSData *)v2RequestWithCmd:(uint16_t)cmd payload:(NSData *)payload;

/// 流式喂字节(蓝牙 notify 到多少喂多少,帧跨包自动缓冲重组)
/// 解析出完整 v1 响应帧时调用 onFrame;非 v1 帧头($X...)按帧长跳过
- (void)feedData:(NSData *)data onFrame:(MSPFrameHandler)onFrame;

/// 丢弃半帧缓冲(连接断开/超时后复用)
- (void)reset;

@end

NS_ASSUME_NONNULL_END
