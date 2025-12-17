//
//  ViewController.m
//  PID_Liner
//
//  Created by 梁隽 on 2025/11/13.
//

#import "ViewController.h"
#import "BlackboxDecoder.h"

@interface ViewController ()
@property (nonatomic, strong) BlackboxDecoder *decoder;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
    self.decoder = [[BlackboxDecoder alloc] init];
}

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // 转换按钮
    self.convertButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.convertButton setTitle:@"转换 BBL 到 CSV" forState:UIControlStateNormal];
    self.convertButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    [self.convertButton addTarget:self action:@selector(convertButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.convertButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.convertButton];
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"准备就绪";
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:16];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];
    
    // 日志文本视图
    self.logTextView = [[UITextView alloc] init];
    self.logTextView.editable = NO;
    self.logTextView.font = [UIFont fontWithName:@"Menlo" size:12];
    self.logTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logTextView.layer.cornerRadius = 8;
    self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logTextView];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [self.convertButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.convertButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],
        [self.convertButton.widthAnchor constraintEqualToConstant:200],
        [self.convertButton.heightAnchor constraintEqualToConstant:50],
        
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.convertButton.bottomAnchor constant:20],
        
        [self.logTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.logTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.logTextView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:20],
        [self.logTextView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20]
    ]];
}

- (void)convertButtonTapped:(UIButton *)sender {
    [self convertBBLToCSV];
}

- (void)convertBBLToCSV {
    NSLog(@"convertBBLToCSV() - 开始转换");

    // 获取Documents目录
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];

    // 从Documents目录读取003.bbl文件
    NSString *inputPath = [documentsDirectory stringByAppendingPathComponent:@"003.bbl"];

    // 如果Documents目录没有，尝试从Bundle读取
    if (![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
        inputPath = [[NSBundle mainBundle] pathForResource:@"003" ofType:@"bbl"];
    }

    if (!inputPath || ![[NSFileManager defaultManager] fileExistsAtPath:inputPath]) {
        self.statusLabel.text = @"错误: 找不到测试文件 003.bbl";
        NSLog(@"❌ 找不到003.bbl文件");
        return;
    }

    NSLog(@"  输入文件: %@", inputPath);

    // 设置输出目录 (对应C程序的--output-dir参数)
    self.decoder.outputDirectory = documentsDirectory;

    self.statusLabel.text = @"正在转换...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 获取log数量 (对应C程序的log->logCount)
        int logCount = [self.decoder getLogCount:inputPath];

        if (logCount <= 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = @"转换失败: 无法读取BBL文件";
            });
            return;
        }

        // 解码所有log (对应C程序的循环解码)
        BOOL allSuccess = YES;
        NSMutableString *resultMessage = [NSMutableString string];

        for (int logIndex = 0; logIndex < logCount; logIndex++) {
            int result = [self.decoder decodeFlightLog:inputPath logIndex:logIndex];

            if (result == 0) {
                // 生成的CSV文件名 (对应C程序的命名规则)
                NSString *basename = [[inputPath lastPathComponent] stringByDeletingPathExtension];
                NSString *csvFilename = [NSString stringWithFormat:@"%@.%02d.csv", basename, logIndex + 1];
                [resultMessage appendFormat:@"✓ 生成: %@\n", csvFilename];
            } else {
                allSuccess = NO;
                [resultMessage appendFormat:@"✗ Log %d 解码失败\n", logIndex + 1];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (allSuccess) {
                self.statusLabel.text = [NSString stringWithFormat:@"转换成功! 共生成 %d 个CSV文件", logCount];
                self.logTextView.text = resultMessage;

                // 显示第一个CSV文件的路径
                NSString *basename = [[inputPath lastPathComponent] stringByDeletingPathExtension];
                NSString *firstCsvPath = [documentsDirectory stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"%@.01.csv", basename]];
                [self showConversionResult:firstCsvPath];
            } else {
                self.statusLabel.text = @"部分转换失败";
                self.logTextView.text = resultMessage;
            }
        });
    });
}

- (void)showConversionResult:(NSString *)outputPath {
    NSError *error;
    NSString *csvContent = [NSString stringWithContentsOfFile:outputPath 
                                                    encoding:NSUTF8StringEncoding 
                                                       error:&error];
    
    if (csvContent) {
        // 显示前几行
        NSArray *lines = [csvContent componentsSeparatedByString:@"\n"];
        NSMutableString *displayText = [NSMutableString string];
        
        NSInteger maxLines = MIN(20, lines.count);
        for (NSInteger i = 0; i < maxLines; i++) {
            [displayText appendFormat:@"%@\n", lines[i]];
        }
        
        if (lines.count > maxLines) {
            [displayText appendFormat:@"\n... 还有 %ld 行数据 ...", (long)(lines.count - maxLines)];
        }
        
        self.logTextView.text = displayText;
    } else {
        self.logTextView.text = [NSString stringWithFormat:@"无法读取输出文件: %@", error.localizedDescription];
    }
    
    // 显示文件位置
    NSLog(@"CSV文件已保存到: %@", outputPath);
}

@end
