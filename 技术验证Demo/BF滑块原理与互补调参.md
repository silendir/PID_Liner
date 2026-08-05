# BF Simplified Tuning 滑块原理 与 互补调参

> **起草**: 2026-08-05
> **目的**: 把 BF 滑块的安全联调原理落盘,避免每次重新理解;明确"滑块 vs 纯净参数"互补关系;指导 CLI 输出单位与拟合/反解目标单位。
> **触发**: 用户洞察"飞手用滑块调参(2m S2→S3 PI 同变 = pi_gain 联动),滑块值域窄(0.5-2x),拟合滑块比拟合 PID 真值更简单有效"
> **参考**(2026-08-05 已 curl 拿到 BF 源码 ground truth,本文公式/默认值/枚举全部源码核对):
> - `src/main/config/simplified_tuning.c`(`calculateNewPidValues` 行 31-63、滤波器 行 65-95)
> - `src/main/config/simplified_tuning.h`(枚举/值域 行 26-37)
> - `src/main/flight/pid.h`(默认值 行 64-67、`D_MAX_DEFAULT` 行 67)
> - [BF PID Tuning Tab 官方](https://betaflight.com/docs/wiki/app/pid-tuning-tab)、[Oscar Liang](https://oscarliang.com/fpv-drone-tuning/)

---

## 一、为什么 BF 滑块是"手调时代终极形态"

单调 P/I/D 各参数会:
- **互相干扰/限制**: P 升高引发振荡,I 升高引发 windup/D 发热,D 过高引发噪声放大
- **破坏安全比例**: P:I、P:D 有安全区间,越界 → 超调/震荡/炸机,十分危险

BF 滑块(Simplified Tuning, 4.3+)把"高频联动的参数"打包成组,让飞手只在**安全子空间**内调参。🔑 **源码确认:公式级联调只有 PI 一组**(`pi_gain` 同时进 P 和 I 项),master 是全局标量,D/FF 各自独立:
- **PI 联调**: `pi_gain` 同步缩放 P 和 I,保 P:I 比例恒定(唯一真联动)
- **master_multiplier**: 全局加力,P/I/D/FF 全部等比例,所有比例恒定,最粗最安全
- ⚠️ **"PD 比例约束"源码不存在** —— D 公式不含 piGain,D 与 P 无公式耦合(D 默认值 30 ≈ P 默认 45 的某种比例只是默认值设定,不是滑块约束)。早期文档写过"PD 联调",已据源码删除

🔑 这是 BF 社区 10 年迭代的产物 —— 不是"必须用滑块",而是滑块把危险的单变量调参约束到了安全子空间。

---

## 二、滑块全集(源 `simplified_tuning.h` + `pid.h` + `gyro.h`)

值域(`.h` 行 26-30):PID 滑块 `[0,200]` 默认 100;**滤波器滑块 min=10**(`SIMPLIFIED_TUNING_FILTERS_MIN`)`[10,200]` 默认 100;D 滑块默认 100。推荐范围 70-140(0.7x-1.4x),master 0.5x-2.0x。

**PID 滑块(9 个)**:
| CLI 名 | 作用 | 源码缩放对象 |
|---|---|---|
| `simplified_pids_mode` | 作用轴枚举 | OFF=0 / RP=1(只Roll+Pitch) / RPY=2(三轴);行 48 `for axis<=pids_mode` |
| `simplified_master_multiplier` | **全局标量** | P/I/D/FF **全部**乘 |
| `simplified_pi_gain` | **PI 联调** | P 和 I 都乘(保 P:I) |
| `simplified_i_gain` | I 微调 | 只 I 乘 |
| `simplified_d_gain` | D 缩放 | D 和 d_max 都乘 |
| `simplified_feedforward_gain` | FF 缩放 | 只 FF 乘 |
| `simplified_d_max_gain` | d_max 混合增益 | d_max 的混合公式(见 §三·二) |
| `simplified_pitch_pi_gain` | Pitch P/I/FF 偏置 | Pitch 的 **P/I/FF** 都乘(D 不受影响) |
| `simplified_roll_pitch_ratio` | Pitch D 偏置 | Pitch 的 D/d_max 乘(原名 pitchDGain) |

**滤波器滑块(2 个)** — 🔑 对反解 forward 模型重要:
| CLI 名 | 作用 | 源码缩放对象 |
|---|---|---|
| `simplified_dterm_filter_multiplier` | dterm 低通倍率 | `dterm_lpf1_dyn_min/max_hz`、`dterm_lpf1_static_hz`、`dterm_lpf2_static_hz` |
| `simplified_gyro_filter_multiplier` | gyro 低通倍率 | `gyro_lpf1_dyn_min/max_hz`、`gyro_lpf1/2_static_hz` |

**3 个独立开关**(`c` 行 97-123,三者互不影响):
- `simplified_pids_mode != OFF` → 应用 PID 滑块
- `simplified_dterm_filter = true` → 应用 dterm 滤波滑块
- `simplified_gyro_filter = true` → 应用 gyro 滤波滑块

---

## 三、PID 公式(源 `calculateNewPidValues`,行 51-54)

**Roll 轴**(`pitchPiGain=1, pitchDGain=1`,默认值 `pid.h` 行 64):
```
P_roll  = 45 × master × pi                          // master = simplified_master_multiplier/100
I_roll  = 80 × master × pi × i                      // ← PI 联调:pi 同时进 P 和 I
D_roll  = 30 × master × d
FF_roll = 120 × master × ff
```

**Pitch 轴**(额外乘 `pitchPi` 进 P/I/FF、`pitchD` 进 D,默认值 `pid.h` 行 65):
```
P_pitch  = 47 × master × pi × pitchPi
I_pitch  = 84 × master × pi × i × pitchPi
D_pitch  = 34 × master × d × pitchD               // pitchD = simplified_roll_pitch_ratio/100
FF_pitch = 125 × master × pitchPi × ff            // ⚠️ FF 也吃 pitchPi(BFSliderMapper 之前漏了)
```
全部 `constrain(..., 0, PID_GAIN_MAX)` 硬限。

🔑 **三个旋钮对 P:I 比例的影响**(源码直接读出):
- 调 `master` → P/I/D/FF 全等比例 → 所有比例恒定
- 调 `pi_gain` → P 和 I 同比例 → **P:I 恒定**(45:80≈0.56),这是"安全联调"的本质
- 调 `i_gain` → 只 I → P:I 改变(独立 I 微调自由度)

## 三·二、D_MAX 混合公式(源 行 57-60,之前完全没提)

```c
dMaxGain = d_max_gain/100 + (1 - d_max_gain/100) × (D_default / DMax_default)
d_max[axis] = DMax_default × master × d × pitchD × dMaxGain
```
默认值:`D_MAX_DEFAULT = {40, 46, 0}`(Roll/Pitch/Yaw),`PID_ROLL_DEFAULT.D = 30`。
- 滑块 `d_max_gain=100` → `dMaxGain=1.0` → d_max 独立用 DMax_default(40)
- 滑块调小 → `dMaxGain` 往 `D_default/DMax_default`(Roll=30/40=0.75)靠 → d_max 跟随 D
语义:在"独立大 D Max"与"跟随 D"间过渡。Roll 默认情况下 `d_max = 40 × master × d × (1.0 或往0.75靠)`。

## 三·三、滤波器滑块(源 行 65-95,对反解 forward 是大事)

```c
// dterm(仅当对应 filter 字段非0时改)
dterm_lpf1_dyn_min_hz = DTERM_LPF1_DYN_MIN_HZ_DEFAULT × dterm_filter_multiplier/100
dterm_lpf1_dyn_max_hz = DTERM_LPF1_DYN_MAX_HZ_DEFAULT × dterm_filter_multiplier/100
dterm_lpf2_static_hz  = DTERM_LPF2_HZ_DEFAULT        × dterm_filter_multiplier/100
// gyro 同理用 gyro_filter_multiplier
```
🔑 **反解意义**:forward 模型里 gyro 三级低通链 + dterm 低通的截止频率,在滑块模式下**不是独立 CLI 参数**,而是由 `gyro_filter_multiplier` / `dterm_filter_multiplier` 联动决定。反解/拟合 forward 时,若飞机开了 simplified filter,截止频率必须从滑块算,不能当独立输入。

---

## 四、用滑块解释 2m 数据(重要更正)

怪象3.5寸 S2→S3:
- S2: P45/80/30 → S3: P49/88/30
- P: 45→49 (**+8.9%**), I: 80→88 (**+10.0%**) → **几乎同比例**
- 🔑 这**不是**飞手刻意同时调 P+I,是飞手拉了 **pi_gain 滑块**(100→~109)
- 反解"S3 P 最高"方向归因 P 仍成立(2j-pre 证 I 在 0.5s 步响应贡献 <1.2%),但**实验解释要更正**: 数据是滑块联动产物,非单变量

---

## 五、⚠️ 算法意义再评估:拟合滑块值的真实优势与边界(2026-08-05 乘积分析修正)

**早期乐观论断(已修正)**:滑块值域窄(0.5-2.0x)、PI 联动,曾被认为"比拟合 PID 真值更低维、欠定风险低、可能缓解 #27"。

**乘积分析后的修正**:

| 维度 | 拟合滑块值(5维) | 拟合 PID 真值(4维) |
|---|---|---|
| 值域 | 0.5-2.0x(窄,有界) | 0-200+(宽,连续) |
| 有效自由度 | master/pi/i/d/ff,但 **master×pi 乘积不可识别** | P/I/D/FF,但 **K_plant×P 乘积不可识别(#27)** |
| 与 #27 关系 | 🔴 **更严重**:曲线 ∝ K_plant×master×pi **三因子乘积** | K_plant×P 两因子乘积 |
| 真正优势 | 值域有界 + PI 联动可作先验正则 | 表达力全 |

🔑 **🔴 证伪"拟合滑块缓解 #27"**:滑块参数化下曲线响应 ∝ `K_plant × master × pi`(P 通道),这是**三因子乘积**,比 PID 真值视角的 `K_plant × P`(两因子)还多一个不可识别因子 master。→ **切滑块目标让 #27 欠定更严重,不是更轻**。与 #27 老发现(2i/2k:`ÿ ∝ Kp·K_plant/τM` 乘积耦合)**同源** —— 都是乘积恒等式下的不可识别性,滑块不治它,反而加码。

🔑 **拟合滑块的真正优势(不是低维,是有界 + 先验)**:值域 0.5-2x 提供天然 box 约束,PI 联动提供"解落在安全子空间"的先验 → 可作正则化项降低数值欠定的实际影响,但**不减少本质不可识别维度**。

→ **反解目标单位切滑块的决策依据要从"缓解欠定"改为"匹配飞手操作单位 + 有界正则"**,不能指望它治 #27。#27 出路仍是 2i/2k 老结论:**固定/先验/独立测量源**(τM 独立标已证伪 → 实际剩 尺寸/KV 先验档位表 + 单架预标定)。

- `BFSliderMapper` 已就绪正向(Slider→PID)与反向(PID→Slider,但反向写死 master=100 = 不可识别的体现)
- 反解器若切滑块目标:先修 BFSliderMapper 5 bug(§八),且必须给 master 加先验/固定,不能 fit

---

## 六、互补调参:滑块 vs 纯净参数(产品哲学)

| 维度 | 滑块(Simplified) | 纯净参数(Raw PID) |
|---|---|---|
| 自由度 | 低(PI 联动) | 高(4 维独立) |
| 值域 | 0.5-2.0x(窄) | 0-200+(宽) |
| 安全性 | 高(比例约束,不易炸) | 低(易破坏比例) |
| 表达力 | 粗(安全子空间) | 细(全空间) |
| 适用 | 主线/快速收敛/小白 | 进阶/精细雕塑/老飞手 |

🔑 **两种手段互补,不是非此即彼**:
- 滑块做**安全粗调**(主线/收敛/拟合目标单位)
- 纯净参数做**精细微调**(进阶/风格化/曲线雕塑)
- 产品应**同时支持**,按用户层级(小白/中级/老飞手)暴露不同原语 —— 呼应 `product-positioning-style-eq` "用一个原语吃掉 BF Slider 手动 + Chirp 自动两个割裂产品"。

---

## 六·二、🎯 实操调参方法论:主乘数两步法(规避超调)

> 飞手实战流程(2026-08-05 用户传授)。**源码只有公式、没有这个方法论,必须单独记**——这是十年经验沉淀的操作哲学,不在 `simplified_tuning.c` 里。

**两步法**:
1. **先降低主乘数**(`simplified_master_multiplier` 调到 0.2-0.3)→ 所有 PID 参数 ×0.2 → 整个闭环增益被压缩到极小可控范围
2. **在低主乘数下调比例**(`pi_gain`/`i_gain`/`d_gain`)→ 整体力度被压缩,任何比例失配引发的超调/振荡也被等比缩小,不会炸机,且异常清晰可观察、可定位
3. **调好比例后拉回主乘数** → 等比例放大到正常力度,比例已对,放大不超调

**机理(源码印证)**:master_multiplier **乘进所有 PID 项**(行 51-54),所以它**不改变任何比例**(P:I、P:D、I:D 全部恒定),纯粹等比例缩放闭环增益。这使它成为完美的"安全力度阀"——压它不破坏你已调好的比例,拉它只是整体加力/减力。

**控制理论对应**(为什么这能规避超调):
- `master_multiplier` = 闭环增益(系统带宽/响应速度)
- `pi_gain`/`d_gain` 的相对比例 = 阻尼比/极点配置(响应形状)
- 两步法 = **先调形状(阻尼对),再上增益(力度)** —— 教科书式的稳定调参顺序
- 超调 = 高增益 × 错阻尼。直接全力度试比例 = 每次试探都在"高增益+未知阻尼"区 → 剧烈超调/炸机;压到 0.2 = 把试错挪到低增益区,异常×0.2,试错成本极低;比例对后再放大 = 系统按正确阻尼比放大,平稳

⚠️ **重要更正(2026-08-05 用户质疑后,撤回"两阶段反解分解")**:
- 两步法是**人类飞手的观测/试错方法**(在无法精确获知参数现实表达时用的安全策略),**不能直接套到反解/拟合的算法分解** —— 实际是否对反解有效从未验证过。
- 而且**数学上"先定比例再定 master"在反解里不成立**:`P = 45 × master × pi` 是乘积,曲线只能识别乘积 `master×pi`,**单独的 master 不可识别**(冗余自由度,与 pi 对 P 的贡献数学等价)。`BFSliderMapper` 反向映射必须写死 master=100 即此原因。所以"两阶段拟合"作为反解策略**撤回**。
- 🔑 副产品认知:这同时修正了"拟合滑块比拟合 PID 真值更低维更简单"的早期论断 —— 滑块 5 维(master/pi/i/d/ff)比 PID 真值 4 维**更高维**,且 master 不可识别 → 拟合滑块的真正优势是**值域有界(0.5-2x)+ PI 联动先验可作正则**,不是"低维"。

**仅 UX 层面成立**:CLI 分层呈现(比例建议 + 力度建议)契合飞手两步心智,便于分步验证 —— 这是**产品呈现**,不是算法分解。

## 七、CLI 输出形态

产品 CLI 应**优先输出 `set simplified_*` 滑块命令**(飞手实际操作单位),纯净参数(`set p_roll` 等)作为 Expert 模式备选。
- `BFSliderMapper.generateSliderCLI` 已实现(输出 `set simplified_pi_gain=...` 等)
- `PIDCLIGenerator` 已接入(generateSliderOutput,行 50-56、166)

---

## 八、代码资产与待修 bug

**已就绪**:`PIDCLIGenerator.m` 的 `generateSliderOutput`/`generateSliderCLI` 滑块 CLI 输出能力可用。

🔴 **`BFSliderMapper.{h,m}` 对照源码发现的待修 bug(2026-08-05 源码核对)**:
1. **漏 `master_multiplier`** —— 正映射公式没乘 master(本地写死 100)。默认等价但用户改 master 时映射错,反向映射丢 master 信息。修复:正/反向都引入 master。
2. **Pitch FF 漏 `pitchPiGain`** —— 源码 `F_pitch = F × master × pitchPi × ff`,本地 FF 只乘 ff。
3. **D_MAX 复杂公式大概率未实现** —— 源码 `dMaxGain` 混合公式(§三·二),需核对本地是否只做简单倍率。
4. **滤波器滑块未实现** —— `dterm_filter_multiplier` / `gyro_filter_multiplier` + 截止频率联动(§三·三),反解 forward 必需,本地大概率没有。
5. **滑块数说错** —— 本地常说"7 滑块",源码实际 9 PID 滑块 + 2 滤波器滑块(含 pids_mode 枚举)。

修复时机:反解深化阶段(切拟合目标到滑块倍率前必须先修 1-4)。

**待办(反解深化,后置拟合主线 #28)**:
- 先修上述 5 个 bug,让 `BFSliderMapper` 与源码对齐
- 拟合/反解目标单位从 PID 真值切到滑块倍率
- forward 模型接入滤波器滑块联动截止频率
- 验证低维滑块空间是否缓解 #27 K 欠定

---

## 九、版本注意

- BF Simplified Tuning 自 **4.3** 引入
- 怪象3.5寸是 **BF 4.3.1**,刚好踩在引入版本 → 解释了为何这批数据开始出现滑块联动特征
- D 默认值随版本变:BF 4.3-4.5 D=40;BF 2025+ D=30(`BFSliderMapper.dDefaultForRoll` 已分支处理)
