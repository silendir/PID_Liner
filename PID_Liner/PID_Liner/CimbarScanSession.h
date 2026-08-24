//
//  CimbarScanSession.h
//  PID_Liner
//
//  libcimbar 光学传输接收会话（QRcode Transfer R2）
//  包装 CimbarDecoder.xcframework 的 extern C API：
//  相机帧 → 扫码定位/透视矫正 → cimbar 解码 → 喷泉码累计 → zstd 还原原文件
//
//  ⚠️ 非线程安全（上游单会话设计）：所有方法必须在同一串行队列调用。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/** 编码档位——发送端网页与 App 必须同档（产品默认 B） */
typedef NS_ENUM(NSUInteger, CimbarScanMode) {
	CimbarScanModeB = 68,       // B:   1024×1024 方帧, 容量最大最快（默认）
	CimbarScanModeMicro = 66,   // Bu:  736×637 小帧, 小屏幕/距离远
	CimbarScanModeMini = 67,    // Bm:  1024×720 宽幅, 宽屏全屏/抗干扰最强
};

/** 一次接收完成的产物（喷泉码还原 + zstd 解压后的原始文件，如 .bbl） */
@interface CimbarScanResult : NSObject
@property (nonatomic, copy, readonly) NSString *filename;  // 发送端原文件名
@property (nonatomic, strong, readonly) NSData *data;      // 解压后文件内容
@end

@interface CimbarScanSession : NSObject

- (instancetype)initWithMode:(CimbarScanMode)mode NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** 喂相机帧（NV12/420f 半平面，AVCaptureVideoDataOutput 常规格式） */
- (void)feedPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/** 喂 RGBA8 原始像素（w*h*4 字节；单测/golden 路径） */
- (void)feedRGBA:(const unsigned char *)pixels width:(unsigned)width height:(unsigned)height;

/** 进度/诊断文本（"📡 接收中 35.2%" 等），可直接渲染 UI */
@property (nonatomic, copy, readonly) NSString *progressString;

/** 已解出首帧（发送端已锁定，链路建立）——三态 UI 的"传输中"判定 */
@property (nonatomic, readonly) BOOL hasLocked;

/** 接收完成度 0.0-1.0（未锁定为 0；到 1.0 即 done）——进度条数据源 */
@property (nonatomic, readonly) double progress;

/** 文件已接收完成（YES 后 result 可用，后续 feed 帧无意义） */
@property (nonatomic, readonly, getter=isDone) BOOL done;

@property (nullable, nonatomic, strong, readonly) CimbarScanResult *result;

/** 丢弃已收数据重新开始（上游实现：同档重进无副作用，换档会自动重置） */
- (void)reset;

@end

NS_ASSUME_NONNULL_END
