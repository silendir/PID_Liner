# BF Chirp AutoTune 技术重点

> 基于 Betaflight 2025.12（原4.6）固件源码分析
> 核心PR：固件侧 `betaflight/betaflight#15113`、Configurator侧 `betaflight/betaflight-configurator#5000`
> 分析日期：2026-05-24

---

## 一、BF 三大调参体系总览

| 体系 | 方法 | 调参维度 | 输出格式 | 需要飞行 |
|------|------|----------|----------|----------|
| **Simplified Tuning (Slider)** | 预设默认值 × 手动乘数 | P/I/D/FF/DMax + 滤波器 | Slider倍率 | 否 |
| **Chirp AutoTune** | 频域系统辨识（FFT） | P/I/D/FF/滤波器 | Slider倍率 | 是（扫频飞行） |
| **手动CLI** | 直接写真值 | 全部 | 直接PID值 | 否 |

---

## 二、BF Simplified Tuning（Slider）详解

### 2.1 设计哲学

BF 开发者有一套"黄金默认值"（基于5寸穿越机调优），所有Slider计算以此为基础：

```
Roll:  P=45, I=80, D=30, F=120, DMax=40
Pitch: P=47, I=84, D=34, F=125, DMax=46
Yaw:   P=45, I=80, D=0,  F=120, DMax=0
```

源码位置：`src/main/flight/pid.h`

```c
#define PID_ROLL_DEFAULT  { 45, 80, 30, 120, 0 }   // P, I, D, F, S
#define PID_PITCH_DEFAULT { 47, 84, 34, 125, 0 }
#define PID_YAW_DEFAULT   { 45, 80,  0, 120, 0 }
#define D_MAX_DEFAULT     { 40, 46, 0 }
```

### 2.2 Slider 参数清单

| CLI 命令 | 类型 | 范围 | 默认值 | 说明 |
|----------|------|------|--------|------|
| `simplified_pids_mode` | uint8 | 0=OFF, 1=RP, 2=RPY | 0 | 控制哪些轴受Slider影响 |
| `simplified_master_multiplier` | uint8 | 0-200 | 100 | 总增益乘数 |
| `simplified_pi_gain` | uint8 | 0-200 | 100 | P和I的联合乘数 |
| `simplified_d_gain` | uint8 | 0-200 | 100 | D的独立乘数 |
| `simplified_feedforward_gain` | uint8 | 0-200 | 100 | FF乘数 |
| `simplified_i_gain` | uint8 | 0-200 | 100 | I相对P的比例 |
| `simplified_d_max_gain` | uint8 | 0-200 | 100 | D Max乘数 |
| `simplified_pitch_d_gain` | uint8 | 0-200 | 100 | Pitch D相对Roll D（⚠️ 结构体字段叫 roll_pitch_ratio，但 CLI 命令名是 pitch_d_gain） |
| `simplified_pitch_pi_gain` | uint8 | 0-200 | 100 | Pitch PI额外增益 |
| `simplified_dterm_filter` | bool | 0/1 | 0 | D-term滤波Slider开关 |
| `simplified_dterm_filter_multiplier` | uint8 | 10-200 | 100 | D-term滤波乘数 |
| `simplified_gyro_filter` | uint8 | 0/1 | 0 | 陀螺仪滤波Slider开关 |
| `simplified_gyro_filter_multiplier` | uint8 | 10-200 | 100 | 陀螺仪滤波乘数 |

常量定义（`simplified_tuning.h`）：

```c
#define SIMPLIFIED_TUNING_PIDS_MIN    0
#define SIMPLIFIED_TUNING_FILTERS_MIN 10
#define SIMPLIFIED_TUNING_MAX         200
#define SIMPLIFIED_TUNING_DEFAULT     100
```

### 2.3 计算公式

源码：`src/main/config/simplified_tuning.c` — `calculateNewPidValues()`

```
masterMultiplier = simplified_master_multiplier / 100.0
piGain           = simplified_pi_gain / 100.0
dGain            = simplified_d_gain / 100.0
feedforwardGain  = simplified_feedforward_gain / 100.0
iGain            = simplified_i_gain / 100.0

// Per-axis Pitch 特殊调整
pitchDGain  = (axis == PITCH) ? simplified_pitch_d_gain / 100.0 : 1.0
pitchPiGain = (axis == PITCH) ? simplified_pitch_pi_gain / 100.0   : 1.0
```

最终PID值：

```
P[axis] = constrain(Default_P × master × pi × pitchPI,          0, 250)
I[axis] = constrain(Default_I × master × pi × i × pitchPI,      0, 250)
D[axis] = constrain(Default_D × master × d × pitchD,            0, 250)
F[axis] = constrain(Default_F × master × pitchPI × ff,           0, 1000)
```

注意：
- P 和 I 共享 `piGain`（没有单独的P slider）
- FF 不受 `piGain` 影响（走独立路径 `master × pitchPI × ff`）
- D 走独立路径 `master × d × pitchD`

#### 2.3.1 ★ 黄金默认值表（正映射基准）

源码：`src/main/flight/pid.h`

| 轴 | P | I | D | F(FF) | DMax |
|----|---|---|---|-------|------|
| **Roll** | 45 | 80 | 30 | 120 | 40 |
| **Pitch** | 47 | 84 | 34 | 125 | 46 |
| **Yaw** | 45 | 80 | **0** | 120 | **0** |

```c
#define PID_ROLL_DEFAULT  { 45, 80, 30, 120, 0 }   // P, I, D, F, S
#define PID_PITCH_DEFAULT { 47, 84, 34, 125, 0 }
#define PID_YAW_DEFAULT   { 45, 80,  0, 120, 0 }
#define D_MAX_DEFAULT     { 40, 46, 0 }
```

🔑 **所有 Slider=100 时，输出精确等于上表的默认值。** 这是 Slider 体系的安全锚点。

#### 2.3.2 ★ 正映射完整公式（Slider → PID 真值）

每个公式展开为具体数值，可直接用于代码实现：

**Roll 轴（pitchPiGain=1.0, pitchDGain=1.0）：**

```
P_roll    = 45  × (master/100) × (pi_gain/100)                          → constrain(0, 250)
I_roll    = 80  × (master/100) × (pi_gain/100) × (i_gain/100)          → constrain(0, 250)
D_roll    = 30  × (master/100) × (d_gain/100)                          → constrain(0, 250)
FF_roll   = 120 × (master/100) × (ff_gain/100)                         → constrain(0, 1000)
DMax_roll = 40  × (master/100) × (d_gain/100) × dMaxGain               → constrain(0, 250)
```

**Pitch 轴（pitchPiGain/roll_pitch_ratio 生效）：**

```
P_pitch    = 47  × (master/100) × (pi_gain/100) × (pitch_pi/100)       → constrain(0, 250)
I_pitch    = 84  × (master/100) × (pi_gain/100) × (i_gain/100) × (pitch_pi/100) → constrain(0, 250)
D_pitch    = 34  × (master/100) × (d_gain/100) × (roll_pitch/100)      → constrain(0, 250)
FF_pitch   = 125 × (master/100) × (pitch_pi/100) × (ff_gain/100)       → constrain(0, 1000)
DMax_pitch = 46  × (master/100) × (d_gain/100) × (roll_pitch/100) × dMaxGain → constrain(0, 250)
```

**Yaw 轴（与 Roll 乘数相同，但 D/DMax 默认=0）：**

```
P_yaw    = 45  × (master/100) × (pi_gain/100)                          → constrain(0, 250)
I_yaw    = 80  × (master/100) × (pi_gain/100) × (i_gain/100)          → constrain(0, 250)
D_yaw    = 0   × ... = 0                                                （永远为0）
FF_yaw   = 120 × (master/100) × (ff_gain/100)                         → constrain(0, 1000)
DMax_yaw = 0   × ... = 0                                                （永远为0）
```

#### 2.3.3 ★ 反向映射公式（PID 真值 → Slider）

已知目标 PID 值，反算 Slider 乘数。**前提：固定 master=100。**

当 `master_multiplier = 100` 时，每个 Slider 可独立反算（消解多轴耦合）：

```
// ──── P/I 共享 pi_gain ────
pi_gain = round( (P_target_roll / 45) × 100 )
// 验证: 45 × (pi_gain/100) = P_target_roll

// ──── I 的额外乘数 ────
i_gain = round( (I_target_roll / 80) / (pi_gain/100) × 100 )
// 展开: I_target = 80 × (pi/100) × (i/100) → i = I_target / (80 × pi/100) × 100

// ──── D 独立 ────
d_gain = round( (D_target_roll / 30) × 100 )

// ──── FF 独立 ────
ff_gain = round( (FF_target_roll / 120) × 100 )

// ──── Pitch 专用 ────
pitch_pi_gain = round( (P_target_pitch / 47) / (pi_gain/100) × 100 )
roll_pitch_ratio = round( (D_target_pitch / 34) / (d_gain/100) × 100 )
```

**数值示例：**

```c
// 目标: P_roll=54 (比默认45高20%), FF_roll=150 (比默认120高25%)
pi_gain = round(54.0 / 45.0 × 100) = 120    // set simplified_pi_gain = 120
ff_gain = round(150.0 / 120.0 × 100) = 125  // set simplified_feedforward_gain = 125

// 验证正映射: 45 × 1.20 = 54 ✅, 120 × 1.25 = 150 ✅
```

**反向映射的精度限制：**

| 误差来源 | 幅度 | 说明 |
|----------|------|------|
| uint8 截断 | ±0.5 | PID值和Slider值都是整数 |
| 多轴耦合 | N/A | master=100 时自动消解 |
| DMax 非线性 | ±1 | 混合公式引入额外误差 |

🔑 **结论：固定 master=100 时，反算误差在 ±1 以内，完全可用于推荐。**

#### 2.3.4 ★ Slider 安全保护层级（为什么"不会超调"）

Slider 体系有三层嵌套保护，确保输出PID值永远在安全范围内：

```
┌─────────────────────────────────────────────────┐
│ 第1层: Slider 值域 [0, 200]                      │  最多 2x 默认值
│   P_roll 最大 = 45 × 2.0 = 90                   │  远低于硬上限250
│   FF_roll 最大 = 120 × 2.0 = 240                │  远低于硬上限1000
├─────────────────────────────────────────────────┤
│ 第2层: constrain(0, 250/1000)                    │  固件硬上限
│   即使乘法结果超限也会被钳位                      │
├─────────────────────────────────────────────────┤
│ 第3层: 非Expert模式 UI限制                        │  Configurator侧
│   PID 滑条: 70~140 (0.7x~1.4x)                   │
│   D-term:   80~120 (0.8x~1.2x)                   │
│   Gyro:     50~150 (0.5x~1.5x)                   │
└─────────────────────────────────────────────────┘
```

**具体数值验证（Slider 拉满到 200 = 2x）：**

| 项 | 默认值 | ×2.0 | 硬上限 | 安全？ |
|----|--------|------|--------|--------|
| P_roll | 45 | 90 | 250 | ✅ 远低于 |
| I_roll | 80 | 160 | 250 | ✅ 低于 |
| D_roll | 30 | 60 | 250 | ✅ 远低于 |
| FF_roll | 120 | 240 | 1000 | ✅ 远低于 |

🔑 **Slider 拉满也只到默认值的2倍，远低于固件硬上限。这就是"Slider保护下不会超调"的根本原因。**

#### 2.3.5 ★ BF 4.6（2025.12）完整参数对照表

源码：`pid.h` + `settings.c` + `simplified_tuning.h`

**PID 增益默认值与范围（Slider全=100时的输出）：**

| 参数 | CLI命令 | 默认值 | 最小 | 最大 | 类型 |
|------|---------|--------|------|------|------|
| Roll P | `p_roll` | 45 | 0 | 250 | uint8 |
| Roll I | `i_roll` | 80 | 0 | 250 | uint8 |
| Roll D | `d_roll` | 30 | 0 | 250 | uint8 |
| Roll FF | `f_roll` | 120 | 0 | 1000 | uint16 |
| Roll DMax | `d_max_roll` | 40 | 0 | 250 | uint8 |
| Pitch P | `p_pitch` | 47 | 0 | 250 | uint8 |
| Pitch I | `i_pitch` | 84 | 0 | 250 | uint8 |
| Pitch D | `d_pitch` | 34 | 0 | 250 | uint8 |
| Pitch FF | `f_pitch` | 125 | 0 | 1000 | uint16 |
| Pitch DMax | `d_max_pitch` | 46 | 0 | 250 | uint8 |
| Yaw P | `p_yaw` | 45 | 0 | 250 | uint8 |
| Yaw I | `i_yaw` | 80 | 0 | 250 | uint8 |
| Yaw D | `d_yaw` | 0 | 0 | 250 | uint8 |
| Yaw FF | `f_yaw` | 120 | 0 | 1000 | uint16 |
| Yaw DMax | `d_max_yaw` | 0 | 0 | 250 | uint8 |

**Slider 乘数参数：**

| CLI命令 | 默认值 | 最小 | 最大 | 控制范围 |
|---------|--------|------|------|----------|
| `simplified_pids_mode` | RP(1) | OFF(0) | RPY(2) | OFF/RP/RPY |
| `simplified_master_multiplier` | 100 | 0 | 200 | 全局缩放 |
| `simplified_pi_gain` | 100 | 0 | 200 | P 和 I |
| `simplified_d_gain` | 100 | 0 | 200 | D 和 DMax |
| `simplified_feedforward_gain` | 100 | 0 | 200 | FF |
| `simplified_i_gain` | 100 | 0 | 200 | I 额外倍率 |
| `simplified_d_max_gain` | 100 | 0 | 200 | DMax 额外倍率 |
| `simplified_pitch_d_gain` | 100 | 0 | 200 | Pitch D 比率（⚠️ CLI命令名，结构体字段叫roll_pitch_ratio） |
| `simplified_pitch_pi_gain` | 100 | 0 | 200 | Pitch PI/FF |

**PID Sum 与运行时限制：**

| CLI命令 | 默认值 | 最小 | 最大 | 说明 |
|---------|--------|------|------|------|
| `pidSumLimit` | 500 | 100 | 1000 | Roll/Pitch PID总和上限 |
| `pidSumLimitYaw` | 400 | 100 | 1000 | Yaw PID总和上限 |
| `d_max_gain` | 55 | 0 | 100 | DMax 动态增益 |
| `d_max_advance` | 20 | 0 | 200 | DMax 提前量 |

**Feedforward 精细参数：**

| CLI命令 | 默认值 | 最小 | 最大 |
|---------|--------|------|------|
| `feedforward_transition` | 0 | 0 | 100 |
| `feedforward_boost` | 15 | 0 | 50 |
| `feedforward_rate` | 60 | 0 | 255 |
| `feedforward_jitter_factor` | 7 | 0 | 20 |
| `feedforward_smoothing_factor` | 25 | 0 | 55 |
| `feedforward_yaw_hold` | 10 | 0 | 255 |

**滤波器默认值：**

| 参数 | 默认值 | 最小 | 最大 |
|------|--------|------|------|
| `dterm_lpf1_dyn_min_hz` | 75 | 0 | 1000 |
| `dterm_lpf1_dyn_max_hz` | 150 | 0 | 1000 |
| `dterm_lpf2_static_hz` | 150 | 0 | 1000 |
| `gyro_lpf1_dyn_min_hz` | 250 | 0 | 1000 |
| `gyro_lpf1_dyn_max_hz` | 500 | 0 | 1000 |
| `gyro_lpf2_static_hz` | 500 | 0 | 1000 |

**PID 计算缩放因子（pid.h 内部常量）：**

| 缩放因子 | 值 | 用途 |
|----------|-----|------|
| `PTERM_SCALE` | 0.032029f | P项缩放 |
| `ITERM_SCALE` | 0.244381f | I项缩放 |
| `DTERM_SCALE` | 0.000529f | D项缩放 |
| `FEEDFORWARD_SCALE` | 0.013754f | FF项缩放 |

**TPA 参数：**

| CLI命令 | 默认值 | 最小 | 最大 |
|---------|--------|------|------|
| `tpa_rate` | 65 | 0 | 100 |
| `tpa_breakpoint` | 1250 | 1000 | 2000 |

#### 2.3.6 ★ PID_Liner CLI 输出策略：强制开启 Slider

PID_Liner 推荐参数时，无需判断用户当前 Slider 状态，直接强制开启：

```
# PID_Liner 推荐输出格式
set simplified_pids_mode = RPY
set simplified_master_multiplier = 100
set simplified_pi_gain = {推荐值}
set simplified_d_gain = {推荐值}
set simplified_feedforward_gain = {推荐值}
set simplified_i_gain = {推荐值}
set simplified_d_max_gain = {推荐值}
set simplified_pitch_d_gain = {推荐值}
set simplified_pitch_pi_gain = {推荐值}
save
```

🔑 **安全性保证**：
- `set simplified_pids_mode = RPY` 放第一行，强制开启 Slider 模式
- 所有推荐值限制在 [0, 200] 范围内（对应 0~2x 默认值）
- Slider 模式下的 PID 真值由固件公式计算，天然受 constrain 保护
- 即使用户手动改了某个 PID 值，Configurator 会检测不一致并回退

🔑 **与直接写真值的对比**：

| 方案 | CLI输出 | 安全性 | 与Configurator兼容 |
|------|---------|--------|-------------------|
| **方案A: Slider命令** | `set simplified_d_gain = 110` | ✅ 固件级保护 | ✅ 完全兼容 |
| 方案B: 先关Slider再写真值 | `set simplified_pids_mode = OFF` + `set d_roll = 33` | ⚠️ 失去Slider保护 | ⚠️ 用户无法再用Slider |
| ~~方案C: 直接写真值~~ | `set d_roll = 33` | ❌ Slider冲突 | ❌ Configurator关闭Slider |

#### 2.3.7 ★ BF 各版本 Slider CLI 命令兼容性表

源码验证：`settings.c`（4.3-maintenance / 4.4 / 4.5 / master 四个分支逐一对比）

**所有 `simplified_*` 命令从 BF 4.3 引入，4.3→4.4→4.5→2025.12 完全无变化。BF 4.2 及以下不支持。**

| CLI 命令（真实命令名） | 4.3 | 4.4 | 4.5 | 2025+ | 类型 | 范围 | 默认 |
|---|---|---|---|---|---|---|---|
| `simplified_pids_mode` | ✅ | ✅ | ✅ | ✅ | lookup | OFF/RP/RPY | RP |
| `simplified_master_multiplier` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_pi_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_i_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_d_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_feedforward_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_d_max_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_pitch_d_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_pitch_pi_gain` | ✅ | ✅ | ✅ | ✅ | uint8 | 0-200 | 100 |
| `simplified_dterm_filter` | ✅ | ✅ | ✅ | ✅ | lookup | OFF/ON | OFF |
| `simplified_dterm_filter_multiplier` | ✅ | ✅ | ✅ | ✅ | uint8 | 10-200 | 100 |
| `simplified_gyro_filter` | ✅ | ✅ | ✅ | ✅ | lookup | OFF/ON | OFF |
| `simplified_gyro_filter_multiplier` | ✅ | ✅ | ✅ | ✅ | uint8 | 10-200 | 100 |

⚠️ **命名陷阱**：`simplified_pitch_d_gain` 的结构体字段名是 `roll_pitch_ratio`（源码 `pidProfile_t.simplified_roll_pitch_ratio`），但 **CLI 命令名**是 `simplified_pitch_d_gain`（通过 `PARAM_NAME_SIMPLIFIED_PITCH_D_GAIN` 宏映射）。PID_Liner 代码中属性名保持 `rollPitchRatio` 以匹配公式含义，CLI 输出时使用正确的命令名。

**Scope 分类：**
- **PROFILE scope**（切换 Profile 独立保存）: `pids_mode`, `master_multiplier`, `pi_gain`, `i_gain`, `d_gain`, `d_max_gain`, `feedforward_gain`, `pitch_d_gain`, `pitch_pi_gain`, `dterm_filter`, `dterm_filter_multiplier`
- **MASTER scope**（全局设置）: `gyro_filter`, `gyro_filter_multiplier`

**验证方法：**

| 方法 | 说明 |
|------|------|
| BF Configurator CLI | 连接飞控 → CLI 标签 → 粘贴命令 → 观察是否报错 |
| `dump` 命令 | BF CLI 中输入 `dump` 列出所有设置，确认 `simplified_*` 是否存在 |
| `simplified_tuning apply` | BF CLI 内置命令，手动触发 Slider 计算 |
| `simplified_tuning disable` | BF CLI 内置命令，禁用 Slider |
| 源码真值 | `github.com/betaflight/betaflight/blob/{branch}/src/main/cli/settings.c` 搜索 `simplified` |
| 官方文档 | `betaflight.com/docs/wiki/guides/current/Betaflight-2025.12-CLI-commands` |

D Max 计算（更复杂，融合了D/DMax的默认值比）：

```
dMaxGain = (dMaxDefault > 0)
    ? simplified_d_max_gain / 100.0 + (1 - simplified_d_max_gain / 100.0) × D_default / dMaxDefault
    : 1.0

d_max[axis] = constrain(dMaxDefault × master × d × pitchD × dMaxGain, 0, 250)
```

### 2.4 滤波器计算

**D-Term 滤波器**（`calculateNewDTermFilterValues`）：

```
默认值:
  DTERM_LPF1_DYN_MIN_HZ_DEFAULT = 75
  DTERM_LPF1_DYN_MAX_HZ_DEFAULT = 150
  DTERM_LPF2_HZ_DEFAULT         = 150

当 simplified_dterm_filter = ON:
  dterm_lpf1_dyn_min_hz = constrain(75  × multiplier / 100, 0, 1000)
  dterm_lpf1_dyn_max_hz = constrain(150 × multiplier / 100, 0, 1000)
  dterm_lpf2_static_hz  = constrain(150 × multiplier / 100, 0, 1000)
```

**Gyro 滤波器**（`calculateNewGyroFilterValues`）：

```
默认值:
  GYRO_LPF1_DYN_MIN_HZ_DEFAULT = 250
  GYRO_LPF1_DYN_MAX_HZ_DEFAULT = 500
  GYRO_LPF2_HZ_DEFAULT         = 500

当 simplified_gyro_filter = ON:
  gyro_lpf1_dyn_min_hz = constrain(250 × multiplier / 100, 0, 1000)
  gyro_lpf1_dyn_max_hz = constrain(500 × multiplier / 100, 0, 1000)
  gyro_lpf2_static_hz  = constrain(500 × multiplier / 100, 0, 1000)
```

### 2.5 Configurator 非Expert模式限制

源码：`useTuningSliders.js`

```javascript
NON_EXPERT_SLIDER_MIN        = 70     // PID滑条最小 0.7x
NON_EXPERT_SLIDER_MAX        = 140    // PID滑条最大 1.4x
NON_EXPERT_SLIDER_MIN_GYRO   = 50     // Gyro滑条最小 0.5x
NON_EXPERT_SLIDER_MAX_GYRO   = 150    // Gyro滑条最大 1.5x
NON_EXPERT_SLIDER_MIN_DTERM  = 80     // D-term滑条最小 0.8x
NON_EXPERT_SLIDER_MAX_DTERM  = 120    // D-term滑条最大 1.2x
```

非线性缩放（slider > 1.0 时灵敏度翻倍）：

```javascript
function scaleSliderValue(value) {
    if (value > 1) {
        return Math.round(((value - 1) * 2 + 1) * 10) / 10;
    }
    return value;
}
```

### 2.6 Slider 与手动CLI的冲突处理

验证协议：`MSP_VALIDATE_SIMPLIFIED_TUNING`

1. Configurator 连接飞控时，发送 `MSP_VALIDATE_SIMPLIFIED_TUNING`
2. 固件复制当前PID配置到临时配置，对临时配置应用Slider计算
3. 逐项对比：`tempPidProfile.pid[i].P == currentPidProfile->pid[i].P`
4. 返回三个布尔值：`pids_valid`、`gyro_valid`、`dterm_valid`
5. 如果不一致 → **Configurator 关闭Slider模式**（手动值优先）

```javascript
// Configurator 侧处理
if (!FC.TUNING_SLIDERS.slider_pids_valid) {
    FC.TUNING_SLIDERS.slider_pids_mode = 0;  // 关闭Slider
}
```

🔑 **结论：手动CLI值优先，检测到冲突时关闭Slider，不会静默覆盖。**

### 2.7 MSP 协议

| MSP 代码 | 方向 | 用途 |
|----------|------|------|
| `MSP_SIMPLIFIED_TUNING` | FC → Configurator | 返回所有Slider值 |
| `MSP_SET_SIMPLIFIED_TUNING` | Configurator → FC | 保存Slider值并立即应用 |
| `MSP_CALCULATE_SIMPLIFIED_PID` | Configurator → FC | **预览**：计算Slider对应的PID值但不保存 |
| `MSP_CALCULATE_SIMPLIFIED_DTERM` | Configurator → FC | 预览D-term滤波值 |
| `MSP_CALCULATE_SIMPLIFIED_GYRO` | Configurator → FC | 预览Gyro滤波值 |
| `MSP_VALIDATE_SIMPLIFIED_TUNING` | Configurator → FC | 验证当前PID是否与Slider一致 |

MSP 载荷结构（`MSP_SIMPLIFIED_TUNING`写入方向）：

**PID部分（12字节 + 8字节保留）：**
- U8: `simplified_pids_mode`
- U8: `simplified_master_multiplier`
- U8: `simplified_pitch_d_gain`（结构体字段名 `roll_pitch_ratio`）
- U8: `simplified_i_gain`
- U8: `simplified_d_gain`
- U8: `simplified_pi_gain`
- U8: `simplified_d_max_gain`
- U8: `simplified_feedforward_gain`
- U8: `simplified_pitch_pi_gain`
- U32: 保留
- U32: 保留

**D-Term滤波部分（12字节 + 8字节保留）：**
- U8: `simplified_dterm_filter`
- U8: `simplified_dterm_filter_multiplier`
- U16: `dterm_lpf1_static_hz`
- U16: `dterm_lpf2_static_hz`
- U16: `dterm_lpf1_dyn_min_hz`
- U16: `dterm_lpf1_dyn_max_hz`
- U32: 保留
- U32: 保留

**Gyro滤波部分（12字节 + 8字节保留）：**
- U8: `simplified_gyro_filter`
- U8: `simplified_gyro_filter_multiplier`
- U16: `gyro_lpf1_static_hz`
- U16: `gyro_lpf2_static_hz`
- U16: `gyro_lpf1_dyn_min_hz`
- U16: `gyro_lpf1_dyn_max_hz`
- U32: 保留
- U32: 保留

---

## 三、BF 4.6 Chirp AutoTune 详解

### 3.1 整体架构

**两阶段闭环系统：固件侧信号生成 + Configurator侧频谱分析**

```
[固件侧]                    [BBL日志]              [Configurator侧]
飞控生成Chirp扫频信号  →  Blackbox记录       →   浏览器内FFT分析
注入到PID setpoint        setpoint+gyro+debug    Welch传递函数估计
                          debug_mode=CHIRP       →  增益推荐
                                                  →  Slider倍率输出
```

### 3.2 Chirp信号生成（固件侧）

**源码：`src/main/common/chirp.c` / `chirp.h`**

#### 数据结构

```c
typedef struct chirp_s {
    float f0, Ts, beta, k0, k1;  // 起始频率、采样周期、频率比指数、相位常数
    uint32_t count, N;            // 当前采样计数、总采样数
    float exc, fchirp, sinarg;    // 输出激励、瞬时频率、相位角
    bool isFinished;
} chirp_t;
```

#### 指数扫频算法

几何/指数扫频信号（Geometric Chirp），频率随时间指数增长：

```
瞬时频率:  f(t) = f0 × beta^(t)
           其中 beta = pow(f1/f0, 1/t1)

相位角:    sinarg = k0 × fchirp - k1
           其中 k0 = 2π / ln(beta), k1 = k0 × f0

输出:      cos(sinarg)  ← 余弦波，使角度绕0振荡

低频补偿:  fchirp < 1Hz 时输出 × fchirp（保持等角度幅度）
```

#### 频率范围与默认参数

源码：`src/main/flight/pid.c` → `resetPidProfile()`

| CLI 参数 | 默认值 | 说明 |
|----------|--------|------|
| `chirp_frequency_start_deci_hz` | 2 (0.2 Hz) | 扫频起始频率（单位: 0.1Hz） |
| `chirp_frequency_end_deci_hz` | 6000 (600 Hz) | 扫频终止频率 |
| `chirp_time_seconds` | 20 秒 | 每轴扫频时长 |
| `chirp_amplitude_roll` | 230 deg/s | Roll轴激励幅度 |
| `chirp_amplitude_pitch` | 230 deg/s | Pitch轴激励幅度 |
| `chirp_amplitude_yaw` | 180 deg/s | Yaw轴激励幅度 |
| `chirp_lag_freq_hz` | 3 Hz | 相位补偿滞后频率 |
| `chirp_lead_freq_hz` | 30 Hz | 相位补偿超前频率 |

扫频范围 **0.2Hz ~ 600Hz**，覆盖从刚体运动到电机噪声的完整频率范围。

#### 相位补偿滤波器（Lead-Lag Compensator）

源码：`src/main/common/filter.c`

二阶 IIR 滤波器，对 Chirp 信号整形以避免突发冲击：

```c
typedef struct phaseComp_s {
    float b0, b1, a1;    // 滤波器系数
    float x1, y1;        // 状态变量
} phaseComp_t;

// 滤波器方程: y[n] = b0*x[n] + b1*x[n-1] - a1*y[n-1]

// 设计参数:
omega = 2π × centerFreqHz × looptimeUs × 1e-6
gain  = (1 + sin(phaseDeg)) / (1 - sin(phaseDeg))
alpha = (12 - omega²) / (6 × omega × sqrt(gain))
```

#### 轴序扫描机制

源码：`pid.c` → `pidController()`

```
1. 用户通过 RC 开关激活 CHIRP_MODE
2. 开始在 Roll 轴注入 chirp（20秒，0.2Hz→600Hz）
3. 用户关闭开关 → chirpAxis 切换到 Pitch，重置 chirp
4. 用户再次打开开关 → Pitch 轴开始扫频
5. 重复上述过程 → Yaw 轴
6. 完成 Yaw 后，chirpAxis 循环回 Roll
```

注入方式：

```c
currentPidSetpoint += pidRuntime.chirpAmplitude[axis] * chirpFiltered;
```

🔑 注入到 setpoint（叠加），不是直接控制电机。飞行员始终有操控权。

#### Blackbox Debug 通道

| Slot | 值 | 用途 |
|------|-----|------|
| `debug[0]` | `sinarg × 5000` | 相位参考（离线信号重建） |
| `debug[1]` | chirp axis (0/1/2/-1) | 标识当前活动轴 |
| `debug[2]` | `fchirp × 10` | 瞬时频率 (deci-Hz) |
| `debug[3]` | `chirp × 1000` | 原始激励信号（相位补偿前） |

### 3.3 Configurator 频谱分析

**源码：Configurator PR #5000**

架构组件：

```
AutotuneTab.vue
  ├── AutotuneImport.vue       ← 导入 BBL 文件
  ├── BodePlot.vue             ← 频率响应图（幅频、相频、灵敏度、阶跃响应）
  ├── SpectrogramPlot.vue      ← 时频谱图
  └── GainRecommendation.vue   ← PID 增益推荐 + Apply 按钮

核心分析引擎:
  useAutotune.js               ← 编排层
  chirp_bbl_parser.js          ← BBL 解析器（1171行）
  spectral_analysis.js         ← Welch FFT + 增益推荐（659行）
  fft.js                       ← 复数 FFT（316行）
  decoders.js                  ← BBL 编码解码
  datastream.js                ← 二进制数据流
  chirp_analysis_worker.js     ← Web Worker（后台分析）
```

#### BBL 解析器

`chirp_bbl_parser.js`（1171行）：

1. 扫描 BBL 找到 log 边界（`H Product:Blackbox...` 标记）
2. 解析 S-frame 获取 sysConfig（looptime、PID参数、simplified tuning sliders）
3. 检测 `debug_mode = CHIRP`
4. 解析 I-frame 和 P-frame，提取 setpoint[axis]、gyro[axis]、debug[0-3]
5. 通过 flightModeFlags 检测 CHIRP_MODE 激活（bit 6 = BOXCHIRP_BIT）
6. 根据 `debug[1]`（axis字段）自动分段，每个轴一段数据

#### Welch 互谱传递函数估计

`welchTransferFunction()` — 整个算法的核心：

```
输入:
  input  = setpoint[axis]（含chirp激励）
  output = gyro[axis]（系统响应）

方法: Welch 平均周期图法
  - Hanning 窗
  - 50% 重叠分段
  - 段大小: min(满足 >= 0.5×sampleRate 的 2^N, 4096)

计算:
  Sxx(f) = |X(f)|²              ← 输入自谱
  Syy(f) = |Y(f)|²              ← 输出自谱
  Sxy(f) = conj(X) × Y          ← 互谱
  H(f)   = Sxy / Sxx            ← 闭环传递函数
  C(f)   = |Sxy|² / (Sxx × Syy) ← 相干函数（数据质量指标）

输出:
  频率数组、幅度(dB)、相位(°)、相干函数
```

### 3.4 增益推荐算法

`recommendGains()` — 从频域指标推算最优 Slider 倍率：

#### 提取的频域指标

| 指标 | 英文名 | 计算方式 | 含义 |
|------|--------|----------|------|
| **带宽** | `bandwidthHz` | 幅度穿越 -3dB 的频率 | 系统响应速度 |
| **谐振峰** | `resonantPeakDb` | 幅频曲线最大峰值 | 欠阻尼/振荡风险 |
| **增益穿越频率** | `gainCrossoverHz` | 幅度穿越 0dB 的频率 | 系统稳定性关键点 |
| **相位裕度** | `phaseMarginDeg` | 穿越频率处相位 + 180° | 系统稳定余量 |
| **低频误差** | `lowFreqErrorDb` | 2-10Hz 平均幅度偏差 | 低频跟踪能力 |
| **噪声底** | `noiseFloorHz` | 相干函数降至 0.5 的频率 | 高频噪声界限 |
| **平均相干性** | `meanCoherence` | 5-100Hz 平均相干 | 测量数据质量 |

#### 增益缩放逻辑

| 增益 | 计算方法 | 目标值 |
|------|----------|--------|
| **P (pi_gain)** | `piScale = 目标带宽 / 当前带宽` | 带宽 = **45Hz** |
| **D (d_gain)** | `dScale = 1 + (目标相位裕度 - 预测相位裕度) / 90` | 相位裕度 = **50°** |
| **I (i_gain)** | 误差 < -1dB: `iScale = 1 + |error| × 0.1`；误差 > 2dB: `iScale = 1 - error × 0.05` | 低频跟踪 |
| **FF (feedforward)** | `ffScale = piScale`（跟随P） | 与P同步 |
| **D-term filter** | `filterScale = 噪声底频率 / 150` | 噪声底 vs 默认150Hz |

#### P-D 耦合补偿

算法会先预测P调整后的新增益穿越频率，在新的穿越频率处计算预测相位裕度，然后基于预测值计算D的调整量。避免P和D的调整互相抵消。

#### 安全机制（分级回退）

```
谐振峰 > 6dB（严重振荡风险）:
  P  × 0.75
  D  × 0.85
  FF × 0.80

谐振峰 > 3dB（中等风险）:
  P  × 0.90
  D  × 0.95

所有缩放因子限幅: [0.5, 2.0]（单次最多2倍变化）
Slider输出值限幅: [25, 250]
```

### 3.5 辅助分析

#### 灵敏度函数

`computeSensitivity()`: `S(f) = 1 - T(f)`

灵敏度峰 > 6dB 表示调参脆弱，系统对参数变化敏感。

#### 阶跃响应

`computeStepResponse()`:

通过闭环传递函数的 IFFT 得到脉冲响应，累积求和得到阶跃响应。提取：
- 超调量 (overshoot %)
- 上升时间 (10% → 90%)
- 建立时间 (2% band)

#### 谱图

`computeSpectrogram()`:

短时 FFT 功率谱密度图，75% 重叠，256 窗口。

### 3.6 用户工作流程

```
1. Configurator 设置:
   - Autotune Tab 选择抖动强度 (Easy / Medium / Hard)
   - Modes Tab 分配 AUX 开关给 CHIRP_MODE
   - 确保 debug_mode = CHIRP
   - 开启 Blackbox 日志

2. 飞行采集:
   - 起飞悬停
   - 开CHIRP开关 → Roll扫频(20秒) → 关开关
   - 开CHIRP开关 → Pitch扫频(20秒) → 关开关
   - 开CHIRP开关 → Yaw扫频(20秒) → 关开关
   - 降落

3. Configurator 分析:
   - Autotune Tab 导入 BBL
   - 查看 Bode 图、谱图、推荐值
   - 连接飞控 → 点击 "Apply Gains"

4. 生效:
   - MSP_SET_SIMPLIFIED_TUNING → 写入Slider值
   - MSP_VALIDATE_SIMPLIFIED_TUNING → 固件验证
   - MSP_EEPROM_WRITE → 持久化
```

### 3.7 安全机制汇总

**固件侧：**
- Chirp 信号注入到 setpoint（叠加，不是直接控电机）
- 激励幅度有上限（Roll/Pitch: 230 deg/s, Yaw: 180 deg/s）
- Lead-lag 补偿器整形信号避免突发冲击
- 低频段（<1Hz）自动降低幅度
- 飞行员可随时关开关停止注入

**Configurator侧：**
- 增益推荐单次最多 2x 变化
- 谐振峰检测自动回退增益
- Slider 输出值限幅 [25, 250]
- 固件 MSP 验证
- 需连接飞控才能 Apply

---

## 四、INAV Autotune 对比（简要）

| 维度 | BF Slider | BF Chirp AutoTune | INAV Autotune |
|------|-----------|-------------------|---------------|
| **方法** | 预设 × 手动乘数 | Welch FFT 传递函数 | 时域统计 + EMA 收敛 |
| **数据源** | 无（纯手动） | Chirp扫频 BBL | 飞行中实时采样 |
| **调参维度** | P/I/D/FF/DMax + 滤波 | P/I/D/FF + 滤波 | **仅FF** |
| **在线/离线** | N/A | 离线分析BBL | 在线实时 |
| **输出格式** | Slider倍率(0-200) | Slider倍率(0-200) | 直接FF值(10-255) |
| **安全机制** | constrain + UI限制 | 谐振峰回退 + 2x限幅 | EMA 10% + constrain |
| **复杂度** | 低（乘法） | 高（FFT + 传递函数） | 低（移动平均） |
| **依赖模型** | 否 | 是（传递函数） | 否 |
| **适用机型** | 多旋翼 | 多旋翼 | 固定翼为主 |
| **收敛保证** | 无（开环） | 有（闭环频域） | 有（EMA渐进） |

---

## 五、对 PID_Liner 的核心启示

### 5.1 必须考虑 Slider 兼容性

BF 的整个生态（Chirp AutoTune、Configurator）都围绕 Slider 倍率体系构建。PID_Liner 的CLI输出应该：

- **方案A**：输出 Slider CLI 命令（`set simplified_d_gain = 110`）
- **方案B**：输出直接值前先关闭 Slider（`set simplified_pids_mode = OFF`），再输出 `set d_roll = 33`
- **现状**：直接输出 `set d_roll = 33`，如果用户 Slider 开着会导致冲突

### 5.2 频域分析是 BF 核心能力

BF Chirp 用 Welch FFT 分析传递函数，从频域提取带宽、相位裕度、谐振峰。PID_Liner 的时域分析（超调量、上升时间）是另一个维度，两者互补。

### 5.3 谐振峰检测应加入安全机制

BF 在谐振峰 > 6dB 时自动回退增益（P×0.75, D×0.85, FF×0.80）。PID_Liner 应加入类似安全检查。

### 5.4 INAV 的极简方案证明"安全 > 精确"

INAV 只调 FF，收敛率 10%，用最简单统计算法。说明飞控领域宁可保守也不要炸机。

### 5.5 PID Sum 检查不可忽略

BF 运行时限制 PID 总和（Roll/Pitch ≤ 500, Yaw ≤ 400）。即使单项不超限，总和超限也会被飞控钳位，推荐效果与预期不一致。

### 5.6 BF 的 PID 硬限制

```
P/I/D 单项: 0 ~ 250  (PID_GAIN_MAX, uint8_t)
FF:         0 ~ 1000 (F_GAIN_MAX, uint16_t)
PID Sum:    100 ~ 1000（默认 RP=500, Yaw=400）
Slider:     0 ~ 200 (0% ~ 200%)
```

PID_Liner 的 `kPIDMaxValue = 200` 不够准确，应为 P/I/D 最大 250、FF 最大 1000。

---

## 六、源码参考

| 文件 | 仓库 | 说明 |
|------|------|------|
| `src/main/common/chirp.c` | betaflight/betaflight | Chirp 信号生成 |
| `src/main/common/chirp.h` | betaflight/betaflight | Chirp 数据结构 |
| `src/main/common/filter.c` | betaflight/betaflight | Lead-lag 补偿器 |
| `src/main/flight/pid.c` | betaflight/betaflight | PID控制器 + Chirp注入 |
| `src/main/flight/pid.h` | betaflight/betaflight | PID默认值、常量 |
| `src/main/config/simplified_tuning.c` | betaflight/betaflight | Slider计算核心 |
| `src/main/config/simplified_tuning.h` | betaflight/betaflight | Slider常量定义 |
| `src/main/cli/settings.c` | betaflight/betaflight | CLI参数范围定义 |
| `src/main/msp/msp.c` | betaflight/betaflight | MSP协议处理 |
| `useTuningSliders.js` | betaflight/betaflight-configurator | Configurator Slider UI |
| `spectral_analysis.js` | betaflight/betaflight-configurator | Welch FFT + 增益推荐 |
| `chirp_bbl_parser.js` | betaflight/betaflight-configurator | BBL Chirp数据解析 |
| `fft.js` | betaflight/betaflight-configurator | 复数 FFT 实现 |
| `useAutotune.js` | betaflight/betaflight-configurator | Autotune编排层 |

---

## 七、相关链接

- BF 主仓库：https://github.com/betaflight/betaflight
- BF Configurator：https://github.com/betaflight/betaflight-configurator
- BF 固件 Chirp PR：https://github.com/betaflight/betaflight/pull/15113
- BF Configurator Autotune PR：https://github.com/betaflight/betaflight-configurator/pull/5000
- BF 2025.12 Release Notes：https://betaflight.com/docs/wiki/release/Betaflight-2025-12-Release-Notes
- BF PID Tuning 文档：https://betaflight.com/docs/wiki/app/pid-tuning-tab
- BF 4.3 Tuning Notes：https://betaflight.com/docs/wiki/tuning/4-3-Tuning-Notes
- Oscar Liang BF 4.6 新特性：https://oscarliang.com/betaflight-4-6/
- INAV Autotune 源码：https://github.com/iNavFlight/inav/blob/master/src/main/flight/pid_autotune.c
- INAV Autotune 文档：https://github.com/iNavFlight/inav/blob/master/docs/Autotune%20-%20fixedwing.md
