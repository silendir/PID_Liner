//
//  PIDInterpolation.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  插值函数 - 对应scipy.interpolate.interp1d
//

#ifndef PIDInterpolation_h
#define PIDInterpolation_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 插值方法类型
 */
typedef NS_ENUM(NSInteger, PIDInterpolationMethod) {
    PIDInterpolationMethodLinear,    // 线性插值
    PIDInterpolationMethodCubic,     // 三次样条插值（简化实现）
    PIDInterpolationMethodNearest    // 最近邻插值
};

/**
 * 插值函数
 * 对应Python: scipy.interpolate.interp1d
 */
@interface PIDInterpolation : NSObject

/**
 * 创建一维插值函数
 * @param x 原始x坐标点（必须单调递增）
 * @param y 原始y坐标点
 * @param method 插值方法
 * @return 可调用的插值块 (x_new -> y_new)
 */
- (NSArray<NSNumber *> *(^)(NSArray<NSNumber *> *))interpolate1D:(NSArray<NSNumber *> *)x
                                                             y:(NSArray<NSNumber *> *)y
                                                        method:(PIDInterpolationMethod)method;

/**
 * 线性插值（便捷方法）
 * @param x 原始x坐标
 * @param y 原始y坐标
 * @param x_new 新的x坐标
 * @return 插值后的y值
 */
+ (NSArray<NSNumber *> *)linearInterpolateWithX:(NSArray<NSNumber *> *)x
                                            y:(NSArray<NSNumber *> *)y
                                         xNew:(NSArray<NSNumber *> *)x_new;

/**
 * 累积和
 * 对应numpy.cumsum()
 * @param data 输入数组
 * @return 累积和数组
 */
+ (NSArray<NSNumber *> *)cumsum:(NSArray<NSNumber *> *)data;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDInterpolation_h */
