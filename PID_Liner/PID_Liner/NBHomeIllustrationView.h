//
//  NBHomeIllustrationView.h
//  PID_Liner
//
//  首页 V3 · 栏目矢量示意图(CAShapeLayer 描线场景) + 导航自绘图标
//  场景几何照搬 design-demos/首页改版-明亮示意图版.html 的 SVG path
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NBHomeScene) {
    NBHomeSceneIndependent,   // 黑匣子(BBL+LED)→读出射线→曲线卡+超调标注 · 蓝系
    NBHomeSceneIteration,     // 迷你四轴→箭头→三轮渐紧曲线+R1→R3轮次链 · 青绿系
    NBHomeSceneCrashMini,     // 摔断四轴俯视小场景(38pt 横条用) · 珊瑚系
};

@interface NBHomeIllustrationView : UIView

/// 场景决定配色(自取 NBTheme 令牌),path 按 bounds 现算(矢量自适应)
- (instancetype)initWithFrame:(CGRect)frame scene:(NBHomeScene)scene;

/// 一次性描线入场(strokeEnd 0→1 错峰 + 标注淡入);幂等,返场不重播
- (void)playIntroAnimationOnce;

/// 导航图标:标准蓝牙符号 ᛒ(模板模式,吃 tint)
+ (UIImage *)navBluetoothImage;

/// 导航图标:黑匣子匣体 + 红✕(清空语义;双色必须 AlwaysOriginal)
+ (UIImage *)navEraseBlackboxImage;

@end

NS_ASSUME_NONNULL_END
