//
//  BBLHeaderParser.m
//  PID_Liner
//

#import "BBLHeaderParser.h"

@implementation BBLHeaderParser

/// 读前 32KB,解析所有 "H field:value" 行
+ (NSDictionary<NSString *, NSString *> *)parseHeaderFromFile:(NSString *)bblPath {
    if (!bblPath) return nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:bblPath];
    if (!handle) return nil;
    NSData *data = [handle readDataOfLength:32768];  // 前32KB cover BF header
    [handle closeFile];
    if (!data || data.length == 0) return nil;

    // header 段是文本,优先 UTF8;若二进制帧混入破坏UTF8,降级ASCII
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    if (!text) return nil;

    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![trimmed hasPrefix:@"H "]) continue;
        // "H field:value"(field 可含空格,如 "Firmware revision" / "Field I name")
        NSString *body = [trimmed substringFromIndex:2];
        NSRange colon = [body rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *field = [[body substringToIndex:colon.location]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[body substringFromIndex:colon.location + 1]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (field.length > 0 && value.length > 0) {
            result[field] = value;
        }
    }
    return result.count > 0 ? [result copy] : nil;
}

@end
