//
//  CimbarScanSession.m
//  PID_Liner
//
//  libcimbar 接收会话实现。C API 语义见 CimbarDecoder.xcframework/Headers/CimbarDecoder.h
//  与上游 web/recv-worker.js 的调用序列一一对应。
//

#import "CimbarScanSession.h"
#import "CimbarDecoder.h"

/** 解压输出缓冲上限（ponytail: 单次全量读，BBL 场景 64MB 足够；更大文件再改流式分块） */
static const NSUInteger kCimbarMaxOutputBytes = 64 * 1024 * 1024;

@interface CimbarScanResult ()
@property (nonatomic, copy, readwrite) NSString *filename;
@property (nonatomic, strong, readwrite) NSData *data;
@end

@implementation CimbarScanResult
@end

@interface CimbarScanSession ()
@property (nonatomic, assign) CimbarScanMode mode;
@property (nonatomic, strong) NSMutableData *fountainBuffer;  // cimbard_get_bufsize() 分配，复用
@property (nonatomic, assign) int fountainBufferSize;
@property (nonatomic, strong, nullable) CimbarScanResult *result;
@property (nonatomic, copy) NSString *progressString;
@property (nonatomic, assign, readwrite) BOOL hasLocked;
@property (nonatomic, assign, readwrite) double progress;
@end

@implementation CimbarScanSession

- (instancetype)initWithMode:(CimbarScanMode)mode
{
	self = [super init];
	if (!self)
		return nil;

	_mode = mode;
	_progressString = @"";
	if (cimbard_configure_decode((int)mode) != 0)
		return nil;

	_fountainBufferSize = cimbard_get_bufsize();
	if (_fountainBufferSize <= 0)
		return nil;
	_fountainBuffer = [NSMutableData dataWithLength:(NSUInteger)_fountainBufferSize];

	return self;
}

#pragma mark - 喂帧

- (void)feedPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
	if (self.done || pixelBuffer == NULL)
		return;

	OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
	// 相机输出只挑 NV12 / 420f（同为双平面 YUV，cimbar format=12）；其余格式让上层换配置，不猜
	if (type != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		&& type != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
		self.progressString = @"不支持的像素格式(需 NV12)";
		return;
	}

	CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
	void *base = CVPixelBufferGetBaseAddress(pixelBuffer);  // NV12: Y+UV 连续单块
	size_t width = CVPixelBufferGetWidth(pixelBuffer);
	size_t height = CVPixelBufferGetHeight(pixelBuffer);
	if (base != NULL && width > 0 && height > 0)
		[self scanExtractDecode:base width:(unsigned)width height:(unsigned)height format:12];
	CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

- (void)feedRGBA:(const unsigned char *)pixels width:(unsigned)width height:(unsigned)height
{
	if (self.done || pixels == NULL || width == 0 || height == 0)
		return;
	[self scanExtractDecode:pixels width:width height:height format:4];
}

#pragma mark - 核心流水线

/** 一帧三步：scan_extract_decode → (n>0) fountain_decode → (id>0) 还原文件 */
- (void)scanExtractDecode:(const unsigned char *)pixels
                    width:(unsigned)width
                   height:(unsigned)height
                   format:(int)format
{
	int decodedBytes = cimbard_scan_extract_decode(pixels, width, height, format,
												   self.fountainBuffer.mutableBytes,
												   (unsigned)self.fountainBufferSize);
	if (decodedBytes <= 0)
		return;  // 0=本帧无码 / -3=提取失败——喷泉码设计天然容忍，静默继续
	self.hasLocked = YES;  // 首帧解出 = 发送端锁定,链路建立

	int64_t fileId = cimbard_fountain_decode(self.fountainBuffer.bytes, (unsigned)decodedBytes);
	self.progressString = [self currentReport];
	if (fileId <= 0)
		return;  // 0=继续收帧；<0 上游内部已记，进度串可见

	// 文件收完：取文件名 + 解压内容（一次全量读）
	[self assembleResultWithFileId:(uint32_t)fileId];
}

- (void)assembleResultWithFileId:(uint32_t)fileId
{
	char filename[256] = {0};
	int nameLen = cimbard_get_filename(fileId, filename, sizeof(filename) - 1);
	NSString *name = nameLen > 0
		? [NSString stringWithFormat:@"%s", filename]
		: [NSString stringWithFormat:@"received_%u.bbl", fileId];

	NSMutableData *output = [NSMutableData dataWithLength:kCimbarMaxOutputBytes];
	int got = cimbard_decompress_read(fileId, output.mutableBytes, (unsigned)kCimbarMaxOutputBytes);
	if (got <= 0) {
		self.progressString = [NSString stringWithFormat:@"解压失败(%d)", got];
		return;
	}

	CimbarScanResult *result = [[CimbarScanResult alloc] init];
	result.filename = name.length ? name : @"received.bbl";
	result.data = [output subdataWithRange:NSMakeRange(0, (NSUInteger)got)];
	self.result = result;
	self.progress = 1.0;
	self.progressString = [NSString stringWithFormat:@"完成: %@ (%.1f MB)",
		result.filename, (double)got / 1024.0 / 1024.0];
}

- (NSString *)currentReport
{
	unsigned char report[512] = {0};
	unsigned len = cimbard_get_report(report, sizeof(report) - 1);
	if (len == 0)
		return self.progressString;
	NSString *raw = [NSString stringWithFormat:@"%s", (const char *)report];

	// C 库原始格式 "[ 0.0071 ]"(接收完成度小数) → UI 显示百分比
	NSRange digit = [raw rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
	if (digit.location == NSNotFound)
		return raw;  // 非进度类诊断文本,原样透传
	double fraction = [[raw substringFromIndex:digit.location] doubleValue];
	self.progress = MIN(MAX(fraction, 0.0), 1.0);  // 顺带更新数值进度(进度条数据源)
	return [NSString stringWithFormat:@"📡 接收中 %.1f%%", self.progress * 100.0];
}

#pragma mark - 状态

- (BOOL)isDone
{
	return self.result != nil;
}

- (void)reset
{
	// 上游只在档位变化时才清接收状态（同档重进保留 sink），借道邻档往返一次实现真重置
	int neighbor = (self.mode == CimbarScanModeB) ? (int)CimbarScanModeMicro : (int)CimbarScanModeB;
	cimbard_configure_decode(neighbor);
	cimbard_configure_decode((int)self.mode);
	self.result = nil;
	self.progressString = @"";
	self.hasLocked = NO;
	self.progress = 0.0;
}

@end
