//
//  FCBluetoothService.m — 飞控 BLE 串口桥传输层
//
//  连接时序(照 BF Configurator 的 GATT 语义,用 CoreBluetooth 原生表达):
//  扫描(按 8 家 service UUID 过滤) → connect → discoverServices(仅已知服务)
//  → didDiscoverCharacteristics 里挑第一个"可写"和第一个"可 notify"特征
//  → 订阅 notify → 就绪。MSP 帧写 write 特征,notify 回包喂 MSPClient 状态机。
//

#import "FCBluetoothService.h"
#import <CoreBluetooth/CoreBluetooth.h>

/// 已知 BLE 串口桥 Service UUID 前缀(Nordic NUS 用完整 UUID)
/// —— 模块型号对照见 技术验证Demo/蓝牙对接计划.md §三
static NSArray<CBUUID *> *KnownServiceUUIDs(void) {
    return @[
        [CBUUID UUIDWithString:@"00001000-0000-1000-8000-00805f9b34fb"],  // SpeedyBee V1
        [CBUUID UUIDWithString:@"0000abf0-0000-1000-8000-00805f9b34fb"],  // SpeedyBee V2
        [CBUUID UUIDWithString:@"000000ff-0000-1000-8000-00805f9b34fb"],  // SpeedyBee FF00
        [CBUUID UUIDWithString:@"0000ffe0-0000-1000-8000-00805f9b34fb"],  // CC2541 / HM-10
        [CBUUID UUIDWithString:@"0000ffe5-0000-1000-8000-00805f9b34fb"],  // HM-10 变体
        [CBUUID UUIDWithString:@"6e400001-b5a3-f393-e0a9-e50e24dcca9e"],  // HM-11 / Nordic NUS
        [CBUUID UUIDWithString:@"0000db32-0000-1000-8000-00805f9b34fb"],  // DroneBridge
    ];
}

@interface FCBleDevice ()
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *uuidKey;
@property (nonatomic, assign, readwrite) NSInteger rssi;
@end

@interface FCBluetoothService () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong, nullable) CBCentralManager *central;
@property (nonatomic, strong, nullable) CBPeripheral *peripheral;
@property (nonatomic, strong, nullable) CBCharacteristic *writeChar;
@property (nonatomic, strong, nullable) CBCharacteristic *notifyChar;
@property (nonatomic, strong, nullable) CBService *boundService;  // 写/通知配对所在服务(防跨服务混搭)
@property (nonatomic, strong) MSPClient *msp;
@property (nonatomic, strong) NSMutableArray<FCBleDevice *> *devices;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, CBPeripheral *> *pendingByUUID;
@property (nonatomic, copy, nullable) void (^connectReply)(NSString *_Nullable);
@property (nonatomic, copy, nullable) void (^pendingReply)(NSData *_Nullable, NSString *_Nullable);
@property (nonatomic, assign) uint16_t expectedCmd;  // 等待中的命令码(不匹配的帧直接丢弃)
@property (nonatomic, assign) BOOL waitingReply;
@property (nonatomic, assign) NSUInteger requestGeneration;  // 请求代数:超时只杀自己那代,不误伤新请求
@end

@implementation FCBleDevice
@end

@implementation FCBluetoothService

+ (instancetype)shared
{
    static FCBluetoothService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] initInternal]; });
    return s;
}

- (instancetype)initInternal
{
    self = [super init];
    if (self) {
        _msp = [[MSPClient alloc] init];
        _devices = [NSMutableArray array];
    }
    return self;
}

- (CBCentralManager *)lazyCentral
{
    if (!_central) {
        // 初始化即触发系统蓝牙权限弹窗(Info.plist 需 NSBluetoothAlwaysUsageDescription)
        _central = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    return _central;
}

#pragma mark - 对外状态

- (NSArray<FCBleDevice *> *)foundDevices { return [self.devices copy]; }

- (BOOL)isConnected { return self.peripheral != nil && self.writeChar != nil; }

- (BOOL)bluetoothReady
{
    return self.central.state == CBManagerStatePoweredOn;
}

- (NSString *)bluetoothStateText
{
    switch (self.lazyCentral.state) {
        case CBManagerStatePoweredOn:     return @"蓝牙已开启";
        case CBManagerStatePoweredOff:    return @"蓝牙未开启,请到控制中心打开";
        case CBManagerStateUnauthorized:  return @"蓝牙权限被拒,请到设置中开启";
        case CBManagerStateUnsupported:   return @"本机不支持 BLE";
        default:                          return @"蓝牙启动中…";
    }
}

#pragma mark - 扫描 / 连接

- (void)startScan
{
    if (!self.bluetoothReady) return;  // 未就绪时扫描是 API misuse,页面靠 onStateChanged 唤醒
    [self.devices removeAllObjects];
    [self notifyDevicesChanged];
    [self.lazyCentral scanForPeripheralsWithServices:KnownServiceUUIDs() options:@{}];
}

- (void)stopScan
{
    if (!self.bluetoothReady) return;
    [self.central stopScan];
}

- (void)connectDevice:(FCBleDevice *)device
           completion:(void (^)(NSString * _Nullable))completion
{
    CBPeripheral *p = self.pendingByUUID[device.uuidKey];
    if (!p) {
        completion(@"设备已失效,请重新扫描");
        return;
    }
    self.connectReply = completion;
    [self.lazyCentral connectPeripheral:p options:@{}];

    // 连接超时兜底:桥被其他手机/App 占用(串口桥只许 1 连接)时系统不会回调,永远卡"正在连接"
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.connectReply) return;  // 已连上或已失败
        [s.central cancelPeripheralConnection:p];
        [s finishConnect:@"连接超时(飞控蓝牙可能被其他 App/设备占用,断电重启飞控后重试)"];
    });
}

- (void)disconnect
{
    if (self.peripheral)
        [self.lazyCentral cancelPeripheralConnection:self.peripheral];
    [self clearConnection];
}

- (void)clearConnection
{
    self.peripheral = nil;
    self.writeChar = nil;
    self.notifyChar = nil;
    self.boundService = nil;
    self.waitingReply = NO;
    [self.msp reset];
}

#pragma mark - 发命令

- (void)sendCommand:(uint8_t)cmd
            payload:(NSData *)payload
              reply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
{
    [self sendFrame:[MSPClient v1RequestWithCmd:cmd payload:payload] expectedCmd:cmd reply:reply];
}

- (void)sendV2Command:(uint16_t)cmd
              payload:(NSData *)payload
                reply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
{
    [self sendFrame:[MSPClient v2RequestWithCmd:cmd payload:payload] expectedCmd:cmd reply:reply];
}

- (void)sendFrame:(NSData *)frame
       expectedCmd:(uint16_t)cmd
              reply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
{
    if (!self.isConnected) {
        reply(nil, @"未连接飞控");
        return;
    }
    if (self.waitingReply) {
        reply(nil, @"上一条命令还在等响应");
        return;
    }
    self.waitingReply = YES;
    self.pendingReply = reply;
    self.expectedCmd = cmd;
    NSUInteger generation = ++self.requestGeneration;
    NSLog(@"[BLE] → cmd=%u frame=%@", cmd, frame);
    // 写入类型自适应(同 BF 插件):特征只支持无响应写时,带响应写会被 iOS 拒发=链路全哑
    CBCharacteristicWriteType type =
        (self.writeChar.properties & CBCharacteristicPropertyWrite)
            ? CBCharacteristicWriteWithResponse
            : CBCharacteristicWriteWithoutResponse;
    [self.peripheral writeValue:frame
              forCharacteristic:self.writeChar
                           type:type];

    // 超时兜底(蓝牙桥丢包/飞控不支持该命令时不会回包);半帧残留一并丢弃
    // ⚠️ 回包到达不会撤销此定时器,必须按代数核对,否则旧命令的超时会误杀新请求(已实测踩坑)
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || generation != s.requestGeneration || !s.waitingReply) return;
        NSLog(@"[BLE] ⏱ cmd=%u 5s 无响应", cmd);
        s.waitingReply = NO;
        [s.msp reset];
        void (^block)(NSData *, NSString *) = s.pendingReply;
        s.pendingReply = nil;
        block(nil, @"飞控无响应(检查是否已解锁/固件是否支持)");
    });
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    NSLog(@"[BLE] 电源状态=%ld", (long)central.state);
    // 权限弹窗点击/开关蓝牙都会走到这里,通知页面跟进(否则页面只检查进场那一瞬,永远停在"启动中")
    if (self.onStateChanged) {
        BOOL ready = (central.state == CBManagerStatePoweredOn);
        self.onStateChanged(ready, [self bluetoothStateText]);
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI
{
    // 按已知服务扫描时系统已过滤,这里只去重(RSSI 取最强)
    NSString *key = peripheral.identifier.UUIDString;
    FCBleDevice *dev = [[FCBleDevice alloc] init];
    dev.uuidKey = key;
    dev.name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey] ?: @"";
    dev.rssi = RSSI.integerValue;
    NSLog(@"[BLE] 发现设备 name=%@ rssi=%ld uuid=%@", dev.name, (long)dev.rssi, key);

    FCBleDevice *existing = nil;
    for (FCBleDevice *d in self.devices) {
        if ([d.uuidKey isEqualToString:key]) { existing = d; break; }
    }
    if (existing) {
        if (dev.name.length > 0) existing.name = dev.name;
        existing.rssi = dev.rssi;
    } else {
        [self.devices addObject:dev];
    }
    if (!self.pendingByUUID) self.pendingByUUID = [NSMutableDictionary dictionary];
    self.pendingByUUID[key] = peripheral;
    [self notifyDevicesChanged];
}

- (void)centralManager:(CBCentralManager *)central
didConnectPeripheral:(CBPeripheral *)peripheral
{
    self.peripheral = peripheral;
    peripheral.delegate = self;
    NSLog(@"[BLE] GATT 已连接,开始发现服务");
    // 只发现已知服务,避免误选系统服务(电量等)的特征
    [peripheral discoverServices:KnownServiceUUIDs()];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    NSLog(@"[BLE] ❌ 连接失败 error=%@", error);
    void (^block)(NSString *) = self.connectReply;
    self.connectReply = nil;
    if (block) block(error.localizedDescription ?: @"连接失败");
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    NSLog(@"[BLE] 断连 error=%@", error);
    [self clearConnection];
    if (self.onDisconnected) self.onDisconnected();
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (error) {
        NSLog(@"[BLE] ❌ 发现服务失败 error=%@", error);
        [self finishConnect:@"发现服务失败"];
        return;
    }
    NSLog(@"[BLE] services=%@", peripheral.services);
    // 服务是异步逐个回调的,特征发现完了才收尾
    for (CBService *service in peripheral.services)
        [peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error
{
    if (error) {
        NSLog(@"[BLE] ⚠️ service %@ 特征发现失败 error=%@", service.UUID, error);
        return;  // 单服务失败不放弃,等其他服务回调
    }
    NSLog(@"[BLE] service %@ chars=%@", service.UUID, service.characteristics);

    // 服务内配对:写在 A 服务、通知听在 B 服务会链路全哑(飞控可能同时广播多个已知服务)
    // 照 BF 插件 UUID 表,写+通知必在同一服务(如 SpeedyBee V2 = ABF1+ABF2)
    CBCharacteristic *svcWrite = nil, *svcNotify = nil;
    for (CBCharacteristic *c in service.characteristics) {
        NSLog(@"[BLE]   char %@ props=%lu", c.UUID, (unsigned long)c.properties);
        if (!svcWrite && (c.properties & (CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse)))
            svcWrite = c;
        if (!svcNotify && (c.properties & CBCharacteristicPropertyNotify))
            svcNotify = c;
    }
    if (svcWrite && svcNotify) {
        self.writeChar = svcWrite;      // 完整服务优先,整体覆盖
        self.notifyChar = svcNotify;
        self.boundService = service;
    } else if (!self.boundService) {
        if (svcWrite && !self.writeChar) self.writeChar = svcWrite;    // 兜底:没有完整服务时才跨服务拼
        if (svcNotify && !self.notifyChar) self.notifyChar = svcNotify;
    }
    if (!self.writeChar || !self.notifyChar)
        return;  // 还有别的服务没发现完

    self.peripheral.delegate = self;
    NSLog(@"[BLE] 选定 写特征=%@ 订阅特征=%@", self.writeChar.UUID, self.notifyChar.UUID);
    [peripheral setNotifyValue:YES forCharacteristic:self.notifyChar];
    [self finishConnect:nil];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error
{
    if (error) [self finishConnect:@"订阅通知失败"];
}

/// notify 回包 → MSP 状态机 → 命中等待中的命令回调
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error
{
    if (error) {
        NSLog(@"[BLE] ❌ 订阅失败 error=%@", error);
        return;
    }
    if (!characteristic.value) return;
    NSLog(@"[BLE] ← %@", characteristic.value);
    __weak typeof(self) weakSelf = self;
    [self.msp feedData:characteristic.value onFrame:^(uint8_t cmd, NSData *payload) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s.pendingReply) return;
        // 一问一答按命令码匹配,不匹配的帧(杂散/上轮残留)直接丢弃
        if (cmd != (uint8_t)(s.expectedCmd & 0xff)) {
            NSLog(@"[BLE] 丢弃不匹配帧 cmd=%u (等待 %u)", cmd, s.expectedCmd);
            return;
        }
        void (^block)(NSData *, NSString *) = s.pendingReply;
        s.pendingReply = nil;
        s.waitingReply = NO;
        block(payload, nil);
    }];
}

- (void)finishConnect:(NSString *)errorMessage
{
    void (^block)(NSString *) = self.connectReply;
    self.connectReply = nil;
    if (block) block(errorMessage);
}

- (void)notifyDevicesChanged
{
    if (self.onDevicesChanged) self.onDevicesChanged([self foundDevices]);
}

@end
