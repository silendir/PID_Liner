# 风格化PID产品功能清单

> **基于** `曲线即产品-PID_Liner差异化战略调研.md`（2026-07-01）  
> **定位**：PID不是"修复到最优"，而是"可雕塑的个人飞行签名"，类似音频EQ/混音

---

## 📊 功能架构总览

```
用户交互层
├── 风格EQ旋钮（4维度）
├── 预设档位（Racer/Freestyle/Cinematic）
├── 反向操纵曲线（交互式界面）
└── 实时预览（调整后的预测曲线）

技术实现层
├── 风格映射引擎（风格→工程量）
├── 前向校准模型（RMSE质量门）
├── 反向求解器（曲线→PID）
└── 安全限制系统（防炸机）
```

---

## 🎛️ 风格EQ的4个旋钮定义（核心创新）

### 设计原则
- 基于Pareto五维降维：响应锐度/平滑度/噪声底/锁定感/控制精度
- 每个旋钮影响1-2个工程量，避免耦合
- 映射到可预测的PID/FF变化（非黑盒）

### 旋钮详情

#### 1. 🎯 **锐度（Snap）** - 控制响应速度
**旋钮范围**：0-100（默认50）  
**语义映射**：
- 0-30：缓慢响应（ cinematic 风格）
- 31-70：平衡响应（Freestyle 默认）
- 71-100：急速响应（Racer 风格）

**工程影响**：
```objc
// 在推荐引擎中的映射逻辑
- (double)snapToPAdjustment:(double)snapValue {
    // P增益与带宽正相关
    if (snapValue < 30) {
        return 0.7;    // P×0.7
    } else if (snapValue > 70) {
        return 1.3;    // P×1.3
    } else {
        return 1.0;    // P不变
    }
}
```

**曲线变化**：
- 上升时间↓ → 响应更迅速
- 可能伴随小幅超调↑

#### 2. 🌊 **平滑度（Smooth）** - 控制阻尼与超调
**旋钮范围**：0-100（默认50）  
**语义映射**：
- 0-20：允许剧烈振荡（竞速不惧抖动）
- 21-80：临界阻尼（Freestyle 默认）
- 81-100：超低超调（航拍安全优先）

**工程影响**：
```objc
// D增益与阻尼比正相关
- (double)smoothToDAdjustment:(double)smoothValue {
    // ζ = f(smoothValue)，二阶系统阻尼比
    double dampingRatio = 0.3 + (smoothValue / 100.0) * 1.4;  // 0.3~1.7
    
    // D ∝ ζ，但存在非线性关系
    if (smoothValue > 80) {
        return 1.5;    // D×1.5，高阻尼
    } else if (smoothValue < 20) {
        return 0.8;    // D×0.8，低阻尼
    } else {
        return 1.0;    // D不变
    }
}
```

**曲线变化**：
- 超调量↓ → 更平滑无 overshoot
- 上升时间↑ → 响应变缓

#### 3. 🔇 **噪声底（Noise）** - 控制高频滤波
**旋钮范围**：0-100（默认50）  
**语义映射**：
- 0-30：锐利高频保留（竞速需快速响应）
- 31-70：适度滤波（Freestyle 默认）
- 71-100：强滤波（环境干扰严重时）

**工程影响**：
```objc
// 主要影响D-term滤波器，次要影响D增益
- (NSDictionary *)noiseToFilterAdjustment:(double)noiseValue {
    // 实际应用：
    // 1. D-term截止频率 = 150Hz - (noiseValue × 1.0Hz)
    // 2. D增益微调：noiseValue > 70时额外×0.9，noiseValue < 30时×1.1
    
    return @{
        @"dterm_cutoff": @(150 - noiseValue),
        @"d_gain": @(noiseValue > 70 ? 0.9 : (noiseValue < 30 ? 1.1 : 1.0))
    };
}
```

**曲线变化**：
- 高频噪声↓ → 更平稳的 trace
- 瞬态响应↑ → 可能损失快速响应

#### 4. 🧲 **锁定感（Hold）** - 控制悬停稳定性
**旋钮范围**：0-100（默认50）  
**语义映射**：
- 0-30：宽松悬停（freestyle允许自然漂移）
- 31-70：适度锁定（Freestyle 默认）
- 71-100：刚性锁定（航拍定位精准）

**工程影响**：
```objc
// I增益与积分强度正相关
- (double)holdToIAdjustment:(double)holdValue {
    // I ∝ 1/积分时间，锁定感强 → I值大
    
    // 同时考虑FF辅助（锁定感强的场合FF也需增强）
    double iScale = 1.0 + (holdValue - 50) * 0.02;  // ±100%变化
    double ffScale = 1.0 + (holdValue - 50) * 0.015;
    
    return @{
        @"i_gain": @(iScale),
        @"ff_gain": @(ffScale)
    };
}
```

**曲线变化**：
- 悬停漂移↓ → 更稳定的悬停
- 弹回效应↓ → 更紧的跟随

---

## 🎚️ 3个预设档位的目标工作点表

### 设计原则
- 基于 UAV Model 2026 数值表 + BF 官方文档区分
- 每档位是一个完整的风格锚点，不是单独的旋钮
- 支持混合模式（如50% Racer + 50% Cinematic）

### 预设详情

#### 🏁 **Racer（竞速）**
**目标场景**：FPV竞速、3D飞行、敏捷操控  
**风格描述**：响应迅速，允许轻微震荡，优先控制精度

| 旋钮 | 目标值 | 工程映射 | 典型曲线特征 |
|---|---|---|---|
| **锐度（Snap）** | 85 | P×1.25 | 快速响应，短上升时间 |
| **平滑度（Smooth）** | 25 | D×0.85 | 允许轻微震荡，保留快速性 |
| **噪声底（Noise）** | 15 | D-term: 135Hz | 保留高频响应，不怕噪声 |
| **锁定感（Hold）** | 40 | I×1.0, FF×1.0 | 自然漂移，不束缚灵活性 |

**关键指标**：
- 带宽：60-80Hz（高频响应）
- 相位裕度：40-50°（允许临界稳定）
- 超调：10-20%（竞速可接受）

#### 🎨 **Freestyle（自由飞）**
**目标场景**：自由花飞、日常训练、特技飞行  
**风格描述**：平衡操控，流畅易控，适合各种动作

| 旋钮 | 目标值 | 工程映射 | 典型曲线特征 |
|---|---|---|---|
| **锐度（Snap）** | 55 | P×1.05 | 中等响应速度 |
| **平滑度（Smooth）** | 60 | D×1.05 | 临界阻尼，无显著超调 |
| **噪声底（Noise）** | 50 | D-term: 100Hz | 平衡响应与稳定性 |
| **锁定感（Hold）** | 55 | I×1.1, FF×1.05 | 适度悬停锁定 |

**关键指标**：
- 带宽：45-55Hz（中频响应）
- 相位裕度：50-60°（稳定余量）
- 超调：5-10%（可接受范围）

#### 🎬 **Cinematic（影视航拍）**
**目标场景**：影视拍摄、无人机表演、环境监测  
**风格描述**：绝对平稳，零噪声干扰，镜头稳定

| 旋钮 | 目标值 | 工程映射 | 典型曲线特征 |
|---|---|---|---|
| **锐度（Snap）** | 25 | P×0.75 | 缓慢响应，避免冲击 |
| **平滑度（Smooth）** | 85 | D×1.4 | 高阻尼，零超调 |
| **噪声底（Noise）** | 80 | D-term: 70Hz | 强滤波，纯净信号 |
| **锁定感（Hold）** | 85 | I×1.3, FF×1.2 | 强力悬停锁定 |

**关键指标**：
- 带宽：30-40Hz（低频响应）
- 相位裕度：60-70°（高稳定性）
- 超调：0-3%（绝对平稳）

---

## ⚖️ 校准门 RMSE 阈值系统

### 设计原则
- 校准不是"收敛"而是"模型对齐"
- 未达标时引导用户继续校准，不进入反向操纵
- 分轴设置，不同轴容忍度不同

### 质量门实现

#### RMSE计算与阈值

```objc
// PID_Liner/PIDAnalysis/Engine/CalibrationGate.h
@interface CalibrationGate : NSObject

// RMSE 阈值定义（基于真实飞行数据统计）
static const double kRMSEThresholdRoll = 0.05;    // Roll轴：较高容忍
static const double kRMSEThresholdPitch = 0.04;  // Pitch轴：中等容忍
static const double kRMSEThresholdYaw = 0.06;    // Yaw轴：较高容忍

// 校准状态枚举
typedef NS_ENUM(NSInteger, CalibrationStatus) {
    CalibrationStatusNotStarted,
    CalibrationStatusInProgress,
    CalibrationStatusPassed,        // 通过质量门
    CalibrationStatusFailedRoll,    // 各轴失败状态
    CalibrationStatusFailedPitch,
    CalibrationStatusFailedYaw
};

// 校准质量评估
- (CalibrationStatus)evaluateCalibrationForAxis:(NSInteger)axis
                                   predictedCurve:(NSArray<NSNumber *> *)predicted
                                       measuredCurve:(NSArray<NSNumber *> *)measured;

// RMSE 计算核心
- (double)calculateRMSE:(NSArray<NSNumber *> *)predicted
             measured:(NSArray<NSNumber *> *)measured;
@end
```

#### 未通过时的用户引导

```swift
// 用户界面逻辑
class CalibrationViewController: UIViewController {
    
    func handleCalibrationResult(status: CalibrationStatus) {
        switch status {
        case .Passed:
            transitionToReverseManipulation()
            
        case .FailedRoll:
            showGuidance("Roll轴校准未达标", 
                        suggestion: "请再飞一次Roll轴小动作测试，注意保持动作干净")
            
        case .FailedPitch:
            showGuidance("Pitch轴校准未达标",
                        suggestion: "Pitch轴数据波动较大，检查环境干扰并重试")
            
        case .FailedYaw:
            showGuidance("Yaw轴校准未达标",
                        suggestion: "Yaw轴受磁干扰，远离金属环境重试")
            
        default:
            break
        }
    }
    
    func showGuidance(_ title: String, suggestion: String) {
        let alert = UIAlertController(
            title: title,
            message: suggestion,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "重试", style: .default))
        alert.addAction(UIAlertAction(title: "查看校准详情", style: .default))
        
        present(alert, animated: true)
    }
}
```

### 仪表盘可视化

```swift
// 校准进度与质量可视化
struct CalibrationDashboard {
    var rollCalibration: CalibrationProgress
    var pitchCalibration: CalibrationProgress
    var yawCalibration: CalibrationProgress
    
    // 可视化组件
    var calibrationChart: CalibrationChartView {
        // 显示三轴RMSE曲线，实时更新
        return CalibrationChartView(
            data: [
                "Roll": rollCalibration.rmse,
                "Pitch": pitchCalibration.rmse,
                "Yaw": yawCalibration.rmse
            ],
            thresholds: [
                "Roll": 0.05,
                "Pitch": 0.04,
                "Yaw": 0.06
            ]
        )
    }
}
```

---

## 🎨 反向操纵曲线的UI交互模型

### 设计原则
- 直观：拖动曲线点就能看到效果
- 实时：每次调整都有预测反馈
- 安全：防止单次剧烈变化

### 交互组件设计

#### 1. **交互式曲线编辑器**

```swift
// 曲线编辑器主组件
class FlightCurveEditor: UIView {
    
    // 曲线数据点
    private var curvePoints: [ControlPoint] = []
    
    // 控制点（可拖动）
    private var controlPoints: [DraggableControlPoint] = []
    
    // 实时预览曲线
    private var previewCurve: PreviewCurveView!
    
    override func draw(_ rect: CGRect) {
        // 1. 绘制目标曲线（用户拖动的）
        drawTargetCurve()
        
        // 2. 绘制预测曲线（根据当前PID计算的）
        drawPredictedCurve()
        
        // 3. 绘制差异区域
        drawDifferenceArea()
    }
    
    // 控制点拖动响应
    @objc func controlPointDragged(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let controlPoint = findNearestControlPoint(to: location)
        
        if let point = controlPoint {
            updateControlPoint(point, to: location)
            
            // 实时更新预测
            updatePredictedCurve()
            
            // 更新PID值
            updatePIDRecommendations()
            
            setNeedsDisplay()
        }
    }
}
```

#### 2. **实时反馈机制**

```swift
// 实时反馈组件
class RealTimeFeedback {
    
    // 监控曲线变化
    func monitorCurveChanges(oldCurve: FlightCurve, newCurve: FlightCurve) {
        let changes = calculateCurveChanges(old: oldCurve, new: newCurve)
        
        // 生成反馈
        let feedback = generateFeedback(changes: changes)
        
        // 显示反馈
        showFeedback(feedback)
    }
    
    // 反馈生成
    private func generateFeedback(changes: CurveChanges) -> Feedback {
        var messages = [String]()
        
        // 上升时间变化
        if let riseTimeChange = changes.riseTime {
            if riseTimeChange > 0.1 {
                messages.append("响应变慢 +\(riseTimeChange*1000)ms")
            } else if riseTimeChange < -0.1 {
                messages.append("响应变快 \(-riseTimeChange*1000)ms")
            }
        }
        
        // 超调变化
        if let overshootChange = changes.overshoot {
            if overshootChange > 0.05 {
                messages.append("超调增加 +\(Int(overshootChange*100))%")
            } else if overshootChange < -0.05 {
                messages.append("超调减少 \(Int(-overshootChange*100))%")
            }
        }
        
        return Feedback(messages: messages)
    }
}
```

#### 3. **预设样式库**

```swift
// 预设样式库
struct CurvePresetLibrary {
    
    // 内置样式
    let presets: [String: CurveStyle] = [
        "Aggressive": CurveStyle(
            name: "激进型",
            icon: "🔥",
            description: "快速响应，允许震荡",
            curveTemplate: aggressiveCurveTemplate
        ),
        
        "Smooth": CurveStyle(
            name: "平稳型",
            icon: "🌊",
            description: "平稳过渡，零超调",
            curveTemplate: smoothCurveTemplate
        ),
        
        "Precision": CurveStyle(
            name: "精准型",
            icon: "🎯",
            description: "精准悬停，严格锁定",
            curveTemplate: precisionCurveTemplate
        )
    ]
    
    // 自定义样式
    var customPresets: [String: CurveStyle] = [:]
    
    // 应用预设
    func applyPreset(_ presetName: String, to curve: inout FlightCurve) {
        if let preset = presets[presetName] {
            curve = preset.curveTemplate.generateCurve()
        }
    }
}
```

#### 4. **安全限制系统**

```swift
// 安全限制
class SafetyLimitSystem {
    
    // 单次变化限制
    private let singleChangeLimit: Double = 0.3  // ±30%
    
    // 检查调整是否安全
    func isAdjustmentSafe(from oldPID: PIDValues, to newPID: PIDValues) -> Bool {
        // 1. 检查单项变化
        let changes = [
            abs(newPID.p - oldPID.p) / oldPID.p,
            abs(newPID.i - oldPID.i) / oldPID.i,
            abs(newPID.d - oldPID.d) / oldPID.d,
            abs(newPID.ff - oldPID.ff) / oldPID.ff
        ]
        
        // 任何单项变化都不能超过30%
        for change in changes {
            if change > singleChangeLimit {
                return false
            }
        }
        
        // 2. 检查PID总和
        let newPIDSum = newPID.p + newPID.i + newPID.d + newPID.ff
        let oldPIDSum = oldPID.p + oldPID.i + oldPID.d + oldPID.ff
        
        let sumChange = abs(newPIDSum - oldPIDSum) / oldPIDSum
        return sumChange <= singleChangeLimit
    }
    
    // 自动安全缩放
    func safeAdjustment(from oldPID: PIDValues, target newPID: PIDValues) -> PIDValues {
        let changes = [
            (newPID.p - oldPID.p) / oldPID.p,
            (newPID.i - oldPID.i) / oldPID.i,
            (newPID.d - oldPID.d) / oldPID.d,
            (newPID.ff - oldPID.ff) / oldPID.ff
        ]
        
        let maxChange = abs(changes.max() ?? 0)
        
        if maxChange > singleChangeLimit {
            // 按比例缩放到安全范围内
            let scale = singleChangeLimit / maxChange
            return PIDValues(
                p: oldPID.p + (newPID.p - oldPID.p) * scale,
                i: oldPID.i + (newPID.i - oldPID.i) * scale,
                d: oldPID.d + (newPID.d - oldPID.d) * scale,
                ff: oldPID.ff + (newPID.ff - oldPID.ff) * scale
            )
        }
        
        return newPID
    }
}
```

---

## 🔄 与现有代码的集成点

### 1. **PIDRecommendationEngine 增强**

```objc
// 原有方法签名保持兼容，内部增加风格逻辑
- (PIDTuningResult *)generateRecommendationWithDiagnosis:(PIDAxisDiagnosis *)diagnosis
                                               currentPID:(PIDValues *)currentPID
                                          currentResponse:(NSArray<NSNumber *> *)currentResponse
                                              sampleRate:(double)sampleRate
                                               styleGuide:(StyleGuide *)styleGuide  // 新增参数
{
    // 现有逻辑保持不变...
    
    // 新增：风格化推荐
    PIDTuningResult *styledResult = [self applyStyleGuide:styleGuide
                                                    toResult:result
                                            currentResponse:currentResponse];
    
    return styledResult;
}
```

### 2. **新增风格引导模型**

```objc
// 新增：风格引导数据模型
@interface StyleGuide : NSObject
@property (nonatomic, assign) double snapValue;      // 锐度 0-100
@property (nonatomic, assign) double smoothValue;     // 平滑度 0-100
@property (nonatomic, assign) double noiseValue;      // 噪声底 0-100
@property (nonatomic, assign) double holdValue;       // 锁定感 0-100
@property (nonatomic, assign) NSString *presetName;   // 预设名称（可选）
@end
```

### 3. **UI层与引擎层解耦**

```swift
// UI层使用风格接口，不直接涉及PID计算
class StyleAdjustmentViewController: UIViewController {
    
    // 风格调整
    @IBAction func snapValueChanged(_ sender: UISlider) {
        let styleGuide = StyleGuide(
            snapValue: sender.value,
            smoothValue: smoothnessSlider.value,
            noiseValue: noiseSlider.value,
            holdValue: holdSlider.value
        )
        
        // 调用引擎更新
        let newResult = engine.applyStyle(styleGuide)
        
        // 更新显示
        updateDisplay(with: newResult)
    }
}
```

---

## 📋 开发优先级与里程碑

### Phase 1: 基础框架（2-3周）
- [ ] 风格EQ旋钮组件开发
- [ ] 预设档位定义与数据结构
- [ ] 与现有`PIDRecommendationEngine`集成点设计

### Phase 2: 交互实现（3-4周）
- [ ] 交互式曲线编辑器UI
- [ ] 实时预览功能
- [ ] 安全限制系统

### Phase 3: 质量保证（2-3周）
- [ ] 校准门RMSE系统实现
- [ ] 用户引导流程设计
- [ ] 测试用例与边界条件

### Phase 4: 优化完善（1-2周）
- [ ] 性能优化（实时响应速度）
- [ ] 用户体验细节优化
- [ ] 文档与示例

---

## 📊 用户价值验证指标

### 功能有效性指标
- **校准通过率**：用户首次校准的成功率（目标>80%）
- **风格调整效率**：从调整到获得满意风格的时间（目标<5分钟）
- **推荐采纳率**：用户接受推荐PID调整的比例（目标>70%）

### 用户体验指标
- **操作便捷度**：完成风格调整的点击次数（目标<10次）
- **理解度**：用户对风格旋钮语义的理解程度（目标>90%用户清楚）
- **满意度**：NPS评分（目标>40）

### 技术性能指标
- **实时性**：从调整到看到预测曲线的响应时间（目标<100ms）
- **准确性**：预测曲线与实际曲线的RMSE（目标<0.05）
- **稳定性**：系统长时间运行的内存使用（目标<100MB）

---

## 🎯 后续演进方向

### 短期优化（1-2个月）
- **混合模式**：允许用户混合不同预设（如50% Racer + 50% Cinematic）
- **风格模板**：用户自定义保存风格模板
- **智能推荐**：基于飞手历史数据推荐风格偏好

### 中期扩展（2-3个月）
- **多轴协同**：三轴风格调整的联动关系
- **环境自适应**：根据飞行环境自动调整风格
- **数据导入**：从现有工具导入PID并分析风格

### 长期愿景（6个月+）
- **云端同步**：风格模板云端存储与分享
- **社区风格库**：用户贡献的优秀风格模板
- **AI风格助手**：基于飞行行为自动生成风格建议