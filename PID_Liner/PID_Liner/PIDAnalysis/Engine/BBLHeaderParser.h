//
//  BBLHeaderParser.h
//  PID_Liner
//
//  阶段2.5c: 纯ObjC解析BBL header,提取BF真实配置(PID/FF/d_min/滤波/TPA)
//
//  背景: BBL header 文本含完整BF配置(rollPID/feedforward_weight/d_min/dterm滤波/TPA等),
//        但 BlackboxDecoder.extract_metadata 只取 firmwareVersion/craftName(BBLMetadata无PID字段)。
//        本类补这个缺口——纯ObjC读文件解析,不动BlackboxDecoder(1.1前代码),不动C桥接。
//
//  使用方: 探索模型(标定/反解测试)调用拿真实配置;主程序暂不接入(零影响)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析 BBL 文件 header 的 "H field:value" 文本行
@interface BBLHeaderParser : NSObject

/// 解析 BBL header,返回 {fieldName: rawValueString} 字典
///
/// BBL header 是文本行(以 "H " 开头),header 结束后才是二进制帧。
/// 本方法读前 32KB(cover BF header 文本段),按 "H field:value" 解析每行。
///
/// 常见字段(001.bbl 实例):
///   rollPID:"38,85,44"  pitchPID:"41,90,48"  yawPID:"41,90,0"   (P,I,D)
///   feedforward_weight:"72,76,72"   (BF4.2; BF4.3+ 用 rollF/pitchF/yawF)
///   d_min:"29,31,0"  d_min_gain:"37"  d_min_advance:"20"
///   dterm_lowpass_hz:"150"  dterm_lowpass_dyn_hz:"70,170"
///   tpa_rate:"60"  tpa_breakpoint:"1350"
///   Firmware revision:"Betaflight 4.2.6 ..."  Craft name:"Silen"
///
/// @param bblPath BBL 文件绝对路径
/// @return 字段字典;文件不存在/无header行返回 nil
+ (nullable NSDictionary<NSString *, NSString *> *)parseHeaderFromFile:(NSString *)bblPath;

@end

NS_ASSUME_NONNULL_END
