//
//  PIDCLIGenerator.h
//  PID_Liner
//
//  第5层：CLI 命令生成
//

#import <Foundation/Foundation.h>
#import "PIDRecommendationEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// CLI 命令生成器
@interface PIDCLIGenerator : NSObject

/**
 * 生成 CLI 命令文本
 *
 * @param rollResult  Roll轴推荐结果
 * @param pitchResult Pitch轴推荐结果
 * @param yawResult   Yaw轴推荐结果
 * @param currentPID  当前PID配置 (从BBL Header解析得到)
 * @param firmwareVersionCode 固件版本代码 (如 405 = BF 4.5)
 * @return 可粘贴到 Betaflight Configurator CLI 的命令文本
 */
+ (NSString *)generateCLICommands:(nullable PIDTuningResult *)rollResult
                      pitchResult:(nullable PIDTuningResult *)pitchResult
                        yawResult:(nullable PIDTuningResult *)yawResult
                        currentPID:(nullable NSDictionary *)currentPID
                   firmwareVersion:(NSInteger)versionCode;

/**
 * 安全检查：参数变更是否在合理范围内
 * @return YES 如果安全
 */
+ (BOOL)validateChanges:(PIDValues *)oldValues
                 newValues:(PIDValues *)newValues;

@end

NS_ASSUME_NONNULL_END
