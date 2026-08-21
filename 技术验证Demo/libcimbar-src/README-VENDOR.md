# libcimbar 源码（vendored，构建输入）

> 用途：编译 iOS decoder xcframework（`CimbarDecoder`），供 App 扫码接收 BBL。
> 本目录是**上游源码的完整拷贝**（未修改，MPL 2.0 合规前提），不是参考代码。

## 来源

| 项 | 值 |
|---|---|
| 上游 | https://github.com/sz3/libcimbar |
| commit | `c509e0bb142bfd20e22583fb96f520e8083f3fba`（2026-08-16，vcpkg.json 版本 0.6.7c） |
| samples | https://github.com/sz3/cimbar-samples（v0.6 分支，浅克隆，golden 测试数据） |
| License | MPL 2.0（见 `LICENSE`）——**不改本目录任何源文件**，改动会使该文件产生开源义务 |

## iOS 构建入口

顶层 `CMakeLists.txt` 是上游原版（含桌面工具/gui/wasm 分支，iOS 构建不用它）。
iOS 交叉编译用独立构建脚本/工具链（见仓库根 `抖二维码传输计划.md` §7/§8），只编这些库：

- `src/lib/`：extractor、cimb_translator、fountain、compression、encoder（含 DecoderPlus 高层API）、bit_file、chromatic_adaptation、image_hash、serialize、util
- `src/third_party_lib/`：wirehair、zstd、libcorrect、base91、intx、libpopcnt（全部树内自带，无外部依赖）
- 不编：gui、cimbar_js、src/exe/*（桌面 CLI）、cxxopts

外部依赖仅 **OpenCV**，自编裁剪版：`BUILD_LIST=core,imgproc,imgcodecs`（源码查证 libcimbar 仅用这些模块，见计划文档 §7.2）。

## samples/ 目录

上游测试经 `LIBCIMBAR_PROJECT_ROOT/samples/` 定位测试帧（`test/TestHelpers.h::getSample`），
R1c golden 单测依赖它。体积 ~12MB，仅测试用，不参与 App 构建。

## 注意

- 🔴 任何对上游源码的修改（哪怕是 bug fix）都会触发 MPL 2.0 文件级开源义务——需要改动时先在构建层包壳解决，实在不行再评估。
- 升级上游 = 重新拷贝 + 更新本表 commit。
