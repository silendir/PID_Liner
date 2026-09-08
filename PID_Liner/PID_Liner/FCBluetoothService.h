//
//  FCBluetoothService.h
//  PID_Liner
//
//  飞控 BLE 传输层(蓝牙分支 · clean-room 重实现)
//  职责:扫描/连接/特征发现/MSP 帧收发。协议事实(UUID 表、特征语义)来自
//  BF Configurator 公开源码,实现为本项目自有 ObjC 代码(GPLv3 传染规避)。
//
//  🔑 支持模块 = BLE 串口桥(SpeedyBee V1/V2/FF00、HM-10/11、CC2541、
//  DroneBridge、Nordic NUS)。HC-05 是经典蓝牙 SPP,CoreBluetooth 不支持,不在列。
//

#import <Foundation/Foundation.h>
#import "MSPClient.h"

NS_ASSUME_NONNULL_BEGIN

/// 扫描发现的一台设备
@interface FCBleDevice : NSObject
@property (nonatomic, copy, readonly) NSString *name;      // 广播名(可能为空)
@property (nonatomic, copy, readonly) NSString *uuidKey;   // peripheral.identifier 字符串
@property (nonatomic, assign, readonly) NSInteger rssi;
@end

@interface FCBluetoothService : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (nullable instancetype)shared;

#pragma mark 状态
@property (nonatomic, copy, readonly, nullable) NSArray<FCBleDevice *> *foundDevices;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
/** 蓝牙可用性(关闭/未授权时 UI 提示,不再尝试扫描) */
@property (nonatomic, readonly) BOOL bluetoothReady;
@property (nonatomic, copy, readonly) NSString *bluetoothStateText;

#pragma mark 动作
- (void)startScan;
- (void)stopScan;

/// 连接指定设备(回调主线程;失败 err 非 nil)
- (void)connectDevice:(FCBleDevice *)device
           completion:(void(^)(NSString *_Nullable errorMessage))completion;

/// 断开当前连接
- (void)disconnect;

/// 发一条 MSP 命令并等响应(回调主线程;超时/断开 err 非 nil)
/// 响应判定:收到的帧 cmd 一致即认为响应(小命令场景一问一答)
- (void)sendCommand:(uint8_t)cmd
            payload:(NSData *)payload
              reply:(void(^)(NSData *_Nullable payload, NSString *_Nullable errorMessage))reply;

#pragma mark 事件回调(主线程)
/** 扫描结果变化(新设备发现/列表刷新) */
@property (nonatomic, copy, nullable) void (^onDevicesChanged)(NSArray<FCBleDevice *> *devices);
/** 连接被对端断开(如激活 MSC 后飞控重启,属预期) */
@property (nonatomic, copy, nullable) void (^onDisconnected)(void);

@end

NS_ASSUME_NONNULL_END
