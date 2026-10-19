# 黑盒频带分析脚本（TPA/AG 识别方法论 v1）

> 2026-10-19 | 配套文档：`分析文档/TPA-AG识别方法论-频带分析v1.md`
> 数据源：`吴飞行迭代/` 六轮 BBL（BETAFPVG473_V3 / BF 2025.12.2 / 994Hz）

## 用途

| 脚本 | 干什么 | 关键产出 |
|---|---|---|
| `bb_tpa.mjs` | **TPA 识别主工具**：高/低油门段 gyro 频带能量分解 + jitter-油门曲线 | 30~150Hz 占比 vs 15% 病灶线 → TPA 是否需调 |
| `bb_rounds.mjs` | 各轮稳态段 PID 输出中位数对比 | 稳态误差淹没 P 输出，**量级法不成立**（方法学反例，留档） |
| `bb_kp.mjs` | **等效 P 增益**：median(axisP/(setpoint−gyro)) 机动帧 | 六轮恒 1.45 → 证明 3~6 轮滑块改动未生效的关键证据 |
| `bb_throttle.mjs` | 油门分桶：高/低油门帧占比、响应增益比、jitter 比、突变帧计数 | AG 场景计数（六轮全 0 → AG 盲区） |
| `bb_stats.mjs` | 多 Session 逐条扫描（时长/杆量峰值/大窗口数） | 定位 Session 数据错位问题的工具 |

## 依赖准备

脚本 import `/tmp/blv_src/flightlog_parser.js`（Blackbox Log Viewer 3.7.0 的 JS 解码器副本）。
`/tmp` 会被系统清理，重建方法：

```bash
cp -r ~/Downloads/blackbox-log-viewer-3.7.0/src /tmp/blv_src
# ES模块补扩展名
perl -pi -e "s/(from\s+['\"])(\.\/[\w\/-]+?)(['\"])/\$1\$2.js\$3/g; s|import ['\"]\./(\w+)['\"]|import './\$1.js'|g" /tmp/blv_src/*.js
```

jQuery/semver 全局桩已内置于各脚本开头（tools.js 顶层依赖 jQuery）。

## 运行

```bash
node /tmp/blv_src 依赖就绪后:
node bb_tpa.mjs            # 六轮 TPA 画像
node bb_kp.mjs             # 等效P增益跨轮对比
node bb_throttle.mjs       # 油门分桶
node bb_rounds.mjs         # 稳态PID对比(方法学反例)
node bb_stats.mjs "文件.bbl" [session号]  # 单文件逐Session扫描
```

## 核心判据（v1，单案例待校准）

- TPA 病灶线：高油门段 30~150Hz 能量占比 >15% → TPA 不足
- 机械问题：150~300Hz 集中 → 调 TPA 无用
- AG 前置：|Δ油门(100ms)|>120PWM 突变帧 =0 → AG 不可诊断
- 等效 P 增益：axisP/(setpoint−gyro) 机动帧中位数，跨轮比值=实际增益比

## 本次六轮结论（2026-10-19）

高油门 30~150Hz 仅 1.0~1.4%（远低于 15%）→ **TPA 保持现状**；
150Hz+ 近零 → 机械干净；突变帧全 0 → **AG 盲区需专门科目**（猛推收油×5）。
等效P增益恒 1.45 → 证明 3~6 轮 CLI 粘贴滑块未触发 PID 重算（四轮白飞）。
