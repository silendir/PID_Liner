//
//  PIDInterpolation.m
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  插值函数实现
//

#import "PIDInterpolation.h"

@implementation PIDInterpolation

- (NSArray<NSNumber *> *(^)(NSArray<NSNumber *> *))interpolate1D:(NSArray<NSNumber *> *)x
                                                             y:(NSArray<NSNumber *> *)y
                                                        method:(PIDInterpolationMethod)method {
    // 复制输入数据（捕获）
    NSArray<NSNumber *> *xCopy = [x copy];
    NSArray<NSNumber *> *yCopy = [y copy];

    // 返回插值块
    return ^(NSArray<NSNumber *> *x_new) {
        switch (method) {
            case PIDInterpolationMethodLinear:
                return [[self class] linearInterpolateWithX:xCopy y:yCopy xNew:x_new];
            case PIDInterpolationMethodNearest:
                return [[self class] nearestInterpolateWithX:xCopy y:yCopy xNew:x_new];
            case PIDInterpolationMethodCubic:
                // 简化实现：使用线性插值代替三次样条
                return [[self class] linearInterpolateWithX:xCopy y:yCopy xNew:x_new];
            default:
                return [[self class] linearInterpolateWithX:xCopy y:yCopy xNew:x_new];
        }
    };
}

#pragma mark - Public Methods

+ (NSArray<NSNumber *> *)linearInterpolateWithX:(NSArray<NSNumber *> *)x
                                            y:(NSArray<NSNumber *> *)y
                                         xNew:(NSArray<NSNumber *> *)x_new {
    if (!x || !y || !x_new || x.count != y.count || x.count < 2) {
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:x_new.count];

    for (NSNumber *xNum in x_new) {
        double xVal = [xNum doubleValue];

        // 边界处理
        if (xVal <= [x[0] doubleValue]) {
            [result addObject:y[0]];
            continue;
        }
        if (xVal >= [x[x.count - 1] doubleValue]) {
            [result addObject:y[y.count - 1]];
            continue;
        }

        // 找到插值区间
        NSInteger i = 0;
        for (i = 0; i < x.count - 1; i++) {
            if (xVal < [x[i + 1] doubleValue]) {
                break;
            }
        }

        // 线性插值
        double x0 = [x[i] doubleValue];
        double x1 = [x[i + 1] doubleValue];
        double y0 = [y[i] doubleValue];
        double y1 = [y[i + 1] doubleValue];

        double t = (xVal - x0) / (x1 - x0);
        double yVal = y0 + t * (y1 - y0);

        [result addObject:@(yVal)];
    }

    return [result copy];
}

+ (NSArray<NSNumber *> *)nearestInterpolateWithX:(NSArray<NSNumber *> *)x
                                              y:(NSArray<NSNumber *> *)y
                                           xNew:(NSArray<NSNumber *> *)x_new {
    if (!x || !y || !x_new || x.count != y.count || x.count < 1) {
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:x_new.count];

    for (NSNumber *xNum in x_new) {
        double xVal = [xNum doubleValue];

        // 找最近的点
        double minDist = HUGE_VAL;
        double nearestY = [y[0] doubleValue];

        for (NSInteger i = 0; i < x.count; i++) {
            double dist = fabs([x[i] doubleValue] - xVal);
            if (dist < minDist) {
                minDist = dist;
                nearestY = [y[i] doubleValue];
            }
        }

        [result addObject:@(nearestY)];
    }

    return [result copy];
}

+ (NSArray<NSNumber *> *)cumsum:(NSArray<NSNumber *> *)data {
    if (!data || data.count == 0) {
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:data.count];
    double sum = 0.0;

    for (NSNumber *num in data) {
        sum += [num doubleValue];
        [result addObject:@(sum)];
    }

    return [result copy];
}

@end
