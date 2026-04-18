//
//  PIDDataModels.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID分析数据模型实现
//

#import "PIDDataModels.h"
#import <UIKit/UIKit.h>

#pragma mark - PIDCSVData Implementation

@implementation PIDCSVData

- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleRate = 8000.0;  // 默认8kHz (Betaflight日志率)
        _dataLength = 0;
    }
    return self;
}

- (NSArray<NSNumber *> *)gyroDataForAxis:(NSInteger)axis {
    switch (axis) {
        case 0: return self.gyroADC0 ?: @[];
        case 1: return self.gyroADC1 ?: @[];
        case 2: return self.gyroADC2 ?: @[];
        default: return @[];
    }
}

- (NSArray<NSNumber *> *)axisPForAxis:(NSInteger)axis {
    switch (axis) {
        case 0: return self.axisP0 ?: @[];
        case 1: return self.axisP1 ?: @[];
        case 2: return self.axisP2 ?: @[];
        default: return @[];
    }
}

- (NSArray<NSNumber *> *)axisIForAxis:(NSInteger)axis {
    switch (axis) {
        case 0: return self.axisI0 ?: @[];
        case 1: return self.axisI1 ?: @[];
        case 2: return self.axisI2 ?: @[];
        default: return @[];
    }
}

- (NSArray<NSNumber *> *)axisDForAxis:(NSInteger)axis {
    switch (axis) {
        case 0: return self.axisD0 ?: @[];
        case 1: return self.axisD1 ?: @[];
        case 2: return self.axisD2 ?: @[];
        default: return @[];
    }
}

@end

#pragma mark - PIDAxisAnalysisResult Implementation

@implementation PIDAxisAnalysisResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _settlingTime = 0.0;
        _overshoot = 0.0;
        _riseTime = 0.0;
    }
    return self;
}

@end

#pragma mark - PIDSessionSummary Implementation

@implementation PIDSessionSummary

- (instancetype)init {
    self = [super init];
    if (self) {
        _axisResults = [NSMutableArray array];
        _analysisDate = [NSDate date];
    }
    return self;
}

@end

#pragma mark - PIDChartSeries Implementation

@implementation PIDChartSeries

- (instancetype)init {
    self = [super init];
    if (self) {
        _chartType = @"spline";  // 平滑曲线样式
        _data = @[];
        _categories = @[];
    }
    return self;
}

@end

#pragma mark - PIDHeatmapData Implementation

@implementation PIDHeatmapData

- (instancetype)init {
    self = [super init];
    if (self) {
        _data = @[];
        _minValue = 0.0;
        _maxValue = 1.0;
        _xAxisLabels = @[];
        _yAxisLabels = @[];
    }
    return self;
}

/**
 * 将数值映射到热图颜色
 * 使用类似Python matplotlib的'viridis'配色方案
 * @param value 数据值
 * @return 对应的UIColor
 */
- (UIColor *)colorForValue:(double)value {
    // 归一化到 [0, 1]
    double normalized = (value - _minValue) / (_maxValue - _minValue + 0.0001);
    normalized = MAX(0.0, MIN(1.0, normalized));  // clamp

    // 简化的热图配色 (蓝 -> 绿 -> 黄 -> 红)
    // 也可以使用更复杂的配色方案
    return [self viridisColorForValue:normalized];
}

/**
 * Viridis配色方案 (类似matplotlib)
 * @param t 归一化值 [0, 1]
 */
- (UIColor *)viridisColorForValue:(double)t {
    // Viridis配色关键点插值
    // (0.0, 0.267004, 0.004874, 0.329415)  -> 深紫
    // (0.25, 0.282623, 0.140926, 0.457517) -> 紫色
    // (0.5, 0.20803, 0.318931, 0.533404)   -> 紫绿
    // (0.75, 0.384769, 0.564374, 0.421093) -> 绿色
    // (1.0, 0.993248, 0.906157, 0.143936)  -> 黄色

    CGFloat r, g, b;

    if (t < 0.25) {
        double localT = t / 0.25;
        r = 0.267004 + (0.282623 - 0.267004) * localT;
        g = 0.004874 + (0.140926 - 0.004874) * localT;
        b = 0.329415 + (0.457517 - 0.329415) * localT;
    } else if (t < 0.5) {
        double localT = (t - 0.25) / 0.25;
        r = 0.282623 + (0.20803 - 0.282623) * localT;
        g = 0.140926 + (0.318931 - 0.140926) * localT;
        b = 0.457517 + (0.533404 - 0.457517) * localT;
    } else if (t < 0.75) {
        double localT = (t - 0.5) / 0.25;
        r = 0.20803 + (0.384769 - 0.20803) * localT;
        g = 0.318931 + (0.564374 - 0.318931) * localT;
        b = 0.533404 + (0.421093 - 0.533404) * localT;
    } else {
        double localT = (t - 0.75) / 0.25;
        r = 0.384769 + (0.993248 - 0.384769) * localT;
        g = 0.564374 + (0.906157 - 0.564374) * localT;
        b = 0.421093 + (0.143936 - 0.421093) * localT;
    }

    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

@end
