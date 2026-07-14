# INAV 自动调参（Autotune）技术研究

> 基于 INAV 固件源码（github.com/iNavFlight/inav）分析
> 核心源文件：`src/main/flight/pid_autotune.c`
> 分析日期：2026-05-23

---

## 一、总体架构

### 1.1 算法类型

**统计收敛法（EMA 指数移动平均）**

- ❌ 不是 Ziegler-Nichols 方法
- ❌ 不是 Relay 反馈法
- ❌ 不是系统辨识 / 模型拟合
- ✅ 是基于飞行数据的移动平均 + EMA 渐进收敛

### 1.2 设计哲学

INAV 的 Autotune **只自动整定 FF（前馈）增益**，不自动调 P/I/D。

2021年9月的 commit `22ba20fbe6` 明确标题为 **"remove P, I and D from struct"**。

原因：
- 固定翼飞机中 FF 是主控制量（前馈直接对应舵面需求）
- P、I、D 是辅助修正项（处理误差）
- 自动调 FF 安全可控，自动调 P/I/D 风险高

### 1.3 PIFF 控制器输出公式

INAV 固定翼使用 PIFF 控制器（pid.c `pidApplyFixedWingRateController()`）：

```
output = P_term + FF_term + I_term + D_term

其中：
  FF_term = rateTarget × kFF          （前馈，比例于目标速率）
  P_term  = rateError × kP            （比例，基于误差）
  I_term += rateError × kI × dT       （积分）
  D_term  = 基于设定点变化率            （微分，非误差微分）
```

---

## 二、核心算法详解

### 2.1 数据采集条件

触发采样需同时满足三个条件：

```c
const float stickInput = absDesiredRate / maxDesiredRate;

if ((stickInput > (pidAutotuneConfig()->fw_min_stick / 100.0f))  // 条件1: 摇杆输入 > 50%
    && correctDirection                                               // 条件2: 响应方向与指令一致
    && (timeSincePreviousSample >= 20))                               // 条件3: 距上次采样 >= 20ms
```

| 条件 | 默认值 | 含义 |
|------|--------|------|
| 摇杆输入 | > 50% | 过滤小机动噪声 |
| 方向一致 | 布尔值 | 飞机响应方向必须与指令方向一致 |
| 采样间隔 | >= 20ms | 50Hz 采样频率 |

### 2.2 移动平均计算

对每个轴持续维护三个指数移动平均：

```c
// 窗口 = min(updateCount, 1000)，即最多1000个采样的移动平均

// 平均期望角速率
tuneCurrent[axis].absDesiredRateAccum +=
    (absDesiredRate - tuneCurrent[axis].absDesiredRateAccum)
    / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);

// 平均实际角速率
tuneCurrent[axis].absReachedRateAccum +=
    (absReachedRate - tuneCurrent[axis].absReachedRateAccum)
    / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);

// 平均PID输出量
tuneCurrent[axis].absPidOutputAccum +=
    (absPidOutput - tuneCurrent[axis].absPidOutputAccum)
    / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);
```

| 变量 | 含义 | 用途 |
|------|------|------|
| `absDesiredRateAccum` | 平均期望角速率 | 辅助判断 |
| `absReachedRateAccum` | 平均实际角速率 | 计算 targetFF 的分母 |
| `absPidOutputAccum` | 平均 PID 输出量 | 计算 targetFF 的分子 |

### 2.3 FF 增益更新公式（核心收敛逻辑）

更新触发条件：**每 25 个采样点** 且 **总采样数 >= 250**

```c
if ((tuneCurrent[axis].updateCount & 25) == 0
    && tuneCurrent[axis].updateCount >= 250) {

    // 目标 FF = (平均PID输出 / 平均实际角速率) × FF乘数常数
    float targetFF = tuneCurrent[axis].absPidOutputAccum
                     / tuneCurrent[axis].absReachedRateAccum
                     * FP_PID_RATE_FF_MULTIPLIER;  // 31.0f

    // 指数移动平均收敛（收敛速率 = 10%）
    gainFF += (targetFF - gainFF) * (AUTOTUNE_FIXED_WING_CONVERGENCE_RATE / 100.0f);

    // 约束到安全范围 [10, 255]
    tuneCurrent[axis].gainFF = constrainf(gainFF, 10, 255);
}
```

**数学本质**：
```
targetFF = mean(|PID_Output|) / mean(|ReachedRate|) × 31.0

gainFF_new = gainFF_old + (targetFF - gainFF_old) × 0.10
```

含义：
- `mean(|PID_Output|) / mean(|ReachedRate|)` = 每度/秒角速率需要多少控制量
- `× 31.0` = 转换到 INAV 的 FF 增益单位
- `× 0.10` = 低通滤波，每次只向目标靠近 10%

### 2.4 最大角速率（Rate）发现

```c
// 目标舵面偏转 = 90% 的 PID 输出限制
float pidSumTarget = 0.90 * pidSumLimit;

// 推算满舵能达到的最大角速率
rateFullStick = pidSumTarget / absPidOutputAccum * absReachedRateAccum;

// 步进调整（每次 +/- 10 deg/s）
if (rateFullStick > (maxRateSetting + 10.0f))
    maxRateSetting += 10.0f;
else if (rateFullStick < (maxRateSetting - 10.0f))
    maxRateSetting -= 10.0f;

// 安全限制
minRate = (yaw) ? 10 : 40;   // deg/s × 10
maxRate = (AUTO模式) ? 720 : MAX(initialRate, minRate);
```

---

## 三、安全保护机制

### 3.1 完整保护清单

| 机制 | 实现方式 | 参数 |
|------|----------|------|
| **FF 范围限制** | `constrainf(gainFF, 10, 255)` | 硬限制 [10, 255] |
| **Rate 范围限制** | 条件判断 | Roll/Pitch: 40~720, Yaw: 10~720 (deg/s×10) |
| **方向一致性检查** | `(desiredRate>0) == (reachedRate>0)` | 布尔值，不一致则跳过 |
| **最小摇杆输入** | `fw_min_stick` | 默认 50%，低于此值不采样 |
| **最小采样数** | `updateCount >= 250` | 至少 250 个采样（约 5 秒）才开始调整 |
| **收敛速率** | `AUTOTUNE_FIXED_WING_CONVERGENCE_RATE` | 每步仅 10%，防止剧烈跳变 |
| **Rate 步进限制** | 每次 `+/- 10 deg/s` | 缓慢调整 |
| **快照保存** | 每 5 秒保存 | 退出 autotune 时恢复上次快照 |
| **I-term 冻结** | 大坡度时 | 冻结 Yaw I-term |
| **ANGLE 模式保护** | ANGLE 模式下 | 不调整 Rate |
| **MANUAL 模式跳过** | MANUAL 模式下 | 不运行 autotune |

### 3.2 算法状态机

```
[解锁起飞]
    ↓
[切换 AUTOTUNE 模式]
    ↓
autotuneStart()
  - 保存当前 FF/Rate 值
  - 初始化移动平均累积器
  - updateCount = 0
    ↓
[飞行循环 - 主循环]
    ↓
├── 摇杆 > 50% && 方向一致 && 间隔 >= 20ms？
│   ├── Yes: 采集数据
│   │   ├── 更新三个移动平均（desiredRate, reachedRate, pidOutput）
│   │   ├── updateCount++
│   │   ├── updateCount >= 250 && (updateCount % 25 == 0)？
│   │   │   ├── Yes:
│   │   │   │   ├── 计算 targetFF = meanOutput / meanRate × 31.0
│   │   │   │   ├── EMA 收敛 gainFF (10%)
│   │   │   │   ├── constrain(gainFF, 10, 255)
│   │   │   │   └── 可选: 调整 maxRate (+/- 10 deg/s)
│   │   │   └── No: 继续采样
│   │   └── 将 gainFF 应用到 PID 控制器
│   └── No: 跳过本次采样
├── 每 5 秒: 保存快照
└── [退出 AUTOTUNE 模式]
    ↓
autotuneStop()
  - 保存最终 FF/Rate 到配置
  - 用户需要执行 `save` 才会永久生效
```

---

## 四、关键常量

```c
#define FP_PID_RATE_FF_MULTIPLIER           31.0f   // FF 增益乘数常量
#define AUTOTUNE_FIXED_WING_SAMPLES         1000    // 移动平均窗口大小
#define AUTOTUNE_FIXED_WING_CONVERGENCE_RATE 10      // 收敛速率 10%
// fw_min_stick = 50  (%)
// 采样间隔 = 20ms (50Hz)
// 最小采样数 = 250 (约5秒)
// FF 范围 = [10, 255]
// Rate 步进 = +/- 10 deg/s
```

---

## 五、与 Betaflight 的对比

### 5.1 BF Simplified Tuning（Slider）

BF 从 4.3 开始引入 Slider 系统（INAV 没有类似机制）：

```
set simplified_pids_mode = 2              // OFF/RP/RPY
set simplified_master_multiplier = 100    // 0-200, 100=1x
set simplified_pi_gain = 100              // P和I的乘数
set simplified_d_gain = 100               // D的乘数
set simplified_feedforward_gain = 100     // FF的乘数
set simplified_i_gain = 100               // I相对P的比例
```

固件内部计算：
```c
pidProfile->pid[axis].P = constrain(
    pidDefaults[axis].P × masterMultiplier × piGain × pitchPiGain,
    0, 250);
```

### 5.2 BF 4.6 Chirp AutoTune

BF 4.6 引入了基于频率扫描的 AutoTune（INAV 没有此功能）：
- 发射扫频信号（Chirp）
- 分析频率响应
- 在频域优化 PID 参数
- 与 INAV 的时域统计方法完全不同

### 5.3 共同点

| 特征 | BF | INAV |
|------|-----|------|
| FF 最大值 | 1000 (F_GAIN_MAX) | 255 |
| P/I/D 最大值 | 250 (PID_GAIN_MAX) | 255 |
| 安全收敛 | Slider constrain | EMA 10% |
| 非Expert限制 | 70~140 (0.7x~1.4x) | N/A |

---

## 六、对 PID_Liner 的启发

### 6.1 可借鉴的设计

1. **渐进收敛策略** — INAV 用 10% EMA 收敛，PID_Liner 的迭代调参可以采用类似策略：每轮只向目标靠近一定比例，而非一步到位
2. **输入质量过滤** — "摇杆 > 50% 才采样"，PID_Liner 在分析 BBL 时应过滤低机动段数据
3. **方向一致性检查** — 确保飞机响应方向与设定点一致，检测无效数据
4. **安全硬限制** — constrain 到 [10, 255]，不依赖软限制
5. **最小数据量门槛** — 250 个采样才开始调整，确保统计显著

### 6.2 PID_Liner 的差异化优势

| 能力 | INAV | PID_Liner |
|------|------|-----------|
| 数据来源 | 飞行中实时采样 | 完整 BBL 时间序列 |
| 分析深度 | 移动平均 | 特征提取 + 诊断 + 推荐 |
| 调参维度 | 仅 FF | P/I/D/FF 全部 |
| 预测能力 | 无 | 二阶系统模型预测曲线 |
| 迭代学习 | 无 | 修正系数反馈（需完善） |
| 离线分析 | 不支持 | 完整离线分析 |

### 6.3 需要注意的风险

1. **INAV 只调 FF 的事实说明**：自动调参的安全性是核心挑战，调整维度越少越安全
2. **INAV 用最简单的统计算法**：说明复杂模型不一定比简单统计更可靠
3. **BF 的 Slider 也是乘数体系**：行业标准是"基于默认值的倍率调整"，而非"直接写真值"

---

## 七、对 PID_Liner 的核心启示

### 启示1：BF 的整个生态都围绕 Slider 倍率体系

BF 的 Chirp AutoTune 输出的是 **Slider 倍率**（`simplified_pi_gain`, `simplified_d_gain` 等），不是直接 PID 值。这意味着：

- PID_Liner 应该输出 Slider CLI 命令（`set simplified_d_gain = 110`）而不是直接值（`set d_roll = 33`）
- 或者至少需要先关闭 Slider 模式再输出直接值（`set simplified_pids_mode = OFF`）
- 🔑 **现状风险**：当前 PID_Liner 直接输出 `set d_roll = 33`，如果用户 Slider 开着，BF 会在下次启动时检测到不一致并关闭 Slider，用户的 Slider 设置全部丢失

### 启示2：频域分析是 BF 的核心能力

BF Chirp 用 Welch FFT 分析传递函数，从频域提取带宽、相位裕度、谐振峰。PID_Liner 现在的时域分析（超调量、上升时间）是另一个维度，两者互补。

- 时域指标：超调量、上升时间、建立时间 → 用户直观理解
- 频域指标：带宽、相位裕度、谐振峰 → 工程级精确调参
- 🔑 **建议**：PID_Liner 可以从 BBL 数据中提取频域特征作为诊断补充，不需要 Chirp 扫频也能做频谱分析

### 启示3：INAV 的极简方案证明了"安全 > 精确"

INAV 只调 FF 一项，用最简单的统计算法（EMA），收敛率只有 10%。这说明在飞控领域：

- 宁可保守也不要炸机
- 简单算法 + 强安全机制 > 复杂算法 + 弱安全机制
- INAV 2021年主动删除了 P/I/D 自动调整（commit `22ba20fbe6`），说明多维度自动调参在实践中风险过高
- 🔑 **PID_Liner 应借鉴**：迭代调参的每步调整量应该保守，宁可多飞几轮也不要一步到位

### 启示4：谐振峰检测是关键安全机制

BF Chirp 在谐振峰 > 6dB 时自动回退增益（P×0.75, D×0.85, FF×0.80）。PID_Liner 应该也加入类似的频域安全检查。

- 谐振峰 > 6dB → 严重振荡风险，紧急回退
- 谐振峰 > 3dB → 中等风险，轻微回退
- 🔑 **可从 BBL 实现**：对 gyro 数据做 FFT，检测是否存在明显的频率峰值（机械共振），在推荐参数时考虑避开共振频率

### 启示5：反向映射是 Slider 兼容的前提

用户的 BBL 里读出的是直接 PID 值（如 `d_roll = 33`），要输出 Slider 命令就必须做反算：

```
已知: 当前 PID 值（从BBL元数据读取）
求解: 对应的 Slider 倍率

例: d_roll = 33, 默认 D_roll = 30
    simplified_d_gain = 33 / 30 × 100 ≈ 110
    simplified_master_multiplier 需要联合求解（多轴联动）
```

这是一个多轴联立的方程组，因为 `master_multiplier` 同时影响 P/I/D/FF。需要 BF 源码中的 `calculateNewPidValues()` 逆函数。

### 启示6：BF 的 PID 硬限制必须遵守

```
P/I/D 单项: 0 ~ 250  (PID_GAIN_MAX)
FF:         0 ~ 1000 (F_GAIN_MAX)
PID Sum:    100 ~ 1000（默认 RP=500, Yaw=400）
Slider:     0 ~ 200 (0% ~ 200%)
```

🔑 **PID_Liner 的 `kPIDMaxValue = 200` 不准确**：
- P/I/D 最大应为 250（不是 200）
- FF 最大应为 1000（不是 200）
- 还需加入 PID Sum 总和检查

---

## 九、源码参考

| 文件 | 路径 | 说明 |
|------|------|------|
| pid_autotune.c | `src/main/flight/pid_autotune.c` | Autotune 核心算法 |
| pid.h | `src/main/flight/pid.h` | PID 结构体和常量定义 |
| pid.c | `src/main/flight/pid.c` | PIFF 控制器实现 |
| simplified_tuning.c | `src/main/config/simplified_tuning.c` | BF 的 Slider 实现（INAV无） |
| Autotune 文档 | `docs/Autotune - fixedwing.md` | 固定翼 Autotune 使用说明 |
| PID Tuning 文档 | `docs/PID tuning.md` | PID 调参通用说明 |

---

## 十、相关链接

- INAV 主仓库：https://github.com/iNavFlight/inav
- INAV Autotune 源码：https://github.com/iNavFlight/inav/blob/master/src/main/flight/pid_autotune.c
- INAV Autotune 文档：https://github.com/iNavFlight/inav/blob/master/docs/Autotune%20-%20fixedwing.md
- INAV PID 调参文档：https://github.com/iNavFlight/inav/blob/master/docs/PID%20tuning.md
- INAV Autotune Issue #8869（PID值不更新但FF更新）：https://github.com/iNavFlight/inav/discussions/8869
- INAV Autotune Issue #9727（Roll轴震荡）：https://github.com/iNavFlight/inav/issues/9727
- BF Simplified Tuning 源码：https://github.com/betaflight/betaflight/blob/master/src/main/config/simplified_tuning.c
- BF pid.h 常量定义：https://github.com/betaflight/betaflight/blob/master/src/main/flight/pid.h
- BF Configurator Slider 实现：https://github.com/betaflight/betaflight-configurator/blob/master/src/composables/useTuningSliders.js
