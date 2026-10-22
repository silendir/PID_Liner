//
//  NBTheme.h
//  PID_Liner
//
//  首页 V3 明亮改版 · 设计令牌(非动态色,首页固定明亮;子页照旧跟随系统)
//  视觉基准: design-demos/首页改版-明亮示意图版.html
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NBTheme : NSObject

/// 底色系
+ (UIColor *)bg;         // #F6F8FD 云白
+ (UIColor *)card;       // #FFFFFF
+ (UIColor *)ink;        // #0B1230 主文字
+ (UIColor *)dim;        // #5A6480 次文字
+ (UIColor *)faint;      // #9AA3BC 弱文字
+ (UIColor *)hairline;   // #E6EAF4 细描边

/// 独立分析 · 蓝系
+ (UIColor *)accentBlue;      // #2B5BFF
+ (UIColor *)accentBlueTint;  // #EDF2FF
+ (UIColor *)accentBlueLine;  // #C9D6F8

/// 方案迭代 · 青绿系
+ (UIColor *)accentGreen;      // #0FA47A
+ (UIColor *)accentGreenTint;  // #E7F8F2
+ (UIColor *)accentGreenLine;  // #BCE7D8

/// 炸机诊断 · 珊瑚系
+ (UIColor *)accentCoral;      // #F04E4E
+ (UIColor *)accentCoralTint;  // #FDEEED
+ (UIColor *)accentCoralLine;  // #F6CDCB

/// PRO 徽章渐变两端
+ (UIColor *)proOrange;  // #F08A3C
+ (UIColor *)proRed;     // #F04E4E

/// 衬线标题字体(中文衬线 SongtiSC-Bold,iOS 内置;缺失回退系统粗体)
+ (UIFont *)serifBold:(CGFloat)size;

@end

NS_ASSUME_NONNULL_END
