//
//  NBTheme.m
//  PID_Liner
//

#import "NBTheme.h"

/// #RRGGBB → UIColor(非动态,首页固定明亮)
static UIColor *NBHex(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

@implementation NBTheme

+ (UIColor *)bg         { return NBHex(0xF6F8FD); }
+ (UIColor *)card       { return NBHex(0xFFFFFF); }
+ (UIColor *)ink        { return NBHex(0x0B1230); }
+ (UIColor *)dim        { return NBHex(0x5A6480); }
+ (UIColor *)faint      { return NBHex(0x9AA3BC); }
+ (UIColor *)hairline   { return NBHex(0xE6EAF4); }

+ (UIColor *)accentBlue      { return NBHex(0x2B5BFF); }
+ (UIColor *)accentBlueTint  { return NBHex(0xEDF2FF); }
+ (UIColor *)accentBlueLine  { return NBHex(0xC9D6F8); }

+ (UIColor *)accentGreen      { return NBHex(0x0FA47A); }
+ (UIColor *)accentGreenTint  { return NBHex(0xE7F8F2); }
+ (UIColor *)accentGreenLine  { return NBHex(0xBCE7D8); }

+ (UIColor *)accentCoral      { return NBHex(0xF04E4E); }
+ (UIColor *)accentCoralTint  { return NBHex(0xFDEEED); }
+ (UIColor *)accentCoralLine  { return NBHex(0xF6CDCB); }

+ (UIColor *)proOrange { return NBHex(0xF08A3C); }
+ (UIColor *)proRed    { return NBHex(0xF04E4E); }

+ (UIFont *)serifBold:(CGFloat)size {
    UIFont *f = [UIFont fontWithName:@"SongtiSC-Bold" size:size];
    return f ?: [UIFont systemFontOfSize:size weight:UIFontWeightBold];
}

@end
