//
//  blackbox_bridge.h
//  PIDapp
//
//  C桥接接口 - 连接Swift和blackbox-tools C代码
//  提供简化的解码API供Swift调用
//

#ifndef blackbox_bridge_h
#define blackbox_bridge_h

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - 数据结构定义

/// 解码结果状态
typedef enum {
    DECODE_SUCCESS = 0,      // 成功
    DECODE_ERROR_FILE = -1,  // 文件错误
    DECODE_ERROR_FORMAT = -2,// 格式错误
    DECODE_ERROR_MEMORY = -3 // 内存错误
} DecodeStatus;

/// CSV数据结构
typedef struct {
    char *data;           // CSV数据内容(调用方需要free)
    size_t dataLength;    // 数据长度
    int frameCount;       // 帧数量
    DecodeStatus status;  // 解码状态
    char errorMessage[256]; // 错误信息
} DecodeResult;

/// BBL文件元数据
typedef struct {
    char firmwareVersion[64];  // 固件版本
    char craftName[64];        // 飞行器名称
    int looptime;              // 循环时间(us)
    int logRate;               // 日志采样率
    int fieldCount;            // 字段数量
    char *fieldNames;          // 字段名称列表(逗号分隔,需要free)
} BBLMetadata;

// MARK: - 核心解码API

/**
 * 解码BBL文件为CSV数据
 *
 * @param bblFilePath BBL文件路径(UTF-8编码)
 * @param result 输出解码结果(调用方需要free result->data和result->errorMessage)
 * @return 解码状态码
 */
DecodeStatus blackbox_decode_to_csv(const char *bblFilePath, DecodeResult *result);

/**
 * 提取BBL文件元数据
 *
 * @param bblFilePath BBL文件路径(UTF-8编码)
 * @param metadata 输出元数据(调用方需要free metadata->fieldNames)
 * @return 解码状态码
 */
DecodeStatus blackbox_extract_metadata(const char *bblFilePath, BBLMetadata *metadata);

/**
 * 释放DecodeResult内存
 *
 * @param result 待释放的结果结构
 */
void blackbox_free_decode_result(DecodeResult *result);

/**
 * 释放BBLMetadata内存
 *
 * @param metadata 待释放的元数据结构
 */
void blackbox_free_metadata(BBLMetadata *metadata);

/**
 * 获取库版本信息
 *
 * @return 版本字符串(静态内存,不需要释放)
 */
const char* blackbox_get_version(void);

// MARK: - Session管理API

/**
 * 列举BBL文件中的所有sessions
 *
 * @param bblFilePath BBL文件路径(UTF-8编码)
 * @param sessionCount [输出] session数量
 * @return 解码状态码
 */
DecodeStatus blackbox_list_sessions(const char *bblFilePath, int *sessionCount);

/**
 * 获取指定session的详细信息
 *
 * @param bblFilePath BBL文件路径(UTF-8编码)
 * @param sessionIndex Session索引(从0开始)
 * @param frameCount [输出] 该session的帧数
 * @return 解码状态码
 */
DecodeStatus blackbox_get_session_info(const char *bblFilePath, int sessionIndex, int *frameCount);

/**
 * 解码指定session为CSV格式
 *
 * @param bblFilePath BBL文件路径(UTF-8编码)
 * @param sessionIndex Session索引(从0开始)
 * @param result [输出] 解码结果(调用方需要free result->data)
 * @return 解码状态码
 */
DecodeStatus blackbox_decode_to_csv_with_index(const char *bblFilePath, int sessionIndex, DecodeResult *result);

#ifdef __cplusplus
}
#endif

#endif /* blackbox_bridge_h */
