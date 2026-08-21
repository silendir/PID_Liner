//
//  CimbarDecoder.h
//  PID_Liner — libcimbar 光学传输接收端 C API（构建层自写声明，对接上游 cimbar_recv_js）
//
//  调用序列（App 侧完整流程）:
//   1. cimbard_configure_decode(mode)            —— 档位 B=68 / Bu=66 / Bm=67，切换会重置接收状态
//   2. bufsize = cimbard_get_bufsize()           —— 分配喷泉码块缓冲（一次）
//   3. 每相机帧: cimbard_scan_extract_decode()   —— 返回 >0 = 本帧解出 n 字节；0=没识别到码(忽略)；-3=提取失败(忽略)；其余=错误
//   4. n>0 时: cimbard_fountain_decode(buf, n)   —— 返回 0=继续收；>0=文件完成(此即文件id)；<0=错误
//   5. 完成后: cimbard_get_filename / cimbard_decompress_read —— 取文件名与解压后内容
//  ⚠️ 下方所有函数非线程安全（上游单会话设计），App 侧固定在串行队列调用。
//

#ifndef CIMBAR_DECODER_C_API_H
#define CIMBAR_DECODER_C_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 进度/诊断文本（ASCII），返回长度。渲染 UI 进度用。 */
unsigned cimbard_get_report(unsigned char *buff, unsigned maxlen);

/** 一帧所需的喷泉码块缓冲大小 = chunksPerFrame * chunkSize */
int cimbard_get_bufsize(void);

/**
 * 喂一帧相机图像，完成 扫码定位→透视矫正→cimbar 解码，输出到 bufspace。
 * @param format 12=NV12(YUV半平面) 420=I420(YUV平面) 4=RGBA 3=RGB（默认）
 * @return >0 解出的字节数（送 fountain_decode）；0 本帧无码；-1 参数错；-2 缓冲不够；-3 定位/提取失败
 */
int cimbard_scan_extract_decode(const unsigned char *imgdata, unsigned imgw, unsigned imgh,
                                int format, unsigned char *bufspace, unsigned bufsize);

/**
 * 喂入 scan_extract_decode 的输出，累计喷泉码解码。
 * @return 0 继续收帧；>0 文件收完（uint32 文件 id，用于下方三个函数）；<0 错误
 */
int64_t cimbard_fountain_decode(const unsigned char *buffer, unsigned size);

/** 压缩流文件大小（一般不需要直接用） */
unsigned cimbard_get_filesize(uint32_t id);

/**
 * 取原始文件名（发送端的原名，如 xxx.bbl）。
 * @return >0 = 写入 filename 的字节数；0 = 无名；<0 = 错误
 */
int cimbard_get_filename(uint32_t id, char *filename, unsigned fnsize);

/** 解压读缓冲建议大小（流式分块用） */
int cimbard_get_decompress_bufsize(void);

/**
 * 读取解压后的文件内容。
 * 上游实现为"每次调用全量解压再拷贝前 size 字节"，所以 App 侧一次给足大 buffer 调用一次即可
 * （ponytail: 单次全量，BBL 场景上限 64MB 够用；真有更大文件再改流式多次读）。
 * @return 拷贝出的字节数；0 = 已读完；<0 错误
 */
int cimbard_decompress_read(uint32_t id, unsigned char *buffer, unsigned size);

/** 设置解码档位（收发两端必须同档）。B=68（默认）/ Bu=66 / Bm=67 */
int cimbard_configure_decode(int mode_val);

#ifdef __cplusplus
}
#endif

#endif /* CIMBAR_DECODER_C_API_H */
