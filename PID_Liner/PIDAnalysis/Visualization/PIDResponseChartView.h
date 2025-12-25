//
//  PIDResponseChartView.h
//  PID_Liner
//
//  Created by Claude on 2025/12/25.
//  PID响应图表视图 - 对应Python的response plot
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PIDResponseChartView;

/**
 * 响应数据模型
 * 对应Python中的stack_response结果
 */
@interface PIDResponseData : NSObject

// 时间轴 (秒)
@property (nonatomic, strong) NSArray<NSNumber *> *time;

// 阶跃响应数据
@property (nonatomic, strong) NSArray<NSNumber *> *stepResponse;

// 响应 vs 油门的热力图数据 [throttleIdx][responseIdx]
@property (nonatomic, strong) NSArray<NSArray<NSNumber *> *> *responseHeatmap;

// 油门轴 (0-100%)
@property (nonatomic, strong) NSArray<NSNumber *> *throttleAxis;

// 响应时间轴 (秒)
@property (nonatomic, strong) NSArray<NSNumber *> *responseTimeAxis;

// 轴名称 (roll/pitch/yaw)
@property (nonatomic, copy) NSString *axisName;

// PID参数字符串
@property (nonatomic, copy) NSString *pidString;

/**
 * 创建响应数据
 */
+ (instancetype)dataWithTime:(NSArray<NSNumber *> *)time
                stepResponse:(NSArray<NSNumber *> *)stepResponse
             responseHeatmap:(nullable NSArray<NSArray<NSNumber *> *> *)responseHeatmap
                 throttleAxis:(nullable NSArray<NSNumber *> *)throttleAxis
            responseTimeAxis:(nullable NSArray<NSNumber *> *)responseTimeAxis
                    axisName:(NSString *)axisName
                  pidString:(NSString *)pidString;

@end

/**
 * PID响应图表视图
 *
 * 布局（对应Python的subplot结构）:
 * ┌─────────────────────────────────────┐
 * │           Gyro vs Input             │  ← 顶部折线图
 * ├─────────────────────────────────────┤
 * │      Response vs Throttle           │  ← 中部热力图
 * ├─────────────────────────────────────┤
 * │         Step Response               │  ← 底部阶跃响应图
 * └─────────────────────────────────────┘
 */
@interface PIDResponseChartView : UIView

// 响应数据（低输入）
@property (nonatomic, strong) PIDResponseData *lowResponseData;

// 响应数据（高输入）
@property (nonatomic, strong, nullable) PIDResponseData *highResponseData;

// 输入阈值
@property (nonatomic, assign) double threshold;

/**
 * 初始化
 */
- (instancetype)initWithFrame:(CGRect)frame;

/**
 * 设置响应数据并刷新
 */
- (void)setLowResponseData:(PIDResponseData *)lowData
          highResponseData:(nullable PIDResponseData *)highData;

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
