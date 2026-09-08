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
@property (nonatomic, strong) MSPClient *msp;
@property (nonatomic, strong) NSMutableArray<FCBleDevice *> *devices;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, CBPeripheral *> *pendingByUUID;
@property (nonatomic, copy, nullable) void (^connectReply)(NSString *_Nullable);
@property (nonatomic, copy, nullable) void (^pendingReply)(NSData *_Nullable, NSString *_Nullable);
@property (nonatomic, assign) BOOL waitingReply;
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
    [self.devices removeAllObjects];
    [self notifyDevicesChanged];
    [self.lazyCentral scanForPeripheralsWithServices:KnownServiceUUIDs() options:@{}];
}

- (void)stopScan
{
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
    self.waitingReply = NO;
    [self.msp reset];
}

#pragma mark - 发命令

- (void)sendCommand:(uint8_t)cmd
            payload:(NSData *)payload
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
    [self.peripheral writeValue:[MSPClient v1RequestWithCmd:cmd payload:payload]
              forCharacteristic:self.writeChar
                           type:CBCharacteristicWriteWithResponse];

    // 超时兜底(蓝牙桥丢包/飞控不支持该命令时不会回包)
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s.waitingReply) return;
        s.waitingReply = NO;
        void (^block)(NSData *, NSString *) = s.pendingReply;
        s.pendingReply = nil;
        block(nil, @"飞控无响应(检查是否已解锁/固件是否支持)");
    });
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    // 状态变化只影响 UI 文案(bluetoothStateText),扫描由页面在 ready 后调 startScan
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
    // 只发现已知服务,避免误选系统服务(电量等)的特征
    [peripheral discoverServices:KnownServiceUUIDs()];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    void (^block)(NSString *) = self.connectReply;
    self.connectReply = nil;
    if (block) block(error.localizedDescription ?: @"连接失败");
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error
{
    [self clearConnection];
    if (self.onDisconnected) self.onDisconnected();
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (error) {
        [self finishConnect:@"发现服务失败"];
        return;
    }
    // 服务是异步逐个回调的,特征发现完了才收尾
    for (CBService *service in peripheral.services)
        [peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error
{
    if (error)
        return;  // 单服务失败不放弃,等其他服务回调

    // 通用特征发现:第一个可写 + 第一个可 notify,兼容全部已知模块,不按型号分支
    for (CBCharacteristic *c in service.characteristics) {
        if (!self.writeChar && (c.properties & (CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse)))
            self.writeChar = c;
        if (!self.notifyChar && (c.properties & CBCharacteristicPropertyNotify))
            self.notifyChar = c;
    }
    if (!self.writeChar || !self.notifyChar)
        return;  // 还有别的服务没发现完

    self.peripheral.delegate = self;
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
    if (error || !characteristic.value) return;
    __weak typeof(self) weakSelf = self;
    [self.msp feedData:characteristic.value onFrame:^(uint8_t cmd, NSData *payload) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s.pendingReply) return;
        // 简化一问一答:任何完整帧都终结等待(MSC 场景只发一条命令)
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
