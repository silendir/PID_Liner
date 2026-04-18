//
//  PIDHeatmapView.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  热力图视图 - 使用Core Graphics绘制，对应Python的pcolormesh
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 热力图配置
 */
@interface PIDHeatmapConfig : NSObject

// 颜色映射方案
@property (nonatomic, copy) NSArray<UIColor *> *colors;

// 最小/最大值（用于颜色归一化）
@property (nonatomic, assign) double minValue;
@property (nonatomic, assign) double maxValue;

// 是否使用对数刻度
@property (nonatomic, assign) BOOL useLogScale;

// 是否显示颜色条
@property (nonatomic, assign) BOOL showColorBar;

// 标签配置
@property (nonatomic, copy) NSString *xAxisLabel;
@property (nonatomic, copy) NSString *yAxisLabel;
@property (nonatomic, copy) NSString *title;

/**
 * 默认配置 - Blues配色
 */
+ (instancetype)defaultConfig;

/**
 * 热力图配色 - Orange配色（用于高输入响应）
 */
+ (instancetype)orangeConfig;

/**
 * 自定义渐变配色
 * @param startColor 起始颜色（低值）
 * @param endColor 结束颜色（高值）
 * @param steps 颜色步数
 */
+ (instancetype)gradientConfigFromColor:(UIColor *)startColor
                                toColor:(UIColor *)endColor
                                  steps:(NSInteger)steps;

@end

/**
 * 热力图视图
 *
 * 功能：
 * - 绘制2D热力图（对应Python的plt.pcolormesh）
 * - 支持线性/对数刻度
 * - 支持颜色条
 * - 支持双指缩放/平移
 */
@interface PIDHeatmapView : UIView

// 数据 (2D数组: [row][col])
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *data;

// X轴刻度值
@property (nonatomic, strong) NSArray<NSNumber *> *xAxisValues;

// Y轴刻度值
@property (nonatomic, strong) NSArray<NSNumber *> *yAxisValues;

// 热力图配置
@property (nonatomic, strong) PIDHeatmapConfig *config;

/**
 * 初始化
 */
- (instancetype)initWithFrame:(CGRect)frame config:(PIDHeatmapConfig *)config;

/**
 * 刷新显示
 */
- (void)refreshDisplay;

/**
 * 导出为图片
 */
- (UIImage *)exportImage;

@end

NS_ASSUME_NONNULL_END
