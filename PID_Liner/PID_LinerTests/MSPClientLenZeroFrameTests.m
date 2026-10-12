//
//  MSPClientLenZeroFrameTests.m — v1 空 payload(len=0)响应帧解析回归
//
//  真机踩坑:ERASE(cmd=0x48)响应 `$M> 00 48 48` 是 len=0 的 v1 帧,旧状态机
//  跳过 cmd 直进 Checksum,把 cmd 当校验和 → 永远解析失败 → 上层白等 5s 超时。
//
#import <XCTest/XCTest.h>
#import "MSPClient.h"

static NSData *BytesData(const uint8_t *bytes, NSUInteger len)
{
    return [NSData dataWithBytes:bytes length:len];
}

@interface MSPClientLenZeroFrameTests : XCTestCase
@end

@implementation MSPClientLenZeroFrameTests

/// len=0 的 v1 响应帧必须派发 onFrame(cmd, 空 payload)
- (void)testV1LenZeroFrameDispatches
{
    MSPClient *msp = [[MSPClient alloc] init];
    __block BOOL called = NO;
    __block uint8_t gotCmd = 0;
    __block NSUInteger gotLen = 999;
    const uint8_t eraseReply[] = {0x24, 0x4D, 0x3E, 0x00, 0x48, 0x48};  // 真机日志原样字节
    [msp feedData:BytesData(eraseReply, sizeof(eraseReply))
          onFrame:^(uint8_t cmd, NSData *payload) {
        called = YES; gotCmd = cmd; gotLen = payload.length;
    }];
    XCTAssertTrue(called, @"len=0 的 v1 响应帧必须派发,否则关单失败走 5s 超时");
    XCTAssertEqual(gotCmd, 0x48);
    XCTAssertEqual(gotLen, 0u);
}

/// 正常 len>0 帧不受修复影响(回归:cmd=1 握手响应,真机日志原样字节)
- (void)testV1NormalFrameStillDispatches
{
    MSPClient *msp = [[MSPClient alloc] init];
    __block BOOL called = NO;
    __block uint8_t gotCmd = 0;
    __block NSData *gotPayload = nil;
    const uint8_t handshakeReply[] = {0x24, 0x4D, 0x3E, 0x03, 0x01, 0x00, 0x01, 0x2C, 0x2F};
    const uint8_t wantPayload[] = {0x00, 0x01, 0x2C};
    [msp feedData:BytesData(handshakeReply, sizeof(handshakeReply))
          onFrame:^(uint8_t cmd, NSData *payload) {
        called = YES; gotCmd = cmd; gotPayload = payload;
    }];
    XCTAssertTrue(called);
    XCTAssertEqual(gotCmd, 0x01);
    XCTAssertEqualObjects(gotPayload, BytesData(wantPayload, sizeof(wantPayload)));
}

/// 帧前有杂散字节(粘包/残留)照样能解析出 len=0 帧
- (void)testV1LenZeroFrameWithLeadingJunk
{
    MSPClient *msp = [[MSPClient alloc] init];
    __block BOOL called = NO;
    const uint8_t junkThenFrame[] = {0xAA, 0xBB, 0x24, 0x4D, 0x3E, 0x00, 0x10, 0x10};
    [msp feedData:BytesData(junkThenFrame, sizeof(junkThenFrame))
          onFrame:^(uint8_t cmd, NSData *payload) {
        called = YES;
        XCTAssertEqual(cmd, 0x10);
        XCTAssertEqual(payload.length, 0u);
    }];
    XCTAssertTrue(called);
}

@end
