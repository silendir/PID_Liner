# sz3/libcimbar 调研报告

> 调研日期：2026-08-20
> 用途：评估将 libcimbar 用于「屏幕 ↔ 摄像头」光学数据传输 App（iOS 优先）的可行性
> 仓库：<https://github.com/sz3/libcimbar>

---

## 1. 项目概要

| 项 | 内容 |
|---|---|
| 名称 | libcimbar (Color Icon Matrix Barcodes，彩色图标矩阵条码) |
| 作者 | sz3 |
| 语言 | C++17 |
| License | **MPL 2.0**（⚠️ 不是 MIT，见 §5 商用分析） |
| Stars | ~6.3k+（HN/Reddit 病毒式传播后，长期是该领域第一） |
| 维护状态 | ✅ 活跃维护 |
| 定位 | 气隙（air-gapped）环境下，用「一块屏幕 + 一个摄像头」单向传文件的生产级库 |

**一句话**：不依赖 WiFi/蓝牙/USB/网络，屏幕循环播放彩色条码动画，另一设备的摄像头拍摄解码，实测维持 **~850 kbit/s（约 106 KB/s）**，支持 **100+ MB** 文件。是这个赛道速度最快、星最多、维护最好的开源实现。

---

## 2. 技术原理

### 2.1 编码格式（为什么比二维码快 10 倍）

- 数据编码为 **图标网格**：每个格子 16 种符号 × 8 种颜色 = **128 种组合/格**
  - 相比 QR 码：信息密度大幅提升（QR 每模块只有 1 bit 黑白）
- 自研格式，**不兼容标准二维码扫码器**（收发两端都必须用本库）

### 2.2 传输协议栈

```
文件
 ├─ zstd 压缩            （体积瘦身）
 ├─ wirehair 喷泉码       （前向纠错：丢帧/坏帧可恢复，无需重传协商）
 └─ cimbar 帧序列         （彩色图标矩阵动画）
     ↓ 屏幕循环刷新 → 摄像头采集 → 解码
```

- **喷泉码是关键**：单向广播式传输，接收端收到"足够多"的帧即可还原，天然适合摄像头丢帧/模糊/乱序的现实环境
- 单向通道：发送端不需要任何反馈（这是速度和实现简洁性的来源，也是固有限制——无重传协商）

### 2.3 依赖

- OpenCV（图像处理/解码核心依赖）
- CMake 构建
- 官方支持 Linux / macOS / Windows 编译

---

## 3. 性能

| 指标 | 数值 |
|---|---|
| 持续速度 | ~850 kbit/s ≈ **106 KB/s**（电脑显示器 + 手机摄像头） |
| 文件大小 | 100+ MB |
| 对比：动态二维码方案（txqr 等） | ~10 KB/s 级别，**慢 10 倍以上** |
| 对比：纯原生 QR（CIFilter 生成 + AVFoundation 扫码） | ~2-5 KB/s，仅够传文本/密钥 |

速度假设：摄像头稳定采集（30fps 可跑，60fps 更佳），帧率不稳会直接打折。

---

## 4. 生态

| 仓库 | 说明 | License |
|---|---|---|
| [sz3/cimbar](https://github.com/sz3/cimbar) | 最初的概念验证（PoC），格式设计文档在此 | — |
| [sz3/libcimbar](https://github.com/sz3/libcimbar) | **优化后的正式实现**，编码器+解码器+协议 | MPL 2.0 |
| [sz3/cfc](https://github.com/sz3/cfc) | "Copy File Camera" —— Android 演示 App（摄像头接收端），是移植其他平台的**最佳参考实现** | MIT |

- cfc 是原生 Android（Kotlin UI + JNI 调 C++ 核心），验证了「移动端集成」这条路是通的
- **官方没有 iOS 版**，需自行移植（见 §6）

---

## 5. 商用 License 分析（MPL 2.0）🔑

**MPL 2.0 是文件级弱 Copyleft**，对 App 商用总体友好：

- ✅ **可以商用、可以闭源你的 App 代码**
- ✅ 以未修改的库形式集成（静态/动态链接均可），只需在关于页/声明中注明使用了 libcimbar 及其 MPL 2.0 license
- ⚠️ **如果你修改了 libcimbar 的源文件，被修改的那些文件必须以 MPL 2.0 开源**（其余代码不受影响）
- ⚠️ 依赖的 license 混合：MIT / BSD / zlib / Boost / Apache（均为宽松协议，无传染风险）
- ⚠️ App Store 上架 MPL 2.0 代码：可行，常见做法（Firefox 系 iOS 组件先例），保留源码获取途径说明即可

**结论：可以放心用于商业 App；尽量「不改库源码、外壳封装」最省心。**

---

## 6. iOS App 开发可行性

### 6.1 结论：可行，核心 100% 复用，只需写 Swift 壳（预估 1-2 周）

```
┌─────────────────────────────────┐
│ libcimbar 核心 (C++17)          │  ← 跨平台复用，一行不改
│  - encode: 文件 → cimbar 帧序列  │
│  - decode: 视频帧 → 文件         │
├─────────────────────────────────┤
│ Android: Kotlin + Camera2 + JNI │  ← cfc 已有（参考实现）
│ iOS:     Swift + AVFoundation   │  ← 需自行开发
└─────────────────────────────────┘
```

### 6.2 移植工作分解

| 任务 | 工作量 | 要点 |
|---|---|---|
| CMake 交叉编译 → `.xcframework` | 2-3 天 | arm64 device + simulator 双 slice |
| 集成 OpenCV iOS framework | 1 天 | 官方预编译 opencv2.xcframework；⚠️ 完整包 ~200MB，上架前需裁剪（imgproc/core） |
| 接收端：AVFoundation 采集 | 2-3 天 | 参照 cfc 的 Camera2 参数逐项翻译（见 6.3） |
| 发送端：帧动画刷新 | 1-2 天 | `CADisplayLink` + `CAMetalLayer` 防撕裂（优于 UIImageView） |
| UI + 文件导入导出 | 2-3 天 | Files App、进度、配对引导 |

### 6.3 iOS 关键坑位 ⚠️

1. **相机帧率**：高速模式假设稳定高帧率采集。iPhone 需挑选 `AVCaptureDevice.Format` + 主动锁定，否则速度腰斩（30fps 稳定也有 ~50KB/s，仍远超二维码）
2. **对焦/曝光必须锁定**：`focusMode = .locked`、`exposureMode = .locked`，否则码糊掉解码失败（cfc 中有对应参数可对照）
3. **OpenCV 体积裁剪**：直接上架 200MB 会被用户骂，需自建裁剪版或用构建参数瘦身
4. **App 审核声明**：相机用途写明「本地解码处理，不上传任何数据」——这类气隙传输 App 反而是隐私加分项

### 6.4 Web 单页应用 + Cloudflare Worker/Pages 部署路线 🌐

**部署本质：cimbar 编解码全部是本地计算，零服务器逻辑 —— Worker/Pages 只当静态文件服务器**，免费额度绰绰有余，自动满足摄像头 API 的 HTTPS 强制要求，还可做成 PWA 离线可用（与气隙传输的产品气质契合）。

```
浏览器A(发送) ──屏幕闪码──> 摄像头 ──> 浏览器B(接收)
      └── 服务器只负责下发 HTML/JS/WASM，之后完全离线 ──┘
```

两条技术路线：

| 路线 | 做法 | 速度 | 工作量 |
|------|------|------|--------|
| **A. 标准 QR 动画** | 纯 JS：JS QR 库生成 + `BarcodeDetector` API 解码，零 WASM | ~2-10 KB/s | **1-2 天**，参考 [QRSync](https://github.com/huiihao/QRSync) / AirScan-QR（已是现成网页版） |
| **B. cimbar WASM 移植** | libcimbar 用 Emscripten 编成 WASM + OpenCV.js 解码 | 理论 ~50-100 KB/s | **2-4 周**，有硬坑 |

B 路线的三个硬坑：

1. **OpenCV.js 体积 ~8-10MB**：首屏加载重，需裁剪成仅 imgproc/core
2. **浏览器摄像头帧率不稳**：`getUserMedia` 在 iOS Safari 上拿稳定 30fps 都要调参（`frameRate` constraint、`ImageCapture`），速度比原生 App 再打折
3. **解码算力**：30fps 逐帧 WASM 解码，桌面浏览器 OK，低端手机浏览器可能掉帧雪崩

**建议节奏：先 A 后 B** —— Day 1 用 A 路线部署上 Worker 验证产品闭环（传文本/密钥场景 QR 速度够用）→ 有真实需求再投入 B 路线。B 的 WASM 产物将来可直接复用进 iOS App 的 WKWebView 内嵌页，一份投入两端用。

### 6.5 产品机会 💡

- **iOS ↔ Android 跨端互传**：cimbar 格式两边通用，cfc 用户可直接接 iOS 发出的码（差异化卖点）
- 气隙/安全场景：密钥分发、离线设备激活、无网络环境传文件
- 双向传输 = 两台设备交替收发（协议是单向的，双向靠应用层轮换）

---

## 7. 竞品对比（为什么选它）

| 项目 | Stars | 维护 | 速度 | 平台 | 结论 |
|---|---|---|---|---|---|
| **libcimbar** | ~6.3k+ | ✅ 活跃 | **106 KB/s** | C++ 全平台+Android 参考实现 | ✅ 首选 |
| [divan/txqr](https://github.com/divan/txqr) | ~2k | ❌ 停更 | ~10 KB/s | Go | 格式老、慢 10 倍 |
| [huiihao/QRSync](https://github.com/huiihao/QRSync) | 小 | ✅ 新 | 慢 | 纯浏览器 | 只适合 Web 玩具 |
| smyrgeorge/qrt | 小 | ⚠️ 实验性 | 中 | — | 学术探索 |
| ScreenFlicker / FlickerCam / FlickerModem | <150 | ❌ 停更 | 玩具级 | — | 不可用于生产 |

---

## 8. 快速验证路径（建议节奏）

1. **Day 1**：macOS 直接编译 libcimbar 自带 demo，跑通「电脑屏幕 ↔ 手机摄像头（用 cfc App 收）」全流程，直观感受速度和拍摄条件要求
2. **Day 2-3**：纯原生降级方案 Demo（CIFilter 生成 QR 动画 + AVFoundation 扫码），1 天验证 iOS 端 UI/相机链路
3. **Week 1-2**：交叉编译 xcframework + OpenCV 裁剪 + 集成，替换降级方案的核心
4. 上架前：License 声明页 + 相机隐私文案 + 体积检查

---

## 9. 总结

- ✅ 该领域**事实标准**：星最多、维护最好、速度最快（10 倍于二维码方案）
- ✅ **MPL 2.0 可商用**，不改库源码即无开源义务
- ✅ iOS 移植路径清晰：C++ 核心复用 + cfc 作参考，1-2 周可控
- ⚠️ 主要工程风险：OpenCV 裁剪、相机帧率/对焦锁定、发送端防撕裂
- ⚠️ 固有限制：单向传输、收发两端都必须装本格式实现（不兼容普通扫码器）

## 参考链接

- 主仓库：<https://github.com/sz3/libcimbar>
- 格式设计说明（PoC 仓库）：<https://github.com/sz3/cimbar>（`ABOUT.md`）
- Android 参考实现：<https://github.com/sz3/cfc>
- 演示视频：<https://www.youtube.com/watch?v=bR7L9DnxhEI>
- 第三方介绍博客：<https://gwliang.com/en/posts/cimbar-introduction/>
