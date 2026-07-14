# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

PID_Liner 是一款 iOS 应用（Objective-C / UIKit，最低 iOS 13），用于分析 BetaFlight / INAV 黑盒飞行记录（`.BBL`），诊断 PID 调参问题并生成 CLI 调参命令与下一轮推荐参数。整体设计参照 Python 版 PID-Analyzer，所有信号处理与诊断算法用 Objective-C 原生重写。

## 构建与运行

依赖通过 CocoaPods 管理（`PID_Liner/Podfile`：`AAChartKit` 图表、`SVProgressHUD`），**必须使用 workspace 而非 xcodeproj** 打开/构建：

```bash
# 首次或修改 Podfile 后
cd PID_Liner && pod install

# 命令行构建（模拟器）
xcodebuild -workspace PID_Liner/PID_Liner.xcworkspace -scheme PID_Liner \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

更推荐使用 **XcodeBuildMCP** 工具（见会话指令）：先 `session_show_defaults` 确认 scheme/simulator，再 `build_run_sim` 一键构建并启动。

## 关键架构

### 入口与导航
- `SceneDelegate.m` 是根：`ViewController`（主页面，BBL 解码与原始数据展示）嵌入 `UINavigationController`。
- `CSVHistoryViewController`：CSV 历史与迭代链管理（历史页 → PID 分析的入口隔离见下）。
- `CrashDiagnosisEngine`：独立的炸机诊断领域知识库（`分析文档/FPV 炸机诊断领域知识库.md`）。

### BlackboxDecoder 桥接层（C ↔ Objective-C）
`Libs/BlackboxDecoder.xcframework` 封装了 BF `blackbox-tools` 的 C 代码。`blackbox_bridge.h` 暴露 `extern "C"` 接口，**Objective-C 侧通过 `BlackboxDecoder.{h,m}` 调用**，不要直接调 C 函数：

- `blackbox_decode_to_csv(path, DecodeResult*)` / `blackbox_decode_to_csv_with_index(path, sessionIndex, result)`：解码 BBL → CSV（一个 BBL 可含多个 Session，按 index 取）。
- `blackbox_extract_metadata(path, BBLMetadata*)`：提取 `firmwareVersion`、`craftName`、`looptime`、`logRate`、字段列表 —— **固件版本与飞机名是后续 CLI 命名与迭代链路由的依据，必须先取**。
- C 侧分配的 `data` / `fieldNames` 必须用对应的 `blackbox_free_*` 释放。

### PID 分析 5 层管线（`PIDAnalysis/`）
管线在 `PIDAnalysisViewController.m` 编排，分层目录即处理顺序：

1. **Core**（特征提取）：`PIDCSVParser` 解析注入了元数据的 CSV（见下方"CSV 注入格式"）→ `PIDDataModels`（`PIDCSVData` 等，对应 Python 的 DataFrame）→ `PIDTraceAnalyzer` 计算时域/频域特征。
2. **SignalProcessing**：`PIDFFTProcessor`、`PIDGaussianFilter`、`PIDInterpolation`、`PIDWienerDeconvolution`（Wiener 反卷积恢复真实响应曲线）。
3. **Engine / PIDCurveDiagnostic**（诊断）：曲线特征 → 问题列表 → 评分。
4. **Engine / PIDRecommendationEngine**（推荐 + 预测曲线）：诊断 → 推荐新 PID 四参数（P/I/D/FF）+ 预测响应。
5. **Engine / PIDCLIGenerator**（CLI 生成）：推荐参数 → BF/INAV CLI 命令。

辅助 Engine：
- `BFSliderMapper`：BF Simplified Tuning（Slider）正/反向映射，参照 BF 源码 `simplified_tuning.c::calculateNewPidValues()`。
- `PIDTuningRecord`：迭代闭环调参的单轮快照数据模型。

### 迭代闭环调参系统（当前开发分支 `PID_20`）
以**迭代链 (IterationChain)** 为单位管理多轮调参，与"单次分析"完全隔离：

- 链存储：`Documents/IterationChains/{chainId}.json`；旧历史兼容路径 `Documents/PIDTuningHistory/{craftName}.json`。
- **入口隔离由 `isIterationMode` 控制**：
  - 历史页 → PID 分析：`isIterationMode = NO`，独立分析，**不加载链历史、不保存**。
  - 分析页 → "导入下一轮返参"：`isIterationMode = YES`，加载链历史、保存到链。
- 一个 BBL 含 N 个 Session → 批量创建 N 条独立迭代链；"导入下一轮"是单选 Session 追加到指定链。
- 首次 BBL→CSV 与迭代链导入**完全隔离**。

## BF 固件版本差异（CLI 命名易踩坑）

CLI 命令的轴/项命名依赖 `firmwareVersion`，详见项目记忆 `bf-cli-params.md`：

- P / I / FF 项：`{term}_{axis}` 格式（如 `p_roll`, `i_roll`, `f_roll`）。
- **D-term 因版本而异**：BF 4.3–4.5 用 `d_min_{axis}`；BF 2025+ 用 `d_{axis}`。改 CLI 生成时务必按版本分支。

## CSV 注入格式（BBL → CSV 时写入表头注释）

CSV 不是裸数据，首部带元数据注释，`PIDCSVParser` 依赖这些行：

```
# Craft name:XXX
# Flight time:XXX       (微秒)
# Firmware version:XXX
# PID roll:p,i,d,ff
# Motor KV:XXX
```

## 测试与算法验证

- `PID_LinerTests/`：XCTest target。
- `PIDAnalysis/Testing/PIDAlgorithmVerifier`：**将 iOS 实现与 Python 参考输出逐项比对**（响应曲线、频谱等），是算法改动的回归保险；改信号处理 / 诊断逻辑后应跑它。
- `PIDAnalysis/Testing/PIDEdgeCaseTester`：边界值用例（真实业务中出现的所有值类型，不只 happy path）。
- 单测命令：
  ```bash
  xcodebuild -workspace PID_Liner/PID_Liner.xcworkspace -scheme PID_Liner \
    -destination 'platform=iOS Simulator,name=iPhone 16' test
  ```

## 重要文档（根目录，非代码）

- `分析文档/`：PID 低角速度偏差分析、FPV 炸机诊断知识库。
- `BF Chirp AutoTune 技术重点.md`、`inav PID调参研究.md`、`INAV_pid_autotune源码.c`：跨固件调参算法参考资料。
- `AI进击计划.md`：产品与开发计划。

## 工程约定

- 全 Objective-C，**禁止 Swift 混编**（除桥接必要的 C）；C 桥接集中在 `blackbox_bridge.h` / `BlackboxDecoder.{h,m}`。
- 新增分析层组件遵循 5 层目录划分，引擎类保持"输入不可变模型 → 输出新模型"的纯函数风格。
- 涉及迭代链 / 历史持久化的改动，注意 `isIterationMode` 的两条入口路径都要验证。
