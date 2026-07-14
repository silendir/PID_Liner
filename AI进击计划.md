# PID_Liner AI Agent 产品方案

## 现状分析

当前项目已有模块：

| 模块 | 状态 | 关键文件 |
|------|------|---------|
| BBL 解码 | ✅ | `BlackboxDecoder` + C桥接层 |
| CSV 解析 | ✅ | `PIDCSVParser` |
| 信号处理 | ✅ | FFT、维纳反卷积、高斯滤波 |
| PID 分析 | ✅ | 阶跃响应、噪声频谱、响应热图 |
| 可视化 | ✅ | `PIDResponseChartView`、热图、噪声图 |

**缺失环节**：诊断 → 推荐 → 写回飞控，这三步没有打通。

---

## 🔑 关键洞察：BBL 只有"行为"，没有"身体"

BBL 文件记录的是 PID 控制器的抽象行为数据（陀螺仪、P/I/D 项、遥控指令），但**完全不包含机体的物理特性**：

| BBL 里有的 | BBL 里没有的 |
|-----------|-------------|
| 陀螺仪角速度 | 机架尺寸 / 重量 / 材质 |
| PID 各项输出 | 电机 KV / 螺旋桨尺寸 |
| 遥控指令 | 推重比 / 转动惯量 |
| 油门值 | 电池电压/容量 |

### 核心认知：PID 调参本质上是信号特征分类问题，不是物理建模问题

1. 一个"调好的"5寸机和一个"调好的"7寸机的阶跃响应曲线看起来很相似：快速上升、低超调、快速稳定
2. 一个"没调好的"5寸机的信号特征（震荡、噪声、prop wash）跟一个"没调好的"7寸机也很相似
3. PID 调参的目标是让信号特征趋向"理想状态"——**跟机体尺寸无关**

所以诊断引擎只需要看：
- 阶跃响应超不超调？
- D频段有没有噪声尖峰？
- 低输入时稳不稳定？

**物理参数的作用是"辅助校准推荐幅度"，而不是"能不能推荐的前提条件"。**

---

## 物理参数获取：三层策略

```
┌──────────────────────────────────────────────────┐
│           物理参数获取（三层策略）                   │
│                                                   │
│  第1层：从 BBL Header 自动提取（零用户成本）        │
│  ┌─────────────────────────────────┐              │
│  │ ✅ Product (飞控型号)             │              │
│  │ ✅ Firmware revision             │              │
│  │ ✅ Craft name                    │              │
│  │ ✅ looptime / sample rate        │              │
│  │ ✅ PID 当前值（从header提取）      │              │
│  │ ✅ 滤波器配置                     │              │
│  └─────────────────────────────────┘              │
│            │                                      │
│            ▼                                      │
│  第2层：从 BBL 数据反推（无需用户输入）             │
│  ┌─────────────────────────────────┐              │
│  │ 🔬 推重比估算（悬停油门法）       │              │
│  │ 🔬 等效转动惯量估算（阶跃响应法） │              │
│  │ 🔬 机架共振指纹（FFT频谱法）     │              │
│  └─────────────────────────────────┘              │
│            │                                      │
│            ▼                                      │
│  第3层：用户交互输入（可选，提升精度）              │
│  ┌─────────────────────────────────┐              │
│  │ 📋 机型预设选择                  │              │
│  │ 📋 具体参数（高级用户可选填）     │              │
│  └─────────────────────────────────┘              │
└──────────────────────────────────────────────────┘
```

### 第1层：BBL Header 自动提取

🔑 **关键发现**：Betaflight 从 4.3+ 开始，`dump` 输出中的 `set motor_kv` 等参数会被写入 BBL header。只需要扩展 `parseHeaderLine:` 方法就能自动获取。

#### 当前解析状态

`BlackboxDecoder.m` 的 `parseHeaderLine:` 方法（第848-876行）已解析：
- ✅ `Product`、`Firmware revision`、`Firmware date`、`Craft name`
- ✅ `Log start datetime`、`P interval`、`P ratio`
- ❌ **所有 `set` 开头的配置行被完全忽略**（PID/滤波器/TPA/前馈等关键参数）

> 🚨 **现状问题**：`BBLLogHeader` 有 `configParameters` 属性但从未被填充。BBL Header 中的 `H set rollPID = 42,42,42` 等行被跳过，导致无法获取当前 PID 基线值。
> 这意味着 **无法安全生成 CLI 推荐** — 不知道当前值就无法计算推荐值。

#### 🔑 BBL Header 全量字段（Betaflight 源码验证）

以下内容来自 Betaflight 官方源码 `src/main/blackbox/blackbox.c` 的 `blackboxWriteSysinfo()` 函数验证。

> 📌 **源码地址**: `https://github.com/betaflight/betaflight` → `src/main/blackbox/blackbox.c`
> 📌 **写入函数**: `blackboxWriteSysinfo()` — 使用 `BLACKBOX_PRINT_HEADER_LINE` 宏将所有配置写入 header
> 📌 **Header 格式**: `H key:value\n` — 标准文本行，键值对格式

| 分类 | Header Key | 说明 | 诊断用途 |
|------|-----------|------|---------|
| **电机** | `motor_kv` | 电机KV值 | 推力/转速估算 |
| | `motor_poles` ⚡ | 电机磁极数（DShot遥测启用时写入） | RPM计算 |
| | `motor_idle` | 电机空转值 | 悬停特性判断 |
| | `motor_output_limit` | 电机输出限幅 | 推力上限 |
| **PID** | `rollPID` / `pitchPID` / `yawPID` | 三轴PID值（如 `42,42,42`） | 当前PID基线 |
| | `levelPID` | 自稳模式PID | 自稳飞行诊断 |
| | `ff_weight` | 前馈权重 | 前馈调参依据 |
| | `d_max` / `d_max_gain` / `d_max_advance` | D项动态增强 | D项优化 |
| **TPA** | `tpa_rate` | 油门PID衰减率 | 油门相关性诊断 |
| | `tpa_breakpoint` | TPA起始油门 | 油门相关性诊断 |
| | `tpa_low_rate` | 低油门TPA衰减 | 低油门响应 |
| | `tpa_low_breakpoint` | 低油门TPA断点 | 低油门响应 |
| | `tpa_low_always` | 低油门TPA常开 | 配置标志 |
| | `tpa_mode` | TPA模式 | 配置标志 |
| **D项滤波** | `dterm_lpf1_type` / `dterm_lpf1_hz` | D项低通滤波器1 | 噪声诊断关键 |
| | `dterm_lpf2_type` / `dterm_lpf2_hz` | D项低通滤波器2 | 噪声诊断关键 |
| **陀螺仪滤波** | `gyro_lpf1_type` / `gyro_lpf1_hz` | 陀螺仪低通1 | 滤波器配置基线 |
| | `gyro_lpf2_type` / `gyro_lpf2_hz` | 陀螺仪低通2 | 滤波器配置基线 |
| **动态陷波** | `dyn_notch_count` | 动态陷波数量 | 共振滤波 |
| | `dyn_notch_min_hz` / `dyn_notch_max_hz` | 陷波频率范围 | 共振滤波 |
| | `dyn_notch_q` | 陷波Q值 | 滤波精度 |
| **RPM滤波** | `rpm_filter_harmonics` | RPM谐波数 | RPM滤波状态 |
| | `rpm_filter_q` | RPM滤波Q值 | 滤波精度 |
| | `rpm_filter_min_hz` | RPM最低频率 | 滤波范围 |
| **电压** | `vbat_scale` | 电压缩放系数 | 电池电压估算 |
| | `vbatref` | 参考电压 | 电池状态 |
| | `vbatcellvoltage` | 单体电压范围 | 电池类型推断 |
| **简化调参** | `simplified_pids_mode` | 简化PID模式 | Betaflight 4.4+ 特有 |
| | `simplified_master_multiplier` | 主乘数 | 简化调参参数 |
| **前馈** | `feedforward_transition` | 前馈过渡 | 前馈精细调参 |
| | `feedforward_boost` | 前馈增强 | 前馈精细调参 |
| | `feedforward_max_rate` | 前馈最大速率 | 前馈精细调参 |

> ⚠️ **不存在的字段**: `prop_size`（螺旋桨尺寸）— Betaflight 不存储此信息，需通过用户输入（第3层）获取。
> ⚡ `motor_poles` 仅在 DShot 遥测启用时写入，部分旧固件可能不含此字段。

**实现方式**：将 `parseHeaderLine:` 从硬编码 if-else 改为通用 key:value 字典解析，所有字段存入 `BBLLogHeader.configParameters`，同时保持现有类型化属性的向后兼容。

#### ⚠️ 固件版本安全分级（CLI 输出准入门槛）

🔑 **核心原则：没有当前参数基线，任何推荐都是盲目的。拒绝输出比错误输出安全一万倍。**

> 📌 **数据来源**：
> - BBL Header 字段清单：[Betaflight 源码 blackbox.c](https://github.com/betaflight/betaflight/blob/master/src/main/blackbox/blackbox.c) — `blackboxWriteSysinfo()` 函数
> - 各版本参数支持范围：[settings.c 源码](https://github.com/betaflight/betaflight/blob/master/src/main/cli/settings.c) — 按版本追踪变量增删
> - BF 4.5 CLI 变量：[Betaflight 4.5 CLI Command Line Reference](https://betaflight.com/docs/wiki/guides/current/Betaflight-4.5-CLI-commands)
> - BF 2025.12 CLI 变量：[Betaflight 2025.12 CLI Command Line Reference](https://betaflight.com/docs/wiki/guides/current/Betaflight-2025.12-CLI-commands)
> - 版本变更日志：[Betaflight Release Notes](https://betaflight.com/docs/wiki/release/)
> - 当前 `parseHeaderLine:` 实现：`BlackboxDecoder.m` 第848-876行

```
┌─────────────────────────────────────────────────────────────────────┐
│              BBL Header 参数完整度 vs 固件版本                       │
│                                                                     │
│  BF 3.x      BF 4.0~4.2    BF 4.3~4.4     BF 4.5+    BF 2025.12  │
│  ──────────  ────────────  ────────────   ─────────  ─────────── │
│  基础PID ✅   基础PID ✅     基础PID ✅      基础PID ✅  基础PID ✅   │
│  无滤波参数   部分滤波       完整滤波 ✅     完整滤波 ✅  完整滤波 ✅ │
│  无前馈       前馈基础       前馈完整 ✅     前馈完整 ✅  S-term ✅   │
│  无D_max      无D_max       D_max ✅        D_max ✅    SPA ✅      │
│  无TPA详情    基础TPA        TPA完整 ✅      TPA完整 ✅  TPA曲线 ✅  │
│  无RPM滤波    RPM基础        RPM完整 ✅      RPM完整 ✅  RPM完整 ✅  │
│                                                                     │
│  🔴 拒绝      🔴 拒绝         🟡 受限        🟢 完整    🟢 完整+   │
│  无法安全调参  参数不足        基础CLI可用    完整CLI     新特性     │
└─────────────────────────────────────────────────────────────────────┘
```

| 安全等级 | 固件版本 | CLI 输出权限 | 原因 |
|---------|---------|------------|------|
| 🔴 **拒绝** | BF 3.x 及更早 | **禁止输出任何 CLI 命令** | 缺少滤波器/D_max/前馈参数，盲目调整会炸机 |
| 🔴 **拒绝** | BF 4.0~4.2 | **禁止输出任何 CLI 命令** | 滤波器参数不完整，D项推荐可能错误 |
| 🟡 **受限** | BF 4.3~4.4 | 允许基础 CLI（PID + 滤波器） | 缺少 D_max 精细参数，无法推荐动态增强，需警告用户 |
| 🟢 **完整** | BF 4.5~4.6 | 允许完整 CLI 输出 | 全参数可用，但注意 D项命名反转（`d_roll` = D_max） |
| 🟢 **完整+** | BF 2025.12+ | 完整 CLI + 新特性 | S-term、SPA、TPA曲线等（`d_roll` = 基础值） |

#### 拒绝旧版本的安全理由（具体案例）

**BF 3.x 场景**：
```
Header 里没有 dterm_lpf1_hz
→ 不知道当前 D 项滤波器截止频率
→ 如果推荐 "set dterm_lpf1_hz = 100"
→ 但用户实际可能已经是 50Hz
→ 降到 100 反而是增大噪声 → D项炸机 💥
```

**BF 4.0 场景**：
```
Header 里没有 D_max 参数
→ 推荐调整 D 但不知道 D_max 是多少
→ 可能导致 D 项突然变激进 → 高频震荡 💥
```

**BF 4.5 vs 2025.12 场景**：
```
同一组值 d_roll=40, d_min_roll=30：
  BF 4.5:     d_roll=40 是 D_max, d_min_roll=30 是基础值
  BF 2025.12: d_roll=30 是基础值, d_max_roll=40 是 D_max
→ 如果版本判断错误，CLI 命令写反 → D项值反转 → 飞行危险 💥
```

#### 版本检测实现逻辑

> 📌 **来源依据**：
> - `firmwareRevision` 字段格式：BBL Header 中 `H Firmware revision:Betaflight X.Y.Z` 标准格式
> - 版本号解析规则：Betaflight 从 3.x 起使用 `主版本.次版本.补丁` 格式，2025 起增加年份版本号（如 `2025.12`）
> - CLI 变量版本差异：参见 Phase 3 的"D项命名反转"章节，来源为 `settings.c` 源码对比

```objc
/// 从 BBL Header 的 firmwareRevision 解析主版本号
/// 格式示例: "Betaflight 4.5.0" / "Betaflight 2025.12"
- (NSInteger)parseBetaflightMajorVersion:(NSString *)firmwareRevision {
    // 匹配 "Betaflight X.Y.Z" 格式
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"Betaflight\\s+(\\d+)\\.(\\d+)"
        options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:firmwareRevision
                                                   options:0
                                                     range:NSMakeRange(0, firmwareRevision.length)];
    if (match) {
        NSInteger major = [[firmwareRevision substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger minor = [[firmwareRevision substringWithRange:[match rangeAtIndex:2]] integerValue];
        return major * 100 + minor; // e.g. 4.5 → 405
    }
    return 0; // 未知版本，按拒绝处理
}

/// CLI 输出安全等级
typedef NS_ENUM(NSInteger, CLISafetyLevel) {
    CLISafetyLevelRejected = 0,   // 🔴 禁止输出
    CLISafetyLevelRestricted = 1, // 🟡 基础 CLI
    CLISafetyLevelFull = 2,       // 🟢 完整 CLI
};

- (CLISafetyLevel)cliSafetyLevelForVersion:(NSInteger)versionCode {
    if (versionCode < 403) return CLISafetyLevelRejected;   // BF < 4.3
    if (versionCode < 405) return CLISafetyLevelRestricted;  // BF 4.3~4.4
    return CLISafetyLevelFull;                                // BF 4.5+
}

/// 关键参数完整性检查（即使版本够高，也要验证 Header 实际包含必要字段）
- (BOOL)validateRequiredParameters:(NSDictionary *)configParameters {
    // 必须有当前 PID 值（否则不知道基线）
    BOOL hasPID = configParameters[@"rollPID"] &&
                  configParameters[@"pitchPID"] &&
                  configParameters[@"yawPID"];
    // 必须有 D 项滤波器配置（否则无法安全推荐 D 调整）
    BOOL hasDtermFilter = configParameters[@"dterm_lpf1_hz"] &&
                          configParameters[@"dterm_lpf2_hz"];
    return hasPID && hasDtermFilter;
}
```

> 📌 **双重校验**：即使固件版本 >= 4.3，也必须验证 Header 中实际存在必要参数。部分用户可能使用自定义固件或特殊配置导致参数缺失。版本号是第一道门槛，参数完整性检查是第二道。

### 第2层：从飞行数据反推物理参数（纯数学推导，无需用户输入）

#### 2a. 推重比估算

```
原理：
- 悬停油门 ≈ 50% 时，推力 = 重力（悬停平衡）
- motor[i] 输出值 × 电机效率系数 = 推力
- 悬停油门越低 → 推重比越高 → 可承受更激进的PID

实现：
1. 统计油门分布直方图，找到悬停稳态区间（油门变化最小的区间）
2. 该区间的平均油门 → 估算推重比
3. 推重比 > 8:1 → 可以激进调参
   推重比 < 4:1 → 需要保守PID
```

#### 2b. 等效转动惯量估算

```
原理：
- 阶跃响应中，角加速度 = 力矩 / 转动惯量 (τ = I × α)
- 力矩 = motor输出 × 力臂（轴距相关）
- 从 PIDTraceAnalyzer 已有阶跃响应数据

实现：
1. 从阶跃响应提取最大角加速度 α_max
2. 从 motor 输出 × 悬停推力 → 力矩估算
3. I_effort = torque / α_max
4. I_effort 大 → 大机架/重负载 → 需要更低的P、更高的I
   I_effort 小 → 轻量牙签机 → 可以高P
```

#### 2c. 机架共振指纹

```
原理：
- PIDFFTProcessor 已经在算噪声频谱
- 不同机架的共振频率是"指纹"
- 3寸机 ~200-400Hz, 5寸机 ~100-250Hz, 7寸+ ~50-150Hz

实现：
1. FFT 噪声频谱中的窄带尖峰 → 机架共振频率
2. 共振频率区间 → 反推大致机架尺寸类别
3. 无需用户输入，自动分类
```

### 第3层：用户交互（可选，引导式设计）

不需要让用户填一堆数字，用 **机型预设 + 引导式问卷**：

```
┌─────────────────────────────────┐
│  🚁 你的飞机是什么类型？          │
│                                 │
│  ┌──────┐ ┌──────┐ ┌──────┐   │
│  │ 3寸  │ │ 5寸  │ │ 7寸  │   │
│  │ 牙签机│ │ 穿越机│ │ 长航时│   │
│  └──────┘ └──────┘ └──────┘   │
│                                 │
│  ┌──────┐ ┌──────┐ ┌──────┐   │
│  │ 2寸  │ │10寸+ │ │ 固定翼│   │
│  │ Tiny  │ │ 载机  │ │     │   │
│  └──────┘ └──────┘ └──────┘   │
│                                 │
│  ─── 高级设置（可选）───        │
│  起飞重量:  [___] g             │
│  电机KV:    [___]               │
│  螺旋桨:    [___] 寸            │
│  电池:      [2S][3S][4S][6S]   │
│                                 │
│  [跳过此步] [下一步]             │
└─────────────────────────────────┘
```

用户可以完全跳过第3层，诊断和推荐仍然正常工作。物理参数只是让推荐幅度更精准。

### 飞控行业参考

| 飞控 | 方案 | 局限 |
|------|------|------|
| **Betaflight** | CLI 有 `motor_kv`、`motor_poles`，但不用于PID自动调参 | 仅供RPM滤波 |
| **ArduPilot** | [AutoTune](https://ardupilot.org/copter/docs/autotune.html) 飞行中激发各轴，实时测量响应 | 不需要物理参数，但需特殊飞行模式 |
| **PX4** | 类似 AutoTune，基于系统辨识 | 同上 |
| **FPVtune** | 神经网络分析 BBL，用户输入机型信息 | 需要**用户手动填写**机型数据 |

---

## 产品架构：预测曲线 + 迭代收敛闭环

```
┌──────────────────────────────────────────────────────────────┐
│                     PID_Liner AI Agent                        │
│                                                               │
│  Phase 1           Phase 2           Phase 3                 │
│  ┌──────────┐    ┌──────────────┐  ┌───────────────────┐    │
│  │ 自动诊断  │───▶│预测曲线+AI推荐│──▶│CLI输出+二阶对比   │    │
│  └──────────┘    └──────────────┘  └───────────────────┘    │
│       │                │                     │               │
│       ▼                ▼                     ▼               │
│  问题报告         预测阶跃响应          复制CLI到            │
│  评分评定         PID参数建议          Configurator          │
│                   置信度打分            ↓                    │
│                                       二次飞行录BBL          │
│                                       预测vs实际对比         │
│                                       偏差→校正系数          │
│                                       精准二次推荐           │
│                                                               │
│  ════════════ 预测-验证-收敛 闭环 ════════════               │
│                                                               │
│  飞行① → 分析 → 预测曲线+CLI → 粘贴 → 飞行②               │
│    ↑                                         ↓               │
│    │    预测vs实际偏差 → 校正系数 → 更精准推荐 ←┘             │
│    └─── 收敛后迭代停止（匹配度 > 90%）                        │
└──────────────────────────────────────────────────────────────┘
```

### 核心差异化：预测曲线（行业首创）

> 🔑 **PIDtoolbox 和 FPVtune 都没有做这个**。它们只推荐参数，不预测结果。
> PID_Liner 的核心创新是：**在用户贴 CLI 之前，就画出调完后的预估曲线。**
> 用户可以直观看到"调完后响应大概长什么样"，然后再决定是否采纳。

**预测曲线的价值链**：
```
预测曲线 ─→ 用户看到预期效果 ─→ 信心更足，更愿意付费
    ↓
二次飞行 ─→ 预测vs实际对比 ─→ 暴露未建模的物理因素（机架共振/电机滞后/桨弹性）
    ↓
偏差分析 ─→ 校正系数 ─→ 每轮迭代预测更准 ─→ 最终收敛到最优调参
```

---

## Phase 1：自动诊断引擎（本地信号分析 + 专家规则 + 预测曲线）

> 最核心、最可行的一步——不需要任何云端AI，纯本地计算。
> 🔑 **新增**：生成预测阶跃响应曲线，在用户贴 CLI 前就能看到调完后的预估效果。

### 诊断规则

基于已有的 FFT + 维纳反卷积 + 阶跃响应分析结果，建立 **专家规则诊断系统**：

| 诊断项 | 信号来源 | 判断逻辑 | 输出 |
|--------|---------|---------|------|
| 🔴 **P项过高（震荡）** | 阶跃响应 | 超调量 > 阈值 或 建立时间后有持续振荡 | `P项过高，建议降低 X%` |
| 🟡 **D项噪声注入** | 噪声频谱 | D频段存在明显尖峰（> gyro噪声基底） | `D项噪声过大，建议降D或增加滤波` |
| 🟠 **Prop Wash** | 低输入响应 | 低输入时响应曲线抖动/不稳定 | `存在Prop Wash，建议增加I或FF` |
| 🟢 **响应迟缓** | 阶跃响应 | 上升时间过长 / 响应幅度不足 | `P项不足，建议提高` |
| 🔵 **机械共振** | FFT噪声频谱 | 特定频率出现窄带尖峰 | `检测到电机共振，建议动态陷波滤波` |
| 🟣 **油门相关性** | 响应热图 | 响应随油门变化不均匀 | `TPA需要调整` |

### 预测曲线引擎（核心创新 🔑）

> 📌 **行业首创**：PIDtoolbox 和 FPVtune 只推荐参数值，不预测结果曲线。
> PID_Liner 在推荐 CLI 的同时，**绘制推荐参数对应的预估阶跃响应曲线**。

#### 预测曲线数学原理

```
已知（从 Phase 1 分析获得）：
  · 当前 PID 值: P_old, I_old, D_old, FF_old
  · 实测阶跃响应: h(t) — 从 stackResponse + weightedModeAverage 得到
  · 超调量 overshoot_old, 建立时间 settling_old, 上升时间 rise_old

推荐参数（从规则/AI 获得）：
  · 新 PID 值: P_new, I_new, D_new, FF_new

预测方法（三步）：

第1步：从实测响应拟合二阶传递函数
  H(s) = K·ωn² / (s² + 2ζωn·s + ωn²)

  其中:
  · ωn (自然频率) ← 从上升时间计算: ωn ≈ 1.8 / rise_time
  · ζ  (阻尼比)   ← 从超调量计算:   ζ ≈ -ln(overshoot) / √(π² + ln²(overshoot))
  · K  (增益)      ← 从稳态值获取

第2步：根据 PID 变化比例修正传递函数参数
  · P 变化 → 修正增益 K:     K_new = K_old × (P_new / P_old)
  · D 变化 → 修正阻尼比 ζ:   ζ_new = ζ_old × (D_new / D_old)^0.5
  · I 变化 → 修正低频特性:   超调修正系数 = 1 + 0.1 × (I_new/I_old - 1)
  · FF变化 → 修正建立时间:   rise_new = rise_old × (FF_old / FF_new)^0.3

第3步：用修正后的传递函数生成预测响应曲线
  h_predicted(t) = L⁻¹{ H_new(s) / s }   （阶跃响应 = 传递函数 × 1/s 的拉普拉斯逆变换）

简化实现（无需真正做拉普拉斯变换）：
  直接用修正后的参数生成标准二阶阶跃响应公式：
  h(t) = K_new · [1 - e^(-ζ_new·ωn·t) · sin(ωd·t + φ) / √(1-ζ²)]
  其中 ωd = ωn·√(1-ζ²), φ = arccos(ζ)
```

#### 预测曲线展示

在响应图 Tab 中，**当前实测曲线 + 预测曲线重叠显示**：

```
┌─ Roll 阶跃响应 ──────────────────────────────────┐
│                                                   │
│  2.0 ┤                                           │
│      │       ╭─╮                                  │
│  1.5 ┤      ╱   ╲      ← 当前实测（蓝色实线）    │
│      │     ╱     ╲                                │
│  1.0 ┤    ╱  ·  · ╲___                           │
│      │   ╱ ·        · ·╲__                       │
│  0.5 ┤  ·               · ╲   ← 预测曲线         │
│      │ ·  (虚线)            ╲   （绿色虚线）      │
│  0.0 ┤·                        ╲___              │
│      ├──┬──┬──┬──┬──┬──┬──┬──┤                  │
│      0  50 100 150 200 250 300 350 400 (ms)      │
│                                                   │
│  ── 当前 P=46 I=42 D=30    超调23% 建立180ms     │
│  - - 预测 P=32 I=42 D=30    超调9%  建立95ms     │
└───────────────────────────────────────────────────┘
```

#### ObjC 接口设计

```objc
/// 预测曲线引擎 — 根据推荐参数生成预估阶跃响应
@interface PIDPredictiveEngine : NSObject

/// 从实测响应提取二阶系统参数
/// @param stepResponse 实测阶跃响应数据
/// @param sampleRate 采样率
- (PIDSystemModel *)fitSystemModelFromResponse:(NSArray<NSNumber *> *)stepResponse
                                   sampleRate:(double)sampleRate;

/// 根据参数变化预测新响应曲线
/// @param model 拟合的系统模型
/// @param oldPID 当前PID值
/// @param newPID 推荐PID值
/// @param pointCount 输出点数
- (NSArray<NSNumber *> *)predictResponseWithModel:(PIDSystemModel *)model
                                          oldPID:(PIDValues *)oldPID
                                          newPID:(PIDValues *)newPID
                                      pointCount:(NSInteger)pointCount;

/// 计算预测与实际的匹配度（二阶对比用）
/// @param predicted 预测响应
/// @param actual 实际响应
/// @return 匹配度 0~1, 偏差分析字典
- (PIDMatchResult *)calculateMatchBetweenPredicted:(NSArray<NSNumber *> *)predicted
                                           actual:(NSArray<NSNumber *> *)actual;
@end

/// 二阶系统模型（从实测响应拟合）
@interface PIDSystemModel : NSObject
@property (nonatomic, assign) double naturalFrequency;  // ωn 自然频率
@property (nonatomic, assign) double dampingRatio;      // ζ  阻尼比
@property (nonatomic, assign) double gain;              // K  增益
@property (nonatomic, assign) double riseTime;          // 上升时间 (ms)
@property (nonatomic, assign) double overshoot;         // 超调量 (0~1)
@property (nonatomic, assign) double settlingTime;      // 建立时间 (ms)
@end

/// 预测-实际匹配结果
@interface PIDMatchResult : NSObject
@property (nonatomic, assign) double matchScore;        // 匹配度 0~1
@property (nonatomic, assign) double overshootError;    // 超调偏差
@property (nonatomic, assign) double riseTimeError;     // 建立时间偏差
@property (nonatomic, assign) double settlingTimeError; // 建立时间偏差
@property (nonatomic, strong) NSArray<NSNumber *> *correctionFactors; // 校正系数
@end
```
// 核心诊断模型
@interface PIDDiagnosisEngine : NSObject

/// 输入：已有的分析结果
@property (nonatomic, strong) PIDAxisAnalysisResult *analysisResult;
@property (nonatomic, strong) PIDCSVData *csvData;

/// 执行诊断
- (NSArray<PIDDiagnosis *> *)diagnose;

@end

// 单条诊断结果
@interface PIDDiagnosis : NSObject
@property (nonatomic, assign) PIDIssueType issueType;    // 问题类型
@property (nonatomic, assign) PIDSeverity severity;       // 🔴严重 🟡中等 🟢轻微
@property (nonatomic, assign) NSInteger axis;             // 0=Roll 1=Pitch 2=Yaw
@property (nonatomic, copy) NSString *description;        // 中文描述
@property (nonatomic, strong) NSArray<NSNumber *> *evidenceData; // 证据数据（频谱/响应截图）
@property (nonatomic, assign) double confidence;          // 置信度 0~1
@end
```

---

## Phase 2：云端 AI 推荐引擎

> 🔑 **核心策略**：本地信号分析（Phase 1）提取特征 → 发送至云端 AI → 返回诊断 + 推荐参数 + CLI 命令
>
> **AI 模型**：智谱 GLM-4.7-Flash（完全免费、无限调用、中文优秀、200K 上下文）

### 为什么选 GLM-4.7-Flash

| 对比项 | GLM-4.7-Flash | 火山引擎豆包 | DeepSeek API | Claude API |
|--------|--------------|-------------|-------------|-----------|
| **费用** | **完全免费** | 每日200万Token免费 | 极低价（~¥0.001/次） | ~$0.25/百万Token |
| **调用限制** | **无限制** | 每日刷新 | 按量计费 | 按量计费 |
| **上下文** | 200K tokens | 32K | 128K | 200K |
| **中文能力** | 优秀 | 良好 | 优秀 | 优秀 |
| **API 格式** | OpenAI 兼容 | 私有SDK | OpenAI 兼容 | 私有SDK |
| **国内访问** | ✅ 直连 | ✅ 直连 | ✅ 直连 | ❌ 需翻墙 |
| **iOS 接入** | NSURLSession 直连 | 需SDK | NSURLSession 直连 | 需SDK |

**结论**：GLM-4.7-Flash 零成本 + 无限制 + 无需 SDK + 国内直连 = 完美适配。

### 商业模型

```
┌────────────────────────────────────────────────┐
│              收费策略                            │
│                                                 │
│  免费层（本地 Phase 1）         付费层（云端 AI）  │
│  ┌──────────────────┐        ┌────────────────┐ │
│  │ ✅ 信号分析        │        │ 🤖 AI 深度诊断  │ │
│  │ ✅ 问题检测        │   ¥15  │ 🤖 个性化推荐   │ │
│  │ ✅ 基础评分        │  ───▶  │ 🤖 CLI 命令生成  │ │
│  │ ✅ 简单推荐        │  /月   │ 🤖 迭代追踪     │ │
│  │                  │        │ 🤖 版本适配      │ │
│  └──────────────────┘        └────────────────┘ │
│                                                 │
│  API 成本 = ¥0（GLM-4.7-Flash 免费无限）          │
│  用户付费 = 纯利润 💰                             │
└────────────────────────────────────────────────┘
```

### API 接入架构

```
┌─────────────┐     HTTPS POST      ┌─────────────────────┐
│ PID_Liner   │  HTTPS   │ Cloudflare Worker  │  HTTPS+Key   │ 智谱 AI API      │
│ (iOS App)   │ ───────▶ │ silen.dpdns.org    │ ────────────▶│ open.bigmodel.cn │
│             │          │ (免费 10万次/天)    │              │                  │
│             │ ◀─────── │ ◀───────────────── │ JSON Response│ GLM-4.7-Flash    │
│ NSURLSession│  JSON    │ 强制模型=免费版     │   Key安全    │                  │
└─────────────┘          └────────────────────┘   存环境变量  └──────────────────┘
       │                         │
       │  App 不接触 API Key     │  Key 只在 Cloudflare 环境变量中
       │  只知道 Worker URL      │  后台加密存储，无法查看明文
       ▼                         ▼
┌─────────────────────────┐┌──────────────────────────┐
│ 请求 JSON（~1~2K tokens）││ Cloudflare Worker 代码:   │
│ {                        ││ · 接收 App 请求            │
│   "firmware": "BF 4.5",  ││ · 强制 model=glm-4.7-flash│
│   "axis": "roll",        ││ · 从环境变量取 Key         │
│   "current_pid": {...},  ││ · 转发到智谱 AI            │
│   "step_response": {...},││ · 返回结果给 App           │
│   "noise_spectrum": {...}││ · Key 永不暴露给客户端     │
│ }                        ││                            │
└─────────────────────────┘└──────────────────────────┘
```

### API 调用详情

**安全架构**：
- App 不直接调用智谱 AI，通过 Cloudflare Worker 代理
- API Key 存储在 Cloudflare Worker 环境变量（Secret 类型，加密存储）
- Worker 强制 `model = "glm-4.7-flash"`（免费模型），即使用户请求付费模型也会被拦截
- App 端零敏感信息，无需混淆或加密

**Worker 代理地址**：
- URL: `https://silen.dpdns.org`（自定义域名，国内直连）
- 对应 workers.dev: `pidliner-proxy.silenlaung.workers.dev`（国内被墙，仅备用）
- 方法: POST only
- 格式: OpenAI 兼容（标准 JSON），无需 SDK，ObjC 用 `NSURLSession` 直接调用
- CORS: 已配置，支持跨域

**Cloudflare Worker 部署信息**：
- Worker 名称: `pidliner-proxy`
- 环境变量: `GLM_API_KEY`（Secret 类型）
- 自定义域名: `silen.dpdns.org`
- 免费额度: 10万次请求/天

**智谱 AI 后端**：
- 模型名: `glm-4.7-flash`
- Base URL: `https://open.bigmodel.cn/api/paas/v4/chat/completions`（Worker 内部调用，App 不直接访问）
- 注册: [智谱AI开放平台](https://open.bigmodel.cn)

**GLM-4.7-Flash 技术参数**：
- 架构：MoE（混合专家），总参数 300 亿（30B），每次激活 30 亿（3B）
- 上下文窗口：200K tokens（约 20 万汉字）
- 最大输出：128K tokens
- 能力：中文写作、编程、翻译、长文本处理、角色扮演

### ObjC 核心接口设计

```objc
/// 云端 AI 推荐引擎
@interface PIDAIEngine : NSObject

/// API Key（从智谱AI开放平台获取）
@property (nonatomic, copy) NSString *apiKey;

/// 基于分析结果请求 AI 推荐
/// @param analysisResult Phase 1 的信号分析结果
/// @param headerInfo BBL Header 提取的固件/PID/滤波器信息
/// @param completion 回调：推荐结果 + CLI 命令文本
- (void)requestRecommendationWithAnalysis:(PIDAxisAnalysisResult *)analysisResult
                              headerInfo:(BBLLogHeader *)headerInfo
                              completion:(void(^)(NSArray<PIDRecommendation *> *recommendations,
                                                   NSString *cliCommands,
                                                   NSString *diagnosis,
                                                   NSError *error))completion;
@end

/// 单条推荐结果
@interface PIDRecommendation : NSObject
@property (nonatomic, copy) NSString *parameterName;   // e.g. "roll_p"
@property (nonatomic, assign) double currentValue;
@property (nonatomic, assign) double recommendedValue;
@property (nonatomic, assign) double changePercent;     // 变化幅度 ±%
@property (nonatomic, copy) NSString *reason;           // "降低以消除Roll轴震荡"
@property (nonatomic, assign) double confidence;        // AI 置信度 0~1
@end
```

### AI Prompt 设计（发送给 GLM 的系统提示词）

```
你是 PID_Liner 的 AI 调参助手，精通 Betaflight 飞控 PID 调参。

根据以下飞行数据分析结果，生成：
1. 诊断报告（中文，指出每个轴的问题及严重程度）
2. PID 参数推荐（具体数值，附变化百分比）
3. 滤波器调整建议
4. 完整的 CLI 命令（可直接粘贴到 Betaflight Configurator）

注意：
- 固件版本：{firmware_version}（影响变量命名）
- 必须使用对应版本的 CLI 变量名
- 推荐幅度保守，首次调整不超过 ±30%
- 输出 JSON 格式
```

### 发送给 AI 的特征数据格式

```json
{
  "firmware": "Betaflight 4.5.0",
  "axis": "roll",
  "current_pid": {
    "p": 46, "i": 42, "d": 30, "ff": 80,
    "d_min": 25, "d_max": 40
  },
  "current_filters": {
    "dterm_lpf1_hz": 150,
    "dterm_lpf2_hz": 250,
    "dyn_notch_count": 2,
    "rpm_filter_harmonics": 3
  },
  "step_response": {
    "overshoot": 0.23,
    "rise_time_ms": 45,
    "settling_time_ms": 180,
    "steady_state_error": 0.02
  },
  "noise_spectrum": {
    "d_band_peak_hz": 320,
    "noise_floor_db": -45,
    "resonance_peaks": [120, 340]
  },
  "throttle_response": {
    "low_throttle_jitter": 0.15,
    "tpa_consistency": 0.72
  }
}
```

### 本地规则引擎（免费层，降级兜底）

当无网络或用户未付费时，使用本地规则引擎作为降级方案：

```objc
/// 本地规则推荐引擎（免费层 / 离线兜底）
@interface PIDRuleEngine : NSObject

/// 基于诊断结果生成基础推荐（纯本地，无网络）
- (NSArray<PIDRecommendation *> *)recommendFromDiagnoses:(NSArray<PIDDiagnosis *> *)diagnoses
                                              currentPID:(PIDCurrentValues *)currentPID;
@end
```

**规则表**（基于 Betaflight 社区经验）：
- P过高致震荡 → P × 0.7
- 响应迟缓 → P × 1.2
- D噪声大 → D × 0.8 或动态陷波频率 -50Hz
- Prop wash → I × 1.15
- 建立时间长 → FF (Feedforward) × 1.3

> 📌 本地规则引擎覆盖 80% 基础场景，云端 AI 提供个性化深度分析。两者共享相同的 `PIDRecommendation` 数据模型。

---

## Phase 3：CLI 文本输出 → 用户复制粘贴（替代 MSP 写回）

> 🔌 **策略变更**：原方案通过 MSP 协议 + BLE/USB 写回飞控，实现成本高（3~4周）且依赖硬件。
> 新方案改为生成 CLI `set` 命令文本，用户直接在 Betaflight Configurator 的 CLI 标签页粘贴即可。
> **实现成本从 3~4 周降至 ~半天。**

### 为什么 CLI 复制粘贴优于 MSP 写回

| 对比项 | MSP 协议写回 | CLI 复制粘贴 |
|--------|-------------|-------------|
| 实现成本 | 3~4 周（协议栈 + BLE/USB） | ~半天（文本生成） |
| 硬件依赖 | 需要 BLE 桥接器或 USB OTG | 无（用户已有 Configurator） |
| 安全性 | 程序直接写入，有风险 | 用户亲眼看到每条命令，自主决定 |
| 离线可用 | 需要连接飞控 | 生成文本可随时粘贴 |
| 调试友好 | 二进制协议难调试 | 明文可读，出错易排查 |
| 固件兼容 | 需适配 MSP 版本差异 | CLI 命令是 Betaflight 官方接口 |

### CLI 命令格式

```
# PID_Liner 生成的推荐命令（用户直接复制粘贴到 Configurator CLI）

# Roll 轴调整
set roll_p = 46
set roll_i = 42
set roll_d = 30
set roll_ff = 80

# Pitch 轴调整
set pitch_p = 44
set pitch_i = 40
set pitch_d = 28

# Yaw 轴调整
set yaw_p = 35
set yaw_i = 38
set yaw_d = 0
set yaw_ff = 70

# 滤波器调整
set dterm_lpf1_hz = 150
set dterm_lpf2_hz = 250
set dyn_notch_count = 2

# 保存（必须！）
save
```

### ⚠️ 关键：固件版本兼容性（D项命名反转）

🔑 **必须从 BBL Header 的 `Firmware revision` 字段检测固件版本，生成对应变量名。**

| 固件版本 | 基础D值 | D_max（动态增强） | 说明 |
|---------|---------|------------------|------|
| **Betaflight 4.5** | `d_min_roll` / `d_min_pitch` | `d_roll` / `d_pitch` | `d_roll` = D_max，`d_min_roll` = 基础 |
| **Betaflight 2025.12** | `d_roll` / `d_pitch` | `d_max_roll` / `d_max_pitch` | `d_roll` = 基础，`d_max_roll` = D_max |

> 🚨 **如果版本搞反，D项值会写反，可能导致飞行危险！**

### BF 2025.12 新特性（影响 CLI 变量）

| 新特性 | CLI 变量 | 说明 |
|--------|---------|------|
| **S-term** | `s_roll` / `s_pitch` / `s_yaw`（范围 0~250） | 新增S项（Setpoint权重），BF 2025.12 引入 |
| **SPA** | `spa_roll_mode` / `spa_roll_center` / `spa_roll_width` | Setpoint Profile Adjustment，按轴精细调整 |
| **SPA** | `spa_pitch_mode` / `spa_pitch_center` / `spa_pitch_width` | 同上，Pitch轴 |
| **SPA** | `spa_yaw_mode` / `spa_yaw_center` / `spa_yaw_width` | 同上，Yaw轴 |
| **TPA 曲线** | `tpa_curve_type = CLASSIC` 或 `HYPERBOLIC` | 超曲线TPA衰减，替代线性TPA |
| **TPA 曲线** | `tpa_curve_expo` / `tpa_curve_pid_thr0` / `tpa_curve_pid_thr100` / `tpa_curve_stall_throttle` | 曲线参数精细控制 |
| **TPA 速度** | `tpa_speed_type = BASIC` 或 `ADVANCED` | 速度自适应TPA |
| **TPA 速度** | `tpa_speed_basic_gravity` / `tpa_speed_basic_delay` | BASIC 模式参数 |
| **TPA 速度** | `tpa_speed_adv_mass` / `tpa_speed_adv_thrust` 等 | ADVANCED 模式参数 |
| **前馈增强** | `feedforward_yaw_hold_gain` / `feedforward_yaw_hold_time` | 前馈Yaw保持功能 |
| **前馈平滑** | `feedforward_smooth_factor`（2025.12默认65，4.5默认25） | 前馈平滑因子，版本间默认值不同 |
| **其他新增** | `thr_hover` / `landing_disarm_threshold` / `angle_pitch_offset` | 新增辅助参数 |
| **Profile 作用域** | 多数PID/滤波变量显示 `profile 0` | 表示按 Profile 分组存储 |

### 核心诊断相关 CLI 变量速查

#### PID 参数（BF 2025.12）

| 变量名 | 范围 | 诊断关联 |
|--------|------|---------|
| `roll_p` / `pitch_p` / `yaw_p` | 0~200 | P项过高/不足 |
| `roll_i` / `pitch_i` / `yaw_i` | 0~200 | I项不足（prop wash） |
| `roll_d` / `pitch_d` / `yaw_d` | 0~200 | D项基础值 |
| `d_max_roll` / `d_max_pitch` / `d_max_yaw` | 0~200 | D项动态增强 |
| `d_max_gain` | 0~100 | D_max 增益 |
| `d_max_advance` | 0~200 | D_max 提前量 |
| `roll_ff` / `pitch_ff` / `yaw_ff` | 0~200 | 前馈权重 |
| `s_roll` / `s_pitch` / `s_yaw` | 0~200 | S项权重（2025.12+） |

#### 滤波器参数

| 变量名 | 范围 | 诊断关联 |
|--------|------|---------|
| `gyro_lpf1_hz` | 0~16000 | 陀螺仪低通1截止频率 |
| `gyro_lpf2_hz` | 0~16000 | 陀螺仪低通2截止频率 |
| `dterm_lpf1_hz` | 0~16000 | D项低通1截止频率 |
| `dterm_lpf2_hz` | 0~16000 | D项低通2截止频率 |
| `dyn_notch_count` | 0~5 | 动态陷波数量 |
| `dyn_notch_min_hz` | 40~1000 | 动态陷波最低频率 |
| `dyn_notch_max_hz` | 200~16000 | 动态陷波最高频率 |
| `rpm_filter_harmonics` | 0~3 | RPM谐波数 |
| `rpm_filter_min_hz` | 50~1000 | RPM滤波最低频率 |

#### TPA 参数

| 变量名 | 范围 | 诊断关联 |
|--------|------|---------|
| `tpa_rate` | 0~100 | TPA衰减率 |
| `tpa_breakpoint` | 1000~2000 | TPA起始油门 |
| `tpa_curve` | CLASSIC / HYPERBOLIC | TPA曲线类型（2025.12+） |
| `tpa_low_rate` | 0~100 | 低油门TPA衰减 |
| `tpa_low_breakpoint` | 1000~2000 | 低油门TPA断点 |

#### 前馈参数

| 变量名 | 范围 | 诊断关联 |
|--------|------|---------|
| `feedforward_transition` | 0~100 | 前馈过渡 |
| `feedforward_boost` | 0~100 | 前馈增强 |
| `feedforward_max_rate` | 0~1000 | 前馈最大速率 |
| `ff_yaw_hold` | ON/OFF | 前馈Yaw保持（2025.12+） |

### 安全机制

- 显示变更 diff 对比（当前值 → 推荐值）
- 标注每条命令的作用和原因（注释形式）
- 标注固件版本，提醒用户确认版本匹配
- 建议用户先 `diff` 命令查看当前值，再粘贴推荐值

---

## Phase 4：二阶对比 + 迭代收敛（预测曲线 vs 实际曲线）

> 🔑 **核心创新**：用户按推荐参数飞行后，导入新 BBL → 对比预测曲线与实际曲线 → 偏差分析 → 校正系数 → 更精准二次推荐
>
> **这是 PIDtoolbox 和 FPVtune 都没有的能力**。它们只做单次推荐，不做预测验证。

### 为什么二阶对比是必要的

纯数学预测永远不可能 100% 准确，因为：

| 未建模因素 | 影响表现 | 预测偏差方向 |
|-----------|---------|------------|
| 机架共振频率 | 超调比预测大 | 需要额外降 P 或加陷波 |
| 电机响应滞后 | 建立时间比预测长 | 需要额外增 FF |
| 桨弹性变形 | 稳态精度偏差 | 需要微调 I |
| 电池电压跌落 | 高油门响应衰减 | 需要 TPA 补偿 |
| 重心偏移 | 轴间耦合 | 需要轴间平衡 |

**只有"飞一次对比一次"才能发现这些隐藏的物理因素。**

### 二阶对比 UI

```
┌─────────────────────────────────────────────────────────┐
│  ← 二阶对比分析                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─ Roll 阶跃响应 三线对比 ──────────────────────────┐  │
│  │                                                   │  │
│  │  2.0 ┤                                           │  │
│  │      │    ╭─╮                                     │  │
│  │  1.5 ┤   ╱   ╲      ── 第一次实测（蓝色实线）      │  │
│  │      │  ╱     ╲                                   │  │
│  │  1.0 ┤ ╱ · · ·  ╲___                             │  │
│  │      │· ·         · ·╲__                          │  │
│  │  0.5 ┤                · ╲  ━━ 第二次实测（橙色）   │  │
│  │      │                  ╲╲╲╲___                   │  │
│  │  0.0 ┤                       ╲╲╲╲____            │  │
│  │      ├──┬──┬──┬──┬──┬──┬──┬──┤                   │  │
│  │      0  50 100 150 200 250 300 350 400 (ms)      │  │
│  │                                                   │  │
│  │  ── 第一次实测 (P=46)  超调23%                     │  │
│  │  - - 预测曲线  (P=32)  超调9%                      │  │
│  │  ━━ 第二次实测 (P=32)  超调11%  ← 略高于预测      │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ 重合度分析 ──────────────────────────────────────┐  │
│  │                                                   │  │
│  │  轴    预测超调  实际超调  偏差   匹配度           │  │
│  │  ─── ──────── ──────── ───── ────────           │  │
│  │  Roll   9%      11%     +2%   ████████░░ 82%    │  │
│  │  Pitch  建立95ms  建立102ms  +7ms ██████░░░ 71%  │  │
│  │  Yaw    建立90ms  建立88ms   -2ms █████████ 95%  │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ 偏差分析 → 二次推荐 ────────────────────────────┐  │
│  │                                                   │  │
│  │  Roll 预测超调9% vs 实际11% (+2%)                 │  │
│  │  → 机架共振比预估强，P可以再降                     │  │
│  │  → 建议: roll_p 32 → 30                          │  │
│  │                                                   │  │
│  │  Pitch 建立时间偏差+7ms                            │  │
│  │  → 电机响应有滞后，ff再增                          │  │
│  │  → 建议: pitch_ff 104 → 109                      │  │
│  │                                                   │  │
│  │  Yaw 匹配度95%，预测准确 ✅ 无需二次调整           │  │
│  │                                                   │  │
│  │  [📋 复制二次修正CLI]   [🔄 继续迭代飞行]         │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 校正系数与自学习

每轮迭代的 **预测-实际偏差** 累积学习出这台飞机的专属校正系数：

```objc
/// 飞机专属校正系数（本地持久化存储）
@interface PIDCorrectionProfile : NSObject

@property (nonatomic, copy) NSString *craftName;        // 机型名称
@property (nonatomic, assign) double rollCorrection;    // Roll 校正因子
@property (nonatomic, assign) double pitchCorrection;   // Pitch 校正因子
@property (nonatomic, assign) double yawCorrection;     // Yaw 校正因子
@property (nonatomic, assign) NSInteger iterationCount; // 迭代轮次
@property (nonatomic, assign) double averageMatchScore; // 平均匹配度

/// 更新校正系数（每轮对比后调用）
- (void)updateWithMatchResult:(PIDMatchResult *)result axis:(NSInteger)axis;

/// 持久化到本地
- (BOOL)saveToLocal;
+ (instancetype)loadFromLocalForCraft:(NSString *)craftName;
@end
```

**校正原理**：
```
第1轮: 理论预测超调 9%   → 实际 11%  → correction = 11/9 = 1.22
第2轮: 预测 × 1.22 = 11% → 实际 10.5% → correction = 10.5/11 = 0.95 → 累计 1.16
第3轮: 预测 × 1.16 → 实际 10.2% → 匹配度 > 95% → 收敛，停止迭代
```

### 迭代追踪总览 UI

```
┌─────────────────────────────────────────────────────────┐
│  ← 迭代追踪                              📤 分享报告    │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─ 调参进度 ────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  Roll轴评分趋势:                                  │  │
│  │                                                   │  │
│  │  100 ┤                              ╭● 第3轮 95分 │  │
│  │   80 ┤                      ╭──● 第2轮 82分      │  │
│  │   60 ┤              ╭─● 第1轮 68分                │  │
│  │   40 ┤      ● 原始 35分                            │  │
│  │   20 ┤                                            │  │
│  │      └───┬────┬────┬────┬───                     │  │
│  │          原始  第1轮 第2轮 第3轮                   │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ 参数变更历史 ────────────────────────────────────┐  │
│  │                                                   │  │
│  │  轮次   roll_p  roll_d  pitch_ff  匹配度  评分   │  │
│  │  ───── ─────── ─────── ──────── ─────── ──────  │  │
│  │  原始     46      30      80       --      35    │  │
│  │  第1轮    32      25      104     78%     68    │  │
│  │  第2轮    30      25      109     91%     82    │  │
│  │  第3轮    29      24      110     96%     95    │  │
│  │  ✅ 收敛 — 匹配度>90%，建议停止迭代              │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ 预测模型自学习 ──────────────────────────────────┐  │
│  │                                                   │  │
│  │  你的飞机专属校正系数:                             │  │
│  │  · Roll轴: 理论预测 × 1.08（机架偏软，多补偿8%） │  │
│  │  · Pitch轴: 理论预测 × 1.04（电机略滞后）        │  │
│  │  · Yaw轴: 理论预测 × 1.01（非常准确）            │  │
│  │                                                   │  │
│  │  💡 下次新BBL直接用校正系数预测，精度更高         │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 完整迭代闭环流程

```
                          ┌──────────────────────┐
                          │    第一次飞行 录BBL   │
                          └──────────┬───────────┘
                                     ↓
                          ┌──────────────────────┐
                          │  Phase 1: 信号分析     │
                          │  阶跃响应 + 噪声频谱   │
                          │  提取特征: 超调/建立时间│
                          └──────────┬───────────┘
                                     ↓
                          ┌──────────────────────┐
                          │  拟合二阶系统模型      │ ← 新增
                          │  H(s) = K·ωn²/(s²+2ζωn·s+ωn²)
                          │  提取 ωn, ζ, K        │
                          └──────────┬───────────┘
                                     ↓
                          ┌──────────────────────┐
                          │  Phase 2: AI推荐CLI   │
                          │  + 生成预测曲线        │ ← 新增
                          │  三线重叠显示:         │
                          │  当前+预测+历史最优    │
                          └──────────┬───────────┘
                                     ↓
                          ┌──────────────────────┐
                          │  Phase 3: 输出CLI命令  │
                          │  用户复制粘贴到飞控    │
                          └──────────┬───────────┘
                                     ↓
                          ┌──────────────────────┐
                          │    第二次飞行 录BBL   │ ← 用户操作
                          └──────────┬───────────┘
                                     ↓
                 ┌──────────────────────────────────────┐
                 │  Phase 4: 二阶对比（核心创新 🔑）    │
                 │                                      │
                 │  ── 第一次实测曲线（蓝实线）          │
                 │  - - 预测曲线    （绿虚线）           │
                 │  ━━ 第二次实测曲线（橙实线）          │
                 │                                      │
                 │  三线重叠 → 计算预测vs实际偏差        │
                 │  偏差 → 校正系数 → 本地持久化         │
                 └──────────────┬───────────────────────┘
                                ↓
                 ┌──────────────────────────────────────┐
                 │  偏差 → 校正系数                      │
                 │                                      │
                 │  Roll理论预测 × 1.08 = 实际          │
                 │  Pitch理论预测 × 1.04 = 实际         │
                 │                                      │
                 │  → 校正系数存入本机                   │
                 │  → 下次预测直接乘校正系数             │
                 └──────────────┬───────────────────────┘
                                ↓
                 ┌──────────────────────────────────────┐
                 │  输出二次修正 CLI 命令                 │
                 │  用户第三次飞行 → 第三轮对比          │
                 │  匹配度 > 90% → 收敛 → 停止迭代      │
                 └──────────────────────────────────────┘
```

### 收敛判定标准

| 指标 | 收敛阈值 | 说明 |
|------|---------|------|
| 匹配度 | **> 90%** | 预测曲线与实际曲线高度重合 |
| 评分变化 | **< 3分** | 两轮之间评分差异小于3分 |
| 参数变化 | **< 5%** | 两轮之间推荐参数变化幅度小于5% |
| 迭代上限 | **5轮** | 超过5轮未收敛则建议手动检查硬件 |

> 📌 任何一项达标即提示"接近收敛"，全部达标则建议停止迭代。

---

## 用户交互设计（曲线互动为核心）

> 🔑 **设计原则**：UI 围绕曲线互动展开，不是纯文字列表。
> 用户看到的是"曲线变化"而不是"参数变化"。

### 导航结构

```
现有 Tab（保持不变）          新增 Tab
──────────────────          ──────────

┌──────────────────────────────────────────────┐
│  📊响应图 │ 📡噪声图 │ 🩺诊断 │ 🔄迭代追踪  │
└──────────────────────────────────────────────┘
```

### Tab 3：诊断（评分 + 预测曲线 + CLI 输出）

```
┌─────────────────────────────────────────────────────────┐
│  ← 诊断                              📤 分享报告        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─ 固件信息 ────────────────────────────────────┐      │
│  │  Betaflight 4.5.0  ·  MATEK F405              │      │
│  │  🟢 完整CLI支持 · 参数完整性 ✅               │      │
│  └───────────────────────────────────────────────┘      │
│                                                         │
│  ┌─ 综合评分 ────────────────────────────────────┐      │
│  │  Roll   ████████░░░░  82分  良好 🟢           │      │
│  │  Pitch  ██████░░░░░░  68分  ⚠️ 🟡             │      │
│  │  Yaw    ███░░░░░░░░░  35分  较差 🔴           │      │
│  └───────────────────────────────────────────────┘      │
│                                                         │
│  ┌─ 问题诊断 + 预测曲线 ──────────────────────────┐     │
│  │                                                │     │
│  │  🔴 Yaw P项过高  超调23%                       │     │
│  │  建议: yaw_p 46→32  预测超调: 23%→9%  ✅      │     │
│  │                                                │     │
│  │  🟡 Pitch 建立时间偏长  180ms                  │     │
│  │  建议: pitch_ff 80→104  预测建立: 180→95ms ✅  │     │
│  │                                                │     │
│  │  🟢 Roll 响应正常  超调8% · 建立45ms 无需调整  │     │
│  │                                                │     │
│  │  [▶ 展开预测曲线图]                            │     │
│  │                                                │     │
│  └────────────────────────────────────────────────┘     │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  📋 复制CLI命令（含预测效果）  🤖 AI深度分析 ¥  │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  📊 响应图 │ 📡 噪声图 │ 🩺 诊断 │ 🔄 迭代追踪       │
└─────────────────────────────────────────────────────────┘
```

### 展开预测曲线后的视图

```
┌─────────────────────────────────────────────────────────┐
│  ← Roll 预测对比                                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─ Roll 阶跃响应 预测对比 ──────────────────────────┐  │
│  │                                                   │  │
│  │  2.0 ┤                                           │  │
│  │      │       ╭─╮                                  │  │
│  │  1.5 ┤      ╱   ╲      ── 当前实测（蓝色实线）    │  │
│  │      │     ╱     ╲                                │  │
│  │  1.0 ┤    ╱  ·  · ╲___                           │  │
│  │      │   ╱ ·        · ·╲__                       │  │
│  │  0.5 ┤  ·               · ╲  ── 预测曲线（绿色   │  │
│  │      │ ·  (虚线)              ╲   虚线）          │  │
│  │  0.0 ┤·                        ╲___              │  │
│  │      ├──┬──┬──┬──┬──┬──┬──┬──┤                  │  │
│  │      0  50 100 150 200 250 300 350 400 (ms)      │  │
│  │                                                   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ 参数变更明细 ────────────────────────────────────┐  │
│  │  参数     当前值   推荐值   预测效果               │  │
│  │  ─────── ─────── ─────── ──────────              │  │
│  │  roll_p     46      32    超调 23%→9% ✅          │  │
│  │  roll_d     30      25    噪声 ↓12% ✅            │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌─ CLI 命令 ────────────────────────────────────────┐  │
│  │  # Roll: P降低消除超调, D降低减少噪声             │  │
│  │  set roll_p = 32                                  │  │
│  │  set roll_d = 25                                  │  │
│  │  save                                             │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │       📋 复制全部命令到剪贴板                     │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 用户完整操作路径

```
1. 导入 BBL → 转换 CSV → 点分析（和现在一样）
       ↓
2. 分析完成 → 跳到"诊断"Tab ← 新增
       ↓
3. 看到评分 + 问题 + 预测曲线 ← 核心互动
   · 展开任意轴 → 看到当前曲线和预测曲线重叠
   · 预测曲线直观展示"调完后大概长什么样"
       ↓
4. 点"复制CLI命令" → 粘贴到 Configurator ← Phase 3
       ↓
5. 同样操控第二次飞行 → 导入新 BBL
       ↓
6. 自动匹配到上一轮 → 跳到"迭代追踪"Tab ← Phase 4
   · 三线对比: 第一次实测 + 预测 + 第二次实测
   · 偏差分析 + 校正系数 + 二次修正 CLI
       ↓
7. 重复直到匹配度 > 90% → 收敛 → 完成 ✅
```

```
┌─────────────────────────────────┐
│  PID_Liner                      │
│                                 │
│  [导入 BBL] [选择 Session]      │
│                                 │
│  ┌─── 分析结果仪表盘 ──────┐    │
│  │                          │    │
│  │  Roll  ████░░  72分      │    │
│  │  Pitch █████░  85分      │    │
│  │  Yaw   ██░░░░  45分 ⚠️   │    │
│  │                          │    │
│  └──────────────────────────┘    │
│                                 │
│  ┌─── 诊断报告 ────────────┐    │
│  │ 🔴 Yaw P项过高           │    │
│  │    检测到持续震荡         │    │
│  │    [查看频谱证据]         │    │
│  │                          │    │
│  │ 🟡 Roll D噪声偏大        │    │
│  │    高频段噪声超过阈值     │    │
│  │    [查看噪声图]           │    │
│  └──────────────────────────┘    │
│                                 │
│  ┌─── AI推荐调整 ──────────┐    │
│  │  Yaw P:  46 → 32 (-30%) │    │
│  │  Roll D: 30 → 24 (-20%) │    │
│  │  Roll FF: 80 → 100(+25%)│    │
│  │                          │    │
│  │  [逐条确认]  [全部应用]   │    │
│  │  [复制CLI命令]           │    │
│  └──────────────────────────┘    │
│                                 │
│  ┌─── 迭代追踪 ────────────┐    │
│  │  第1次 45→72  ↑27分 ✅   │    │
│  │  第2次 72→85  ↑13分 ✅   │    │
│  │  目标: >90分             │    │
│  └──────────────────────────┘    │
└─────────────────────────────────┘
```

---

## 实施路线图

| 阶段 | 内容 | 周期 | 可行性 |
|------|------|------|--------|
| **Phase 1** | 诊断引擎 + 预测曲线引擎 | 2~3周 | ⭐⭐⭐⭐⭐ 已有全部分析数据 |
| **Phase 2** | 云端 AI 推荐（GLM-4.7-Flash） | 1~2周 | ⭐⭐⭐⭐⭐ 免费无限，OpenAI兼容API |
| **Phase 2B** | 评分仪表盘 + 付费墙 | 1周 | ⭐⭐⭐⭐⭐ 纯UI + StoreKit |
| **Phase 3** | CLI 文本输出（复制粘贴到Configurator） | ~半天 | ⭐⭐⭐⭐⭐ 零硬件依赖，明文可读 |
| **Phase 4** | 二阶对比 + 迭代追踪 + 校正系数 | 1~2周 | ⭐⭐⭐⭐ 需要用户二次飞行配合 |

---

## 为什么这个方案可行

1. **预测曲线是杀手锏**：PIDtoolbox 和 FPVtune 只推荐参数值，不预测结果。PID_Liner 在推荐的同时绘制预估曲线，用户看到效果才有信心付费
2. **二阶对比闭环**：预测 vs 实际的偏差暴露隐藏物理因素，每轮迭代校正系数累积，越用越准
3. **AI 零成本**：GLM-4.7-Flash 完全免费无限调用，用户付费即纯利润
4. **有行业验证**：FPVtune 已证明这个思路可行，PIDtoolbox 的分析方法也已经实现
5. **复用 90% 的代码**：已有的分析管线就是这个产品的核心竞争力
6. **CLI 输出零门槛**：生成 `set` 命令文本，用户复制粘贴到 Configurator CLI 即可，无需任何硬件

---

## 附录：语言选型备忘（ObjC vs Swift 决策记录）

### 结论：全 ObjC 开发，不混编

### 决策依据

**核心资产**：已验证的信号分析管线 + 完美曲线渲染，经历 ObjC/Swift 互调调试的痛苦才达到当前状态，不应再引入混编风险。

**Swift 得益分析**（讨论结论）：

| | 数据层 | 决策层（新模块） |
|---|--------|---------------|
| FFT 计算 | ✅ ObjC 已验证 | — |
| 维纳反卷积 | ✅ ObjC 已验证 | — |
| 阶跃响应分析 | ✅ ObjC 已验证 | — |
| CSV 解析 | ✅ ObjC 已验证 | — |
| 诊断规则引擎 | — | ObjC 足够（if-else + 枚举） |
| PID 推荐系统 | — | ObjC 足够（字典 + 规则查表） |
| 评分/仪表盘 | — | ObjC 足够（纯 UI） |
| MSP 协议栈 | — | ObjC 足够（NSData + 字节操作） |
| CoreML 推理 | — | ObjC 可调用（语法稍繁琐但能用） |

### 混编排异问题（踩坑记录）

1. **`NSArray<NSNumber *>` ↔ `[Double]`**：Swift 拿到的是 `[NSNumber]` 不是 `[Double]`，每次穿越边界都要 `.map { $0.doubleValue }`，数据量大时性能和代码都不干净
2. **`id` / `Any` 穿透**：ObjC 返回的无类型数组在 Swift 侧变成 `[Any]`，每次使用都要 `as?` 强转
3. **枚举不兼容**：Swift 的 associated value enum 在 ObjC 侧不可见
4. **调试体验差**：ObjC 调 Swift、Swift 回调 ObjC，断点打不准，桥接头文件来回改

### 最终策略

```
┌──────────────────────────────────┐
│  全 ObjC（保持不动）               │
│  BlackboxDecoder + PIDCSVParser   │
│  PIDTraceAnalyzer + FFT + 滤波    │
│  PIDDataModels                    │
│  PIDDiagnosisEngine  ← Phase 1   │
│  PIDAIEngine (GLM)   ← Phase 2   │
│  PIDRuleEngine (兜底) ← Phase 2   │
│  评分 UI + 付费墙     ← Phase 2B  │
│  CLI 文本生成         ← Phase 3   │
│  CoreML 模型         ← Phase 4   │
└──────────────────────────────────┘
```

> 📌 **原则**：不为了"代码优雅"打断已跑通的管线。ObjC 完全能胜任全部 Phase，零混编风险。

---

## 参考资源

### CLI 命令参考（Phase 3 核心数据源）

- [Betaflight 2025.12 CLI Command Line Reference](https://betaflight.com/docs/wiki/guides/current/Betaflight-2025.12-CLI-commands) — 最新版完整CLI变量清单（~700+个变量），包含S-term、SPA、TPA曲线等新特性
- [Betaflight 4.5 CLI Command Line Reference](https://betaflight.com/docs/wiki/guides/current/Betaflight-4.5-CLI-commands) — BF 4.5完整CLI变量清单（~600+个变量），注意D项命名与2025.12相反
- [Betaflight CLI 开发文档](https://betaflight.com/docs/development/Cli) — CLI协议官方说明，包含命令格式和参数范围
- [settings.c 源码](https://github.com/betaflight/betaflight/blob/master/src/main/cli/settings.c) — Betaflight固件中所有CLI变量的权威定义（C语言），变量名、范围、默认值的最准确来源
- [betaflight-deciphered](https://github.com/mathiasvr/betaflight-deciphered) — 社区维护的CLI变量反编译文档，按版本追踪变量变化
- [firmware-presets](https://github.com/betaflight/firmware-presets) — Betaflight官方机型预设CLI配置片段，可作为推荐参数的参考基线

### BBL 解码与信号分析

- [FPVtune - AI PID Auto Tuning 技术详解](https://dev.to/fpvtune/i-built-an-auto-pid-tuning-tool-for-betaflight-heres-how-it-works-under-the-hood-okg)
- [FPVtune GitHub 开源仓库](https://github.com/chugzb/betaflight-pid-autotuning)
- [Betaflight Blackbox Logging Internals — BBL文件格式详解](https://betaflight.com/docs/development/Blackbox-Internals)
- [Betaflight MSP Protocol Header 源码](https://github.com/betaflight/betaflight/blob/master/src/main/msp/msp_protocol.h)
- [PIDtoolbox Blackbox 分析教程](https://oscarliang.com/pid-filter-tuning-blackbox/)

### 云端 AI（Phase 2 核心）

- [智谱AI开放平台](https://open.bigmodel.cn) — GLM-4.7-Flash 免费 API 注册入口，完全免费、无调用限制
- [GLM-4.7-Flash API 文档](https://open.bigmodel.cn/dev/api/normal-model/glm-4) — 接入指南，OpenAI 兼容格式
- Cloudflare Worker 代理: `https://silen.dpdns.org` — API Key 安全代理，Key 存于环境变量，App 端零敏感信息
- [2026大模型API免费额度汇总（知乎）](https://zhuanlan.zhihu.com/p/2011551559968896157) — 各平台免费额度对比
- [2026大模型API免费额度汇总（腾讯云）](https://cloud.tencent.com/developer/article/2626756) — 备用参考

### 调参指南与学术参考

- [Betaflight PID Tuning Guide](https://betaflight.com/docs/wiki/guides/current/PID-Tuning-Guide)
- [Betaflight 4.6 新特性](https://oscarliang.com/betaflight-4-6/)
- [Betaflight 4.5 Release Notes — motor_kv/RPM滤波说明](https://betaflight.com/docs/wiki/release/Betaflight-4-5-Release-Notes)
- [Betaflight MSP Extensions 官方文档](https://betaflight.com/docs/development/API/MSP-Extensions)
- [MSP Protocol 命令列表](https://gist.github.com/kolezka/622d6e3ac37ccd5598d6cabfdff7305e)
- [ArduPilot AutoTune — 飞行中自动调参](https://ardupilot.org/copter/docs/autotune.html)
- [Auto-Tuning Algorithms for Rotor PID Loops — 学术综述](https://medium.com/@jzika1/auto-tuning-algorithms-for-rotor-pid-loops-in-multirotor-drones-academic-and-industry-approaches-0bde34c9b0ff)
- [ETH Zürich AutoTune — 高速飞行控制器自动调参](https://rpg.ifi.uzh.ch/docs/RAL21_Saviolo_Loquercio_AutoTune.pdf)
- [AirPilot — DRL增强自适应PID控制器](https://arxiv.org/pdf/2404.0204)
