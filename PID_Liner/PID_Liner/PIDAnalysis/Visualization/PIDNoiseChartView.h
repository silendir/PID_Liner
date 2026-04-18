//
//  PIDNoiseChartView.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID噪声图表视图 - 对应Python的noise plot
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PIDNoiseChartView;

/**
 * 噪声频谱数据
 */
@interface PIDNoiseSpectrumData : NSObject

// 频率轴 (Hz)
@property (nonatomic, strong) NSArray<NSNumber *> *frequencies;

// 频谱幅度 [throttleIdx][freqIdx]
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *spectrumHeatmap;

// 油门轴 (0-100%)
@property (nonatomic, strong) NSArray<NSNumber *> *throttleAxis;

// 轴名称
@property (nonatomic, copy) NSString *axisName;

/**
 * 创建噪声频谱数据
 */
+ (instancetype)dataWithFrequencies:(NSArray<NSNumber *> *)frequencies
                   spectrumHeatmap:(NSArray<NSArray<NSNumber *> *> *)spectrumHeatmap
                       throttleAxis:(NSArray<NSNumber *> *)throttleAxis
                          axisName:(NSString *)axisName;

@end

/**
 * 滤波器透过率数据
 */
@interface PIDFilterPassData : NSObject

// 频率轴 (Hz)
@property (nonatomic, strong) NSArray<NSNumber *> *frequencies;

// 透过率 (0-1)
@property (nonatomic, strong) NSArray<NSNumber *> *passThrough;

/**
 * 创建滤波器透过率数据
 */
+ (instancetype)dataWithFrequencies:(NSArray<NSNumber *> *)frequencies
                         passThrough:(NSArray<NSNumber *> *)passThrough;

@end

/**
 * PID噪声分析图表视图
 *
 * 布局（对应Python的subplot结构）:
 * ┌─────────┬─────────┬─────────┐
 * │  Gyro   │  Debug  │  D-term │  ← 噪声频谱热力图 (3列 x 3行 = 9个轴)
 * │  Roll   │  Roll   │  Roll   │
 * ├─────────┼─────────┼─────────┤
 * │  Gyro   │  Debug  │  D-term │
 * │  Pitch  │  Pitch  │  Pitch  │
 * ├─────────┼─────────┼─────────┤
 * │  Gyro   │  Debug  │  D-term │
 * │  Yaw    │  Yaw    │  Yaw    │
 * ├─────────┴─────────┴─────────┤
 * │    Filter Pass Through       │  ← 滤波器透过率曲线
 * └──────────────────────────────┘
 */
@interface PIDNoiseChartView : UIView

// Gyro噪声数据（3轴）
@property (nonatomic, copy) NSArray<PIDNoiseSpectrumData *> *gyroNoiseData;

// Debug噪声数据（3轴）
@property (nonatomic, copy) NSArray<PIDNoiseSpectrumData *> *debugNoiseData;

// D-term噪声数据（3轴，可选）
@property (nonatomic, copy, nullable) NSArray<PIDNoiseSpectrumData *> *dTermNoiseData;

// 滤波器透过率数据
@property (nonatomic, strong, nullable) PIDFilterPassData *filterPassData;

// 频率显示范围 (Hz)
@property (nonatomic, assign) double minFreq;
@property (nonatomic, assign) double maxFreq;

// 是否显示D-term列
@property (nonatomic, assign) BOOL showDTerm;

/**
 * 初始化
 */
- (instancetype)initWithFrame:(CGRect)frame;

/**
 * 设置噪声数据并刷新
 * @param gyroData Gyro噪声数据（3轴：roll, pitch, yaw）
 * @param debugData Debug噪声数据（3轴）
 * @param dTermData D-term噪声数据（3轴，可为nil）
 */
- (void)setGyroNoiseData:(NSArray<PIDNoiseSpectrumData *> *)gyroData
            debugNoiseData:(NSArray<PIDNoiseSpectrumData *> *)debugData
             dTermNoiseData:(nullable NSArray<PIDNoiseSpectrumData *> *)dTermData;

/**
 * 刷新显示
 */
- (void)refreshDisplay;

/**
 * 导出为图片
 */
- (UIImage *)exportImage;

/**
 * 清空数据
 */
- (void)clearData;

@end

NS_ASSUME_NONNULL_END
