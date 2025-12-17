//
//  test_decoder.m
//  命令行测试黑匣子解码器 - 验证版本
//  功能: 生成iOS版本的CSV输出,用于与C程序输出对比验证
//

#import <Foundation/Foundation.h>
#import "BlackboxDecoder.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔍 BlackboxDecoder验证工具 - iOS版本");
        NSLog(@"main() - 开始执行验证程序");
        NSLog(@"");

        // 定义测试文件 - 用于验证
        NSArray *testFiles = @[
            @{
                @"input": @"/Volumes/闪迪2T/PID_Liner/003.bbl",
                @"output": @"/Volumes/闪迪2T/PID_Liner/validation/ios_output_003.csv"
            },
            @{
                @"input": @"/Volumes/闪迪2T/PID_Liner/good_tune.BBL",
                @"output": @"/Volumes/闪迪2T/PID_Liner/validation/ios_output_good_tune.csv"
            }
        ];

        // 创建解码器
        NSLog(@"创建BlackboxDecoder实例");
        BlackboxDecoder *decoder = [[BlackboxDecoder alloc] init];

        NSInteger successCount = 0;
        NSInteger failureCount = 0;

        // 处理每个测试文件
        for (NSDictionary *testFile in testFiles) {
            NSString *inputPath = testFile[@"input"];
            NSString *outputPath = testFile[@"output"];

            NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
            NSLog(@"【处理文件】%@", [inputPath lastPathComponent]);
            NSLog(@"输入路径: %@", inputPath);
            NSLog(@"输出路径: %@", outputPath);

            // 检查输入文件是否存在
            if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
                NSLog(@"❌ 输入文件不存在: %@", inputPath);
                failureCount++;
                NSLog(@"");
                continue;
            }

            // 获取输入文件大小
            NSError *error;
            NSDictionary *inputAttributes = [[NSFileManager defaultManager]
                attributesOfItemAtPath:inputPath error:&error];

            if (inputAttributes) {
                NSNumber *inputSize = inputAttributes[NSFileSize];
                NSLog(@"✅ 输入文件存在 (大小: %.2f MB)",
                    [inputSize doubleValue] / (1024.0 * 1024.0));
            }

            // 记录开始时间
            NSDate *startTime = [NSDate date];
            NSLog(@"🔄 开始解码... (时间: %@)", startTime);

            // 执行解码
            BOOL success = [decoder decodeFile:inputPath outputPath:outputPath];

            // 计算执行时间
            NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:startTime];

            if (success) {
                NSLog(@"✅ 解码成功 (耗时: %.2f秒)", duration);

                // 获取输出文件信息
                NSDictionary *outputAttributes = [[NSFileManager defaultManager]
                    attributesOfItemAtPath:outputPath error:&error];

                if (outputAttributes) {
                    NSNumber *fileSize = outputAttributes[NSFileSize];
                    NSLog(@"📊 输出文件大小: %.2f MB",
                        [fileSize doubleValue] / (1024.0 * 1024.0));

                    // 统计行数
                    NSString *csvContent = [NSString stringWithContentsOfFile:outputPath
                        encoding:NSUTF8StringEncoding error:&error];

                    if (csvContent) {
                        NSArray *lines = [csvContent componentsSeparatedByString:@"\n"];
                        NSLog(@"📈 CSV行数: %lu", (unsigned long)lines.count);

                        // 显示前3行
                        NSLog(@"📝 CSV文件头部:");
                        NSInteger maxLines = MIN(3, lines.count);
                        for (NSInteger i = 0; i < maxLines; i++) {
                            NSString *line = lines[i];
                            if (line.length > 100) {
                                NSLog(@"  %@...", [line substringToIndex:100]);
                            } else {
                                NSLog(@"  %@", line);
                            }
                        }
                    } else {
                        NSLog(@"⚠️  无法读取输出文件内容: %@", error.localizedDescription);
                    }
                } else {
                    NSLog(@"⚠️  无法获取输出文件属性: %@", error.localizedDescription);
                }

                successCount++;

            } else {
                NSLog(@"❌ 解码失败");
                if (decoder.lastErrorMessage) {
                    NSLog(@"错误信息: %@", decoder.lastErrorMessage);
                }
                failureCount++;
            }

            NSLog(@"");
        }

        // 打印总结
        NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        NSLog(@"【验证总结】");
        NSLog(@"✅ 成功: %ld 个文件", (long)successCount);
        NSLog(@"❌ 失败: %ld 个文件", (long)failureCount);
        NSLog(@"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

        if (failureCount == 0) {
            NSLog(@"🎉 所有文件解码成功！");
            NSLog(@"main() - 验证程序执行完成,返回0");
            return 0;
        } else {
            NSLog(@"⚠️  部分文件解码失败");
            NSLog(@"main() - 验证程序执行完成,返回1");
            return 1;
        }
    }
}