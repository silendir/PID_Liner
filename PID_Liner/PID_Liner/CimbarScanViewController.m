//
//  CimbarScanViewController.m
//  PID_Liner
//
//  相机扫码接收 .bbl（R2）。帧回调队列 = 喂帧队列 = 完成检测队列（会话非线程安全，
//  全部收敛到 frameQueue 串行执行；UI 更新一律跳回主线程）。
//

#import "CimbarScanViewController.h"
#import "CimbarScanSession.h"
#import "BBLImportService.h"
#import <AVFoundation/AVFoundation.h>

@interface CimbarScanViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) dispatch_queue_t frameQueue;      // 喂帧+会话状态唯一队列
@property (nonatomic, strong) CimbarScanSession *scanSession;
@property (nonatomic, strong) UILabel *stageLabel;              // 阶段说明(对准/已锁定/完成)
@property (nonatomic, strong) UIProgressView *progressView;     // 接收进度条
@property (nonatomic, strong) UILabel *statusLabel;             // 进度/诊断文本
@property (nonatomic, copy) NSString *lastShownProgress;        // 节流:内容变化才刷 UI
@property (nonatomic, assign) BOOL lastShownLocked;
@property (nonatomic, assign) double lastShownProgressValue;
@property (nonatomic, assign) BOOL finished;                    // 完成流程只跑一次
@end

@implementation CimbarScanViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"扫码接收";
    self.view.backgroundColor = [UIColor blackColor];

    _frameQueue = dispatch_queue_create("pidliner.cimbar.frame", DISPATCH_QUEUE_SERIAL);
    _scanSession = [[CimbarScanSession alloc] initWithMode:CimbarScanModeB];
    if (!_scanSession) {
        [self showErrorAlert:@"初始化解码器失败"];
        return;
    }

    [self setupUI];
    [self requestCameraAndStart];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _previewLayer.frame = self.view.bounds;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCapture];
}

#pragma mark - UI

- (void)setupUI {
    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:nil];  // session 出来前先占位
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:_previewLayer];

    // 底部信息区:阶段说明 + 进度条 + 明细文本,统一垫黑色半透明底
    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    panel.layer.cornerRadius = 12;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:panel];

    _stageLabel = [[UILabel alloc] init];
    _stageLabel.text = @"📷 对准电脑屏幕上的闪烁码";
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:_stageLabel];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progressTintColor = [UIColor systemGreenColor];
    _progressView.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25];
    _progressView.progress = 0;
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:_progressView];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"保持稳定,等待信号锁定";
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [panel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [_stageLabel.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [_stageLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [_stageLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],

        [_progressView.topAnchor constraintEqualToAnchor:_stageLabel.bottomAnchor constant:10],
        [_progressView.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [_progressView.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [_progressView.heightAnchor constraintEqualToConstant:6],

        [_statusLabel.topAnchor constraintEqualToAnchor:_progressView.bottomAnchor constant:8],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-12]
    ]];
}

#pragma mark - 相机权限与启动

- (void)requestCameraAndStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self startCapture];
        return;
    }
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        [self showCameraDeniedAlert];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            granted ? [weakSelf startCapture] : [weakSelf showCameraDeniedAlert];
        });
    }];
}

- (void)showCameraDeniedAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"需要相机权限"
                         message:@"扫码接收飞行记录需要使用相机,请到设置中开启"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                             options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [self.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startCapture {
    dispatch_async(_frameQueue, ^{
        NSError *error = nil;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                     mediaType:AVMediaTypeVideo
                                                                      position:AVCaptureDevicePositionBack];
        AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:&error] : nil;
        if (!input) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showErrorAlert:error.localizedDescription ?: @"无法访问相机"];
            });
            return;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        session.sessionPreset = AVCaptureSessionPresetHigh;
        if (![session canAddInput:input]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showErrorAlert:@"相机输入初始化失败"]; });
            return;
        }
        [session addInput:input];

        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        // NV12 双平面,cimbar format=12;丢晚帧防积压
        output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        output.alwaysDiscardsLateVideoFrames = YES;
        [output setSampleBufferDelegate:self queue:self->_frameQueue];
        if (![session canAddOutput:output]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showErrorAlert:@"相机输出初始化失败"]; });
            return;
        }
        [session addOutput:output];

        self->_captureSession = session;
        dispatch_async(dispatch_get_main_queue(), ^{ self->_previewLayer.session = session; });
        [session startRunning];
    });
}

- (void)stopCapture {
    dispatch_async(_frameQueue, ^{
        if (self->_captureSession.isRunning)
            [self->_captureSession stopRunning];
    });
}

#pragma mark - 帧回调（frameQueue）

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (_finished)
        return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    [_scanSession feedPixelBuffer:pixelBuffer];

    if (_scanSession.isDone) {
        _finished = YES;
        [self->_captureSession stopRunning];
        double progress = _scanSession.progress;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_progressView.progress = (float)progress;
            self->_stageLabel.text = @"✅ 接收完成";
            [self finishWithResult:self->_scanSession.result];
        });
        return;
    }

    // 三态阶段 + 进度条 + 明细(值变化才刷主线程)
    BOOL locked = _scanSession.hasLocked;
    double progress = _scanSession.progress;
    NSString *detail = _scanSession.progressString;
    if (locked != _lastShownLocked
        || progress != _lastShownProgressValue
        || ![detail isEqualToString:_lastShownProgress]) {
        _lastShownLocked = locked;
        _lastShownProgressValue = progress;
        _lastShownProgress = detail;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_stageLabel.text = locked ? @"📡 信号已锁定,正在接收" : @"📷 对准电脑屏幕上的闪烁码";
            self->_progressView.progress = locked ? (float)progress : 0;
            if (detail.length > 0)
                self->_statusLabel.text = detail;
        });
    }
}

#pragma mark - 完成:存文件 → BBL 管线

- (void)finishWithResult:(CimbarScanResult *)result {
    if (!result) {
        [self showErrorAlert:@"接收失败,数据不完整"];
        return;
    }
    _statusLabel.text = @"✅ 接收完成";

    // 文件名只留最后一段防路径注入;空名兜底
    NSString *name = result.filename.lastPathComponent;
    if (name.length == 0)
        name = @"received.bbl";
    NSString *path = [[BBLImportService documentsDirectory] stringByAppendingPathComponent:name];
    NSError *writeError = nil;
    if (![result.data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        [self showErrorAlert:[NSString stringWithFormat:@"保存失败:%@", writeError.localizedDescription]];
        return;
    }

    // 先弹系统分享窗,让用户自选用途(存"文件"/AirDrop/相册等);分享完再问是否当 BBL 导入
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                        applicationActivities:nil];
    __weak typeof(self) weakSelf = self;
    share.completionWithItemsHandler = ^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        // ponytail: 分享失败/取消不阻塞导入询问,文件本体已在沙盒
        [s askImportAsBBL:path fileName:name];
    };
    [self presentViewController:share animated:YES completion:nil];
}

/// 分享完成后询问:是否作为 BBL 导入分析管线
- (void)askImportAsBBL:(NSString *)path fileName:(NSString *)name {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"作为 BBL 导入?"
                         message:[NSString stringWithFormat:@"%@ 已接收保存。\n现在导入解码为飞行记录吗?", name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [self importAsBBL:path fileName:name]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"暂不" style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [self.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importAsBBL:(NSString *)path fileName:(NSString *)name {
    _statusLabel.text = @"正在导入解码…";
    NSError *convertError = nil;
    NSArray<BBLImportCSVResult *> *results = [[BBLImportService shared] convertAllSessionsForBBL:path
                                                                                          motorKV:nil
                                                                                         progress:nil
                                                                                           error:&convertError];
    NSUInteger ok = [results filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BBLImportCSVResult *r, NSDictionary *b) { return r.isSuccess; }]].count;

    NSString *title = ok > 0 ? @"导入成功" : @"导入失败";
    NSString *msg = ok > 0
        ? [NSString stringWithFormat:@"%@ · 已解码 %lu 个 Session,可在「☰ 总列表」查看", name.lastPathComponent, (unsigned long)ok]
        : (results.firstObject.errorMessage ?: convertError.localizedDescription ?: @"BBL 解码失败");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [self.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showErrorAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫码接收" message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [self.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
