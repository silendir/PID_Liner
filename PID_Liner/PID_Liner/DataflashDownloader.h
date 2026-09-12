//
//  DataflashDownloader.h
//  PID_Liner
//
//  蓝牙直下黑盒(绕过大容量存储):MSP_DATAFLASH_SUMMARY 拿已用量 →
//  循环 MSP_DATAFLASH_READ(v2 帧,4KB 块) 拼出 .bbl 原始字节。
//  协议事实照 BF 配置器 MSPHelper.js dataflashRead / MSP_DATAFLASH_SUMMARY 解析,
//  实现为本项目自有 ObjC 代码。
//

#import <Foundation/Foundation.h>

@class FCBluetoothService;

@interface DataflashDownloader : NSObject

@property (nonatomic, assign, readonly) BOOL running;

- (instancetype)initWithService:(FCBluetoothService *)service;

/// 开始下载(串行一问一答)。progress/completion 均回调主线程;
/// completion fileURL 非 nil 即成功(已落盘 Documents)。
- (void)startWithProgress:(void(^)(double fraction, NSString *text))progress
               completion:(void(^)(NSURL *_Nullable fileURL, NSString *_Nullable errorMessage))completion;

- (void)cancel;

@end
