//
//  PIDDataModels.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID分析数据模型定义
//

#ifndef PIDDataModels_h
#define PIDDataModels_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>  // 用于UIColor等UI类型

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CSV数据模型

/**
 * CSV飞行数据模型
 * 对应Python PID-Analyzer中的DataFrame结构
 */
@interface PIDCSVData : NSObject

// 时间相关
@property (nonatomic, strong) NSArray<NSNumber *> *timeUs;       // 时间戳 (微秒)
@property (nonatomic, strong) NSArray<NSNumber *> *timeSeconds;   // 时间 (秒)

// 遥控命令 (4个通道)
@property (nonatomic, strong) NSArray<NSNumber *> *rcCommand0;    // Roll
@property (nonatomic, strong) NSArray<NSNumber *> *rcCommand1;    // Pitch
@property (nonatomic, strong) NSArray<NSNumber *> *rcCommand2;    // Yaw
@property (nonatomic, strong) NSArray<NSNumber *> *rcCommand3;    // Throttle

// PID参数 (3个轴 x 3项)
@property (nonatomic, strong) NSArray<NSNumber *> *axisP0;        // Roll P
@property (nonatomic, strong) NSArray<NSNumber *> *axisP1;        // Pitch P
@property (nonatomic, strong) NSArray<NSNumber *> *axisP2;        // Yaw P
@property (nonatomic, strong) NSArray<NSNumber *> *axisI0;        // Roll I
@property (nonatomic, strong) NSArray<NSNumber *> *axisI1;        // Pitch I
@property (nonatomic, strong) NSArray<NSNumber *> *axisI2;        // Yaw I
@property (nonatomic, strong) NSArray<NSNumber *> *axisD0;        // Roll D
@property (nonatomic, strong) NSArray<NSNumber *> *axisD1;        // Pitch D
@property (nonatomic, strong) NSArray<NSNumber *> *axisD2;        // Yaw D

// 陀螺仪数据 (3个轴)
@property (nonatomic, strong) NSArray<NSNumber *> *gyroADC0;      // Roll Gyro
@property (nonatomic, strong) NSArray<NSNumber *> *gyroADC1;      // Pitch Gyro
@property (nonatomic, strong) NSArray<NSNumber *> *gyroADC2;      // Yaw Gyro

// Debug数据 (4个通道)
@property (nonatomic, strong) NSArray<NSNumber *> *debug0;
@property (nonatomic, strong) NSArray<NSNumber *> *debug1;
@property (nonatomic, strong) NSArray<NSNumber *> *debug2;
@property (nonatomic, strong) NSArray<NSNumber *> *debug3;

// 油门 (用于热力图X轴)
@property (nonatomic, strong) NSArray<NSNumber *> *throttle;

// 采样率
@property (nonatomic, assign) double sampleRate;                 // 采样率 (Hz)
@property (nonatomic, assign) NSInteger dataLength;              // 数据长度

/**
 * 获取指定轴的陀螺仪数据
 * @param axis 0=Roll, 1=Pitch, 2=Yaw
 */
- (NSArray<NSNumber *> *)gyroDataForAxis:(NSInteger)axis;

/**
 * 获取指定轴的P项数据
 */
- (NSArray<NSNumber *> *)axisPForAxis:(NSInteger)axis;

/**
 * 获取指定轴的I项数据
 */
- (NSArray<NSNumber *> *)axisIForAxis:(NSInteger)axis;

/**
 * 获取指定轴的D项数据
 */
- (NSArray<NSNumber *> *)axisDForAxis:(NSInteger)axis;

@end

#pragma mark - PID分析结果模型

/**
 * 单轴PID分析结果
 * 对应Python Trace类的输出
 */
@interface PIDAxisAnalysisResult : NSObject

@property (nonatomic, assign) NSInteger axisIndex;               // 0=Roll, 1=Pitch, 2=Yaw
@property (nonatomic, copy) NSString *axisName;                  // "Roll", "Pitch", "Yaw"

// 响应分析结果
@property (nonatomic, strong) NSArray<NSNumber *> *stepResponse; // 阶跃响应曲线
@property (nonatomic, strong) NSArray<NSNumber *> *responseTime; // 响应时间轴
@property (nonatomic, assign) double settlingTime;               // 建立时间
@property (nonatomic, assign) double overshoot;                  // 超调量
@property (nonatomic, assign) double riseTime;                   // 上升时间

// 噪声分析结果
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *noiseSpectrum; // 噪声频谱 [频率][幅度]
@property (nonatomic, strong) NSArray<NSNumber *> *frequencies;  // 频率轴

// 热图数据
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *responseHeatmap; // 响应热图 [油门][响应]
@property (nonatomic, strong) NSArray<NSNumber *> *throttleBins; // 油门分箱

@end

#pragma mark - Session分析摘要

/**
 * CSV Session分析摘要
 */
@interface PIDSessionSummary : NSObject

@property (nonatomic, copy) NSString *csvFileName;               // CSV文件名
@property (nonatomic, copy) NSString *sourceBBL;                 // 源BBL文件
@property (nonatomic, assign) NSInteger sessionIndex;            // Session索引
@property (nonatomic, assign) NSInteger dataPointCount;          // 数据点数量
@property (nonatomic, assign) double durationSeconds;            // 时长(秒)
@property (nonatomic, strong) NSDate *analysisDate;              // 分析日期

// 各轴分析结果
@property (nonatomic, strong) NSArray<PIDAxisAnalysisResult *> *axisResults; // 3个轴的结果

@end

#pragma mark - 图表配置模型

/**
 * 图表数据系列
 * 用于AAChartKit配置
 */
@interface PIDChartSeries : NSObject

@property (nonatomic, copy) NSString *name;                      // 系列名称
@property (nonatomic, copy) NSString *chartType;                 // 图表类型 (line, area, spline等)
@property (nonatomic, strong) NSArray<NSNumber *> *data;         // 数据点
@property (nonatomic, strong) NSArray<NSString *> *categories;   // X轴标签
@property (nonatomic, copy) NSString *color;                     // 颜色 (HEX)

@end

/**
 * 热图数据模型
 */
@interface PIDHeatmapData : NSObject

@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *data;     // 2D数据 [row][col]
@property (nonatomic, assign) double minValue;                          // 最小值
@property (nonatomic, assign) double maxValue;                          // 最大值
@property (nonatomic, strong) NSArray<NSString *> *xAxisLabels;        // X轴标签
@property (nonatomic, strong) NSArray<NSString *> *yAxisLabels;        // Y轴标签
@property (nonatomic, copy) NSString *title;                            // 标题

/**
 * 获取指定位置的颜色
 * @param value 数据值
 * @return UIColor对象
 */
- (UIColor *)colorForValue:(double)value;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDDataModels_h */
