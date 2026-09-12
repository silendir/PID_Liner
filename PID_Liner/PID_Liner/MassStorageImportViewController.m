//
//  MassStorageImportViewController.m — 蓝牙取数五态状态机
//
//  流程:iPhone BLE 连飞控(串口桥) → 发 MSP_SET_REBOOT(rebootType=MSC)
//  → 飞控重启为 USB U 盘(BLE 断开属预期) → 用户插 USB 线 → 系统文件选择器
//  选 .BBL → 复制进沙盒 → BBLImportService 导入。
//

#import "MassStorageImportViewController.h"
#import "FCBluetoothService.h"
#import "BBLImportService.h"
#import "DataflashDownloader.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSUInteger, MscStage) {
    MscStageScanning   = 0,  // 态1 设备列表
    MscStageConnecting = 1,  // 态2 连接中
    MscStageConnected  = 2,  // 态3 已连接,激活按钮
    MscStageActivated  = 3,  // 态4 已激活,插线引导
    MscStageImported   = 4,  // 态5 导入结果
};

@interface MassStorageImportViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UITableView *deviceTable;
@property (nonatomic, strong) UIButton *actionButton;     // 态3 激活 / 态4 选文件
@property (nonatomic, strong) UIButton *downloadButton;   // 态3 蓝牙直下 / 下载中变取消
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) DataflashDownloader *downloader;
@property (nonatomic, strong) NSMutableArray<FCBleDevice *> *devices;
@property (nonatomic, strong) FCBleDevice *selectedDevice;
@property (nonatomic, assign) MscStage stage;
@end

@implementation MassStorageImportViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"蓝牙取数";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.devices = [NSMutableArray array];
    [self setupUI];
    [self bindBluetoothEvents];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self enterStage:MscStageScanning];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    FCBluetoothService *ble = [FCBluetoothService shared];
    [self.downloader cancel];  // 下载中离开页面 = 中止
    [ble stopScan];
    ble.onDevicesChanged = nil;
    ble.onDisconnected = nil;
    ble.onStateChanged = nil;
    // 离开页面断连(激活成功后飞控已自行重启,这里兜底)
    [ble disconnect];
}

#pragma mark - UI

- (void)setupUI {
    _stageLabel = [[UILabel alloc] init];
    _stageLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.numberOfLines = 0;
    _stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_stageLabel];

    _deviceTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _deviceTable.dataSource = self;
    _deviceTable.delegate = self;
    _deviceTable.translatesAutoresizingMaskIntoConstraints = NO;
    [_deviceTable registerClass:[UITableViewCell class] forCellReuseIdentifier:@"BleDeviceCell"];
    [self.view addSubview:_deviceTable];

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _actionButton.layer.cornerRadius = 12;
    _actionButton.backgroundColor = [UIColor systemBlueColor];
    [_actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _actionButton.contentEdgeInsets = UIEdgeInsetsMake(14, 24, 14, 24);
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_actionButton addTarget:self action:@selector(actionButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_actionButton];

    _downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _downloadButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _downloadButton.layer.cornerRadius = 12;
    _downloadButton.layer.borderWidth = 1.5;
    _downloadButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    [_downloadButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    _downloadButton.contentEdgeInsets = UIEdgeInsetsMake(14, 24, 14, 24);
    _downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_downloadButton addTarget:self action:@selector(downloadButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_downloadButton];

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.hidden = YES;
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_progressView];

    [NSLayoutConstraint activateConstraints:@[
        [_stageLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [_stageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_stageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        [_deviceTable.topAnchor constraintEqualToAnchor:_stageLabel.bottomAnchor constant:12],
        [_deviceTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_deviceTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_deviceTable.bottomAnchor constraintEqualToAnchor:_actionButton.topAnchor constant:-12],

        [_actionButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_actionButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],

        [_downloadButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_downloadButton.bottomAnchor constraintEqualToAnchor:_actionButton.topAnchor constant:-12],

        [_progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_progressView.bottomAnchor constraintEqualToAnchor:_downloadButton.topAnchor constant:-16]
    ]];
}

/// 订阅 BLE 单例事件(单例在页面消失时摘回调,避免悬空)
- (void)bindBluetoothEvents {
    FCBluetoothService *ble = [FCBluetoothService shared];
    __weak typeof(self) weakSelf = self;
    ble.onDevicesChanged = ^(NSArray<FCBleDevice *> *devices) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s.devices removeAllObjects];
        [s.devices addObjectsFromArray:devices];
        [s.deviceTable reloadData];
        if (s.stage == MscStageScanning) {
            s.stageLabel.text = devices.count > 0
                ? @"发现以下设备,点击连接"
                : @"正在扫描附近飞控…(确认飞控通电、蓝牙模块指示灯亮)";
        }
    };
    ble.onDisconnected = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        // 激活 MSC 后飞控重启断连 = 预期,进入插线引导;其他时机断连回扫描态
        if (s.stage != MscStageActivated) {
            [s enterStage:MscStageScanning];
        }
    };
    // 蓝牙从"启动中"变就绪时唤醒扫描(首次进场权限弹窗未点,进场检查必然落空)
    ble.onStateChanged = ^(BOOL ready, NSString *stateText) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (s.stage != MscStageScanning) return;
        if (ready) {
            [s enterStage:MscStageScanning];
        } else {
            s.stageLabel.text = stateText;  // 权限被拒/关蓝牙时同步提示
        }
    };
}

#pragma mark - 状态机

- (void)enterStage:(MscStage)stage {
    self.stage = stage;
    FCBluetoothService *ble = [FCBluetoothService shared];
    switch (stage) {
        case MscStageScanning: {
            _actionButton.hidden = YES;
            _downloadButton.hidden = YES;
            _progressView.hidden = YES;
            _deviceTable.hidden = NO;
            if (ble.bluetoothReady) {
                _stageLabel.text = @"正在扫描附近飞控…(确认飞控通电、蓝牙模块指示灯亮)";
                [ble startScan];
            } else {
                _stageLabel.text = ble.bluetoothStateText;
                [ble stopScan];
            }
            break;
        }

        case MscStageConnecting: {
            [ble stopScan];
            _deviceTable.hidden = YES;
            _actionButton.hidden = YES;
            _downloadButton.hidden = YES;
            _stageLabel.text = [NSString stringWithFormat:@"正在连接 %@…", self.selectedDevice.name ?: @"设备"];
            [ble connectDevice:self.selectedDevice completion:^(NSString *errorMessage) {
                if (errorMessage) {
                    [self enterStage:MscStageScanning];
                    self.stageLabel.text = [NSString stringWithFormat:@"连接失败:%@\n返回重新扫描", errorMessage];
                } else {
                    [self enterStage:MscStageConnected];
                }
            }];
            break;
        }

        case MscStageConnected: {
            _deviceTable.hidden = YES;
            _actionButton.hidden = NO;
            _progressView.hidden = YES;
            _downloadButton.hidden = NO;
            [_downloadButton setTitle:@"📡 蓝牙直接下载 .BBL(免插线)" forState:UIControlStateNormal];
            [_actionButton setTitle:@"⚡ 激活大容量存储" forState:UIControlStateNormal];
            _stageLabel.text = @"已连接,正在探测 MSP 链路…";

            // 链路探测:API 版本是 BF 必答命令,秒回。能分清"链路不通"和"MSC 命令不支持"
            __weak typeof(self) weakSelf = self;
            [ble sendCommand:MSPCommandApiVersion payload:[NSData data] reply:^(NSData *replyPayload, NSString *errorMessage) {
                if (!weakSelf || weakSelf.stage != MscStageConnected) return;
                if (errorMessage) {
                    weakSelf.stageLabel.text = [NSString stringWithFormat:
                        @"⚠️ 已连接但 MSP 链路不通:%@\n试重启飞控后重连;若仍不通请截图反馈", errorMessage];
                    return;
                }
                const uint8_t *b = replyPayload.length >= 3 ? replyPayload.bytes : NULL;
                weakSelf.stageLabel.text = b
                    ? [NSString stringWithFormat:@"✅ 链路正常(MSP 协议 %u / API %u.%u)。\n激活后飞控将重启为 U 盘模式(需 BF 4.4+,激活前确认电机已断电)", b[0], b[1], b[2]]
                    : @"✅ 链路正常。\n激活后飞控将重启为 U 盘模式(需 BF 4.4+,激活前确认电机已断电)";
            }];
            break;
        }

        case MscStageActivated: {
            _deviceTable.hidden = YES;
            _actionButton.hidden = NO;
            _downloadButton.hidden = YES;
            [_actionButton setTitle:@"📂 选择 .BBL 文件" forState:UIControlStateNormal];
            _stageLabel.text = @"✅ 飞控已激活为 U 盘模式,蓝牙已断开(正常现象)。\n用 USB 线将飞控连接 iPhone,然后点下方按钮选文件。";
            break;
        }

        case MscStageImported: {
            // 结果由 alert 呈现,alert 关闭即 pop
            break;
        }
    }
}

#pragma mark - 动作

- (void)actionButtonTapped {
    switch (self.stage) {
        case MscStageConnected:  [self activateMassStorage]; break;
        case MscStageActivated:  [self presentDocumentPicker]; break;
        default: break;
    }
}

/// 蓝牙直下:下载中再点 = 取消;失败后按钮变"重新下载"
- (void)downloadButtonTapped {
    if (self.downloader.running) {
        [self.downloader cancel];
        return;
    }
    _actionButton.hidden = YES;
    _progressView.hidden = NO;
    _progressView.progress = 0;
    [_downloadButton setTitle:@"⏹ 取消下载" forState:UIControlStateNormal];
    _stageLabel.text = @"正在查询闪存数据量…";

    __weak typeof(self) weakSelf = self;
    self.downloader = [[DataflashDownloader alloc] initWithService:[FCBluetoothService shared]];
    [self.downloader startWithProgress:^(double fraction, NSString *text) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.progressView.progress = fraction;
        s.stageLabel.text = text;
    } completion:^(NSURL *fileURL, NSString *errorMessage) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s.progressView.hidden = YES;
        if (errorMessage) {
            // 失败不跳态:按钮变重试,提示留在状态栏(重连场景直接重扫更稳)
            [s.downloadButton setTitle:@"🔁 重新下载" forState:UIControlStateNormal];
            s.stageLabel.text = [NSString stringWithFormat:@"❌ %@", errorMessage];
            return;
        }
        [s convertAndAlertBBL:fileURL];
    }];
}

/// 发 MSP_SET_REBOOT(rebootType=MSC),响应 payload[0]=1 表示存储就绪
- (void)activateMassStorage {
    _actionButton.enabled = NO;
    _stageLabel.text = @"正在激活…";
    uint8_t msc = MSPRebootTypeMSC;
    NSData *payload = [NSData dataWithBytes:&msc length:1];
    [[FCBluetoothService shared] sendCommand:MSPCommandSetReboot payload:payload reply:^(NSData *replyPayload, NSString *errorMessage) {
        self->_actionButton.enabled = YES;
        if (errorMessage) {
            self.stageLabel.text = [NSString stringWithFormat:@"激活失败:%@", errorMessage];
            return;
        }
        // 响应布局(照 BF 配置器 MSPHelper.js:812-821):payload[0]=rebootType,payload[1]=ready
        // MSC 激活时 ready==0 才是"存储未就绪";不足 2 字节视为接受(同 BF 对老固件的宽容)
        BOOL ready = YES;
        if (replyPayload.length >= 2) {
            ready = (((const uint8_t *)replyPayload.bytes)[1] == 1);
        }
        if (ready) {
            [self enterStage:MscStageActivated];
        } else {
            self.stageLabel.text = @"存储设备未就绪(飞控未挂载 dataflash 或无黑盒数据)";
        }
    }];
}

- (void)presentDocumentPicker {
    // U 盘卷上的 .BBL 没有系统 UTType,用通用 data 类型放开,后缀在回调里校验
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSString *name = url.lastPathComponent;
    if (![name.pathExtension.lowercaseString isEqualToString:@"bbl"]) {
        [self showAlertTitle:@"请选择 .bbl 文件" message:name];
        return;
    }

    // asCopy:YES 已把文件复制到临时区,再转存沙盒(与扫码接收一致的落盘位置)
    NSString *dest = [[BBLImportService documentsDirectory] stringByAppendingPathComponent:name];
    NSError *error = nil;
    NSURL *destURL = [NSURL fileURLWithPath:dest];
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:destURL error:&error]) {
        [self showAlertTitle:@"保存失败" message:error.localizedDescription];
        return;
    }

    [self convertAndAlertBBL:destURL];
}

/// BBL 转码 + 结果弹窗(文件选择器路径与蓝牙直下路径共用;成功后退出本页)
- (void)convertAndAlertBBL:(NSURL *)url {
    NSString *name = url.lastPathComponent;
    NSError *convertError = nil;
    NSArray<BBLImportCSVResult *> *results = [[BBLImportService shared] convertAllSessionsForBBL:url.path
                                                                                          motorKV:nil
                                                                                         progress:nil
                                                                                           error:&convertError];
    NSUInteger ok = [results filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(BBLImportCSVResult *r, NSDictionary *b) { return r.isSuccess; }]].count;

    NSString *title = ok > 0 ? @"导入成功" : @"导入失败";
    NSString *msg = ok > 0
        ? [NSString stringWithFormat:@"%@ · 已解码 %lu 个 Session,可在「☰ 总列表」查看", name, (unsigned long)ok]
        : (results.firstObject.errorMessage ?: convertError.localizedDescription ?: @"BBL 解码失败");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [self.navigationController popViewControllerAnimated:YES]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 设备列表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.devices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"BleDeviceCell" forIndexPath:indexPath];
    FCBleDevice *dev = self.devices[indexPath.row];
    // 默认样式无 detailTextLabel,信号强度并进主文案
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %ld dBm",
        dev.name.length > 0 ? dev.name : @"未命名设备", (long)dev.rssi];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    self.selectedDevice = self.devices[indexPath.row];
    [self enterStage:MscStageConnecting];
}

@end
