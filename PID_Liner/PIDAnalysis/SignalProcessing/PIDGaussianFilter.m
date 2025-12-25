//
//  PIDGaussianFilter.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  高斯滤波器实现
//

#import "PIDGaussianFilter.h"
#import <Accelerate/Accelerate.h>

@implementation PIDGaussianFilter

- (NSArray<NSNumber *> *)filter:(NSArray<NSNumber *> *)data sigma:(double)sigma {
    return [self filter:data sigma:sigma mode:@"constant"];
}

- (NSArray<NSNumber *> *)filter:(NSArray<NSNumber *> *)data sigma:(double)sigma mode:(NSString *)mode {
    if (!data || data.count == 0 || sigma < 0.01) {
        return data ?: @[];
    }

    NSInteger n = data.count;

    // 核大小 = 6 * sigma（确保是奇数）
    NSInteger kernelSize = (NSInteger)(sigma * 6) | 1;
    if (kernelSize < 3) kernelSize = 3;

    // 生成高斯核
    float *kernel = (float *)malloc(kernelSize * sizeof(float));
    [self generateGaussianKernel:kernel size:kernelSize sigma:sigma];

    // 准备输入和输出
    float *input = (float *)malloc(n * sizeof(float));
    float *output = (float *)malloc(n * sizeof(float));

    for (NSInteger i = 0; i < n; i++) {
        input[i] = [data[i] floatValue];
    }

    // 使用vDSP进行卷积
    vDSP_conv(input, 1, kernel, 1, output, 1, n, kernelSize);

    // 转换为输出数组
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:n];
    for (NSInteger i = 0; i < n; i++) {
        [result addObject:@(output[i])];
    }

    free(kernel);
    free(input);
    free(output);

    return [result copy];
}

#pragma mark - Private Methods

/**
 * 生成高斯核
 * g(x) = (1 / (sigma * sqrt(2*pi))) * exp(-x^2 / (2*sigma^2))
 */
- (void)generateGaussianKernel:(float *)kernel size:(NSInteger)size sigma:(double)sigma {
    NSInteger half = size / 2;
    double scale = 1.0 / (sigma * sqrt(2.0 * M_PI));
    double scale2 = 2.0 * sigma * sigma;

    double sum = 0.0;
    for (NSInteger i = 0; i < size; i++) {
        double x = i - half;
        double val = scale * exp(-(x * x) / scale2);
        kernel[i] = (float)val;
        sum += val;
    }

    // 归一化
    if (sum > 1e-9) {
        for (NSInteger i = 0; i < size; i++) {
            kernel[i] /= (float)sum;
        }
    }
}

@end
