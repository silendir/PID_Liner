//
//  test_session_selector.m
//  PID_Liner
//
//  测试Session识别和选择功能
//

#import <Foundation/Foundation.h>
#import "BlackboxDecoder.h"

// 打印Session列表
void printSessions(NSArray<BBLSessionInfo *> *sessions) {
    NSLog(@"\n╔════════════════════════════════════════════════════════════════╗");
    NSLog(@"║  BBL文件Session列表                                           ║");
    NSLog(@"╚════════════════════════════════════════════════════════════════╝\n");
    
    if (sessions.count == 0) {
        NSLog(@"❌ 未找到任何Session");
        return;
    }
    
    NSLog(@"共找到 %lu 个Session:\n", (unsigned long)sessions.count);
    
    for (BBLSessionInfo *session in sessions) {
        NSLog(@"【Session %ld】", (long)session.sessionIndex + 1);
        NSLog(@"  起始偏移: %lu bytes", (unsigned long)session.startOffset);
        NSLog(@"  结束偏移: %lu bytes", (unsigned long)session.endOffset);
        NSLog(@"  数据大小: %lu bytes", (unsigned long)(session.endOffset - session.startOffset));
        NSLog(@"  帧数量: %ld", (long)session.frameCount);
        NSLog(@"  持续时间: %.3f 秒", session.duration);
        NSLog(@"  描述: %@", session.description);
        NSLog(@"");
    }
}

// 测试Session解码
void testSessionDecoding(NSString *bblFile, NSString *outputDir) {
    NSLog(@"\n╔════════════════════════════════════════════════════════════════╗");
    NSLog(@"║  测试Session解码功能                                          ║");
    NSLog(@"╚════════════════════════════════════════════════════════════════╝\n");
    
    NSLog(@"【测试文件】%@", [bblFile lastPathComponent]);
    
    // 创建解码器
    BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];
    
    // 1. 列出所有Session
    NSLog(@"\n【步骤1】列出所有Session");
    NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    NSArray<BBLSessionInfo *> *sessions = [decoder listSessions:bblFile];
    printSessions(sessions);
    
    if (sessions.count == 0) {
        NSLog(@"❌ 无法继续测试");
        return;
    }
    
    // 2. 解码所有Session
    NSLog(@"\n【步骤2】解码所有Session");
    NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    NSString *outputAll = [outputDir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@_all_sessions.csv", 
                           [[bblFile lastPathComponent] stringByDeletingPathExtension]]];
    
    BOOL success = [decoder decodeFile:bblFile outputPath:outputAll];
    if (success) {
        NSLog(@"✅ 解码成功: %@", [outputAll lastPathComponent]);
        
        // 显示文件信息
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputAll error:nil];
        NSLog(@"  文件大小: %.2f KB", [attrs fileSize] / 1024.0);
    } else {
        NSLog(@"❌ 解码失败: %@", decoder.lastErrorMessage);
    }
    
    // 3. 解码第一个Session
    if (sessions.count > 0) {
        NSLog(@"\n【步骤3】解码第一个Session");
        NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        NSString *outputSession1 = [outputDir stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@_session_1.csv", 
                                    [[bblFile lastPathComponent] stringByDeletingPathExtension]]];
        
        success = [decoder decodeFile:bblFile outputPath:outputSession1 sessionIndex:0];
        if (success) {
            NSLog(@"✅ 解码成功: %@", [outputSession1 lastPathComponent]);
            
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputSession1 error:nil];
            NSLog(@"  文件大小: %.2f KB", [attrs fileSize] / 1024.0);
        } else {
            NSLog(@"❌ 解码失败: %@", decoder.lastErrorMessage);
        }
    }
    
    // 4. 如果有多个Session，解码第二个Session
    if (sessions.count > 1) {
        NSLog(@"\n【步骤4】解码第二个Session");
        NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        NSString *outputSession2 = [outputDir stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@_session_2.csv", 
                                    [[bblFile lastPathComponent] stringByDeletingPathExtension]]];
        
        success = [decoder decodeFile:bblFile outputPath:outputSession2 sessionIndex:1];
        if (success) {
            NSLog(@"✅ 解码成功: %@", [outputSession2 lastPathComponent]);
            
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputSession2 error:nil];
            NSLog(@"  文件大小: %.2f KB", [attrs fileSize] / 1024.0);
        } else {
            NSLog(@"❌ 解码失败: %@", decoder.lastErrorMessage);
        }
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"\n╔════════════════════════════════════════════════════════════════╗");
        NSLog(@"║  BlackboxDecoder Session选择功能测试                         ║");
        NSLog(@"╚════════════════════════════════════════════════════════════════╝\n");
        
        // 测试文件路径
        NSString *testFile1 = @"/Volumes/闪迪2T/PID_Liner/003.bbl";
        NSString *testFile2 = @"/Volumes/闪迪2T/PID_Liner/good_tune.BBL";
        NSString *outputDir = @"/Volumes/闪迪2T/PID_Liner/validation";
        
        // 测试003.bbl (2个Session)
        testSessionDecoding(testFile1, outputDir);
        
        // 测试good_tune.BBL (1个Session)
        testSessionDecoding(testFile2, outputDir);
        
        NSLog(@"\n✅ 所有测试完成！");
    }
    return 0;
}

