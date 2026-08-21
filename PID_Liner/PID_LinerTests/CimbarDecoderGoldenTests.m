//
//  CimbarDecoderGoldenTests.m
//  PID_LinerTests
//
//  R1c golden 判据：官方样本帧(b/tr_0~3.png, B档) 喂 iOS decoder（经 CimbarScanSession），
//  喷泉码还原 + zstd 解压后的文件 sha256 必须与上游 DecoderTest 的 golden 常量一致。
//  上游参考: 技术验证Demo/libcimbar-src/src/lib/encoder/test/DecoderTest.cpp
//    (no-ecc) ddcb6cd47751df1402dcf2cffdace212bc9e4a4b6ef097ad4828913086309469
//    (ecc)    a0e9fff8cd5b13807fae215b8b07e38091d3f533ff46243b53ee7f74fbbee0d5
//

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "CimbarScanSession.h"

@interface CimbarDecoderGoldenTests : XCTestCase
@end

@implementation CimbarDecoderGoldenTests

#pragma mark - fixture 加载

/// PNG fixture → RGBA8 原始像素（feedRGBA 用）
+ (nullable NSData *)rgbaPixelsFromFixture:(NSString *)name
                                     width:(NSUInteger *)outW
                                    height:(NSUInteger *)outH
{
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:name ofType:@"png"
                                                                inDirectory:@"TestFixtures/CimbarSamples"];
    if (!path)
        return nil;

    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image)
        return nil;

    CGImageRef cg = image.CGImage;
    NSUInteger w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, rgb,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(rgb);
    if (!ctx)
        return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);

    *outW = w;
    *outH = h;
    return pixels;
}

- (NSString *)sha256Hex:(const void *)bytes length:(NSUInteger)len
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)len, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - golden 测试

- (void)testGoldenBFramesDecodeToUpstreamHash
{
    CimbarScanSession *session = [[CimbarScanSession alloc] initWithMode:CimbarScanModeB];
    XCTAssertNotNil(session, @"session 初始化失败");

    // 逐帧喂（喷泉码冗余容错；最多两轮足够还原）
    NSArray<NSString *> *frames = @[@"tr_0", @"tr_1", @"tr_2", @"tr_3"];
    for (int pass = 0; pass < 2 && !session.done; pass++) {
        for (NSString *name in frames) {
            NSUInteger w = 0, h = 0;
            NSData *pixels = [self.class rgbaPixelsFromFixture:name width:&w height:&h];
            XCTAssertNotNil(pixels, @"fixture %@ 缺失", name);
            [session feedRGBA:pixels.bytes width:(unsigned)w height:(unsigned)h];
            if (session.done)
                break;
        }
    }

    XCTAssertTrue(session.done, @"官方 golden 帧未能还原文件——decoder 移植有误。progress=%@",
                  session.progressString);
    XCTAssertGreaterThan(session.result.data.length, (NSUInteger)0);
    NSLog(@"[cimbar golden] filename=%@ size=%lu progress=%@",
          session.result.filename, (unsigned long)session.result.data.length, session.progressString);

    // sha256 对照上游 golden（ecc 开/关对应两个常量，命中任一即移植正确）
    NSString *hash = [self sha256Hex:session.result.data.bytes length:session.result.data.length];
    BOOL matches = [hash isEqualToString:@"ddcb6cd47751df1402dcf2cffdace212bc9e4a4b6ef097ad4828913086309469"]
                || [hash isEqualToString:@"a0e9fff8cd5b13807fae215b8b07e38091d3f533ff46243b53ee7f74fbbee0d5"];
    XCTAssertTrue(matches, @"golden hash 不匹配: %@ (size=%lu)——decoder 输出与上游不一致",
                  hash, (unsigned long)session.result.data.length);
}

@end
