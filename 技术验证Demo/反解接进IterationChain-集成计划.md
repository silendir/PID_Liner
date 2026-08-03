# 反解接进 IterationChain — 集成短期计划

> **起草日期**:2026-08-03
> **分支**:`pid-Fback`
> **状态**:待 review / 待启动
> **依赖文档**:`技术验证Demo/怪象3.5寸1505新飞机反解验证分析.md`(反解参数+陷阱表)、项目记忆 `reverse-solve-current-state.md` 2m、`iteration-closure-strategy.md`
> **目的**:把已验证的反解能力接进 IterationChain,跑通"导入BBL→反解P→出CLI→换参飞→导入下一轮→曲线对比"端到端产品闭环。

---

## 一、为什么是当前最高优先级

- **方向已验证**:2m 怪象3.5寸1505 新飞机,飞手升P(45→49)反解识别为最高 → 迭代闭环"方向正确性"在真实数据上数学成立。
- **精度够用**:FF=0 干净数据 S2/S4 平均 **2.55%**(优于 2g 吴bbl 8.9%)。
- **单次反解再打磨是边际收益**;真正能验证产品形态的是端到端跑通链路。
- **核心算法零风险**:反解器、质量门、CLI 生成、IterationChain 存储**全部已就绪**,本任务本质是**拼胶水**。

---

## 二、难度评估(诚实)

**整体:中等偏低**。算法已验证,主要工作量在 UX 编排 + 飞机档案,不在算法。

| 新代码 | 难度 | 量 |
|---|---|---|
| 4 个 helper 从测试目标搬到生产(2l 沉淀的) | 低,机械搬运 | ~150 行 |
| 飞机档案 K(`craftName → K_plant`)+ 预标定向导 UX | 中,无现成参考 | ~200 行 + 1 个简单 VC |
| 反解→CLI→IterationChain 编排 | 低,调用拼接 | ~80 行 |

---

## 三、⚠️ 三个出错点(确定会踩 / 设计选择)

| # | 出错点 | 性质 | 对策 |
|---|---|---|---|
| 1 | **入口隔离两条路径**(`isIterationMode=NO` 历史页独立分析 / `=YES` 迭代导入)| 项目硬约束,易只测一条 | 入口矩阵(见 §五)两条路径都要验证 |
| 2 | **helper 搬家踩路径坑** | 2l 笔记:测试侧 fork 时 CSV 在 sandbox tmp,搬到生产后 `BlackboxDecoder` CSV 落点会变,可能 nil | 搬家后立刻跑"零回归"测试,确认 CSV 落点 |
| 3 | **预标定向导 UX**(飞手第一次怎么扫 K、扫完存哪)| 设计选择题,易过度设计 | 先做最简版(见 §六三选一) |

---

## 四、待搬家的 4 个 helper(2l 沉淀,目前在 `RealBBLClosureTests.m`)

| helper | 作用 | 搬家注意 |
|---|---|---|
| `decodeBBLSessionToCSVData:sessionIndex:` | 解指定 session → PIDCSVData(copy+clean+decode+parse 自给自足)| CSV 落点路径(#2 坑) |
| `normalizedCurveFromCSVData:outSampleRate:` | PIDCSVData → 归一化曲线(稳态=1, windowSize=8000)| responseDuration=0.5 固定,反解 duration 必须对齐 |
| `normalizedRollStepCurveFromBBL:sessionIndex:outSampleRate:` | 指定 session 直接出曲线 | 复用上两个 |
| `filterFromBBLHeader:outDMin:outDGain:` | header → BFFilterConfig(真实 gyro/dterm 截止 + d_min)| 各 bbl 滤波不同,**不复用 001 标定的 150/150/120** |

---

## 五、入口矩阵(必跑两条路径)

| 入口 | `isIterationMode` | 加载链历史 | 保存到链 | 反解行为 |
|---|---|---|---|---|
| 历史页 → PID 分析 | `NO` | 否 | 否 | 独立分析(单次反解展示,不进链) |
| 分析页 → 导入下一轮返参 | `YES` | 是 | 是 | 迭代模式(反解P→CLI→存链节点) |

🔑 **集成验收硬指标**:两条入口都跑通,行为符合上表。

---

## 六、K 预标定向导 UX(三选一,待定)

#27 K欠定 → 飞手第一飞不知 bestK。最小可行解:**每架飞机预标定一次 K**,存飞机档案(craftName → K_plant)。2m 已证 K-P 无耦合、K 是稳定机械常数。

| 方案 | 流程 | 优缺 |
|---|---|---|
| **A 预标定向导(推荐起步)** | 新飞机首次导入 → 引导飞一段已知 PID 数据 → 自动扫 K → 存档案 | 最贴合产品,但要多写一个 VC |
| B 尺寸/电机 KV 档位表 | 3.5寸/1505 → K=80 查表 | 最省事,但档位表要积累,初期不全 |
| C 手动输入 K | 用户自己扫好填 | 最懒,体验差 |

🔑 **建议 A 起步**(可降级到 B 兜底)。预标定一次后,该飞机后续所有迭代轮次复用档案 K。

---

## 七、测试策略(复用 2m/2l 资产,不从零写)

| 测试 | 复用 | 新增 |
|---|---|---|
| 搬家零回归 | 2m 的 `testReverse_Guai35_*` 三个方法断言 | helper 搬生产后重跑,行为不变 |
| 入口隔离 | — | 历史页 / 迭代导入 两条路径各一个集成测试 |
| 端到端 | 2m 的反解链路 | 反解P → CLI → IterationChain 节点落盘 → 读回校验 |
| 质量门 | 2l 的 btfl_all16(RMSE 0.70 垃圾数据)| 落成生产侧 guard,曲线点<200 拒 |

🔑 项目 `PIDAnalysis/Testing/PIDAlgorithmVerifier` 是回归保险,改信号处理/诊断逻辑后应跑。

---

## 八、集成步骤(建议顺序)

1. **搬家**:4 helper 从 `RealBBLClosureTests.m` → 生产层(`PIDAnalysis/Core/` 或新建 `Reverse/`)。立即跑零回归。
2. **质量门落生产**:stackResponse 点数<200 拒(2l 教训)。
3. **飞机档案模型**:`AircraftProfile`(craftName → K_plant),存储 `Documents/AircraftProfiles/{craftName}.json`(参照 IterationChain.json 模式)。
4. **预标定向导(方案A)**:新飞机首次导入 → 扫 K → 存档案。先做最简版。
5. **反解→CLI→IterationChain 编排**:每轮节点存反解P + CLI + 时间戳。
6. **入口隔离两条路径**:历史页 / 迭代导入 各走一遍。
7. **端到端集成测试**:怪象3.5寸 4 session 真实数据跑一遍迭代链。

---

## 九、不在本计划内(后置)

- **#26 FF=120 建模偏差**:方向已对不急,集成后用真实 FF=120 数据修更有依据。
- **#27 K 数学深挖**:预标定兜底方案已现,深挖是学术债。
- **S3 振荡建模**:forward 改造工程量大,进阶优化。

---

## 十、对话备份

本计划讨论的完整对话已备份:`技术验证Demo/对话备份-20260803-反解集成讨论.jsonl`(19.1M,原始 JSONL 无遗漏)。
