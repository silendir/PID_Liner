//
//  PIDGaussianFilter.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  高斯滤波器 - 对应scipy.ndimage.filters.gaussian_filter1d
//

#ifndef PIDGaussianFilter_h
#define PIDGaussianFilter_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 高斯滤波器
 * 对应Python: scipy.ndimage.filters.gaussian_filter1d
 */
@interface PIDGaussianFilter : NSObject

/**
 * 执行一维高斯滤波
 * @param data 输入数据
 * @param sigma 高斯核标准差
 * @param mode 边界处理模式: 'constant'（默认）, 'reflect', 'nearest'
 * @return 滤波后的数据
 */
- (NSArray<NSNumber *> *)filter:(NSArray<NSNumber *> *)data
                         sigma:(double)sigma
                          mode:(NSString *)mode;

/**
 * 便捷方法：使用默认参数的高斯滤波
 */
- (NSArray<NSNumber *> *)filter:(NSArray<NSNumber *> *)data sigma:(double)sigma;

@end

NS_ASSUME_NONNULL_END

#endif /* PIDGaussianFilter_h */
