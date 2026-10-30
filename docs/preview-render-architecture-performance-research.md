# 预览渲染模块边界与性能优化调研

> 日期：2026-10-30。范围：`Sources/MEditor/Resources/Preview/scripts/render.js`、
> `scripts/render/` 及其与 `bridge.js` 的交界。本文是调研与实施候选方案，不代表已经落地。
> 既有全局性能方案见 `docs/performance-plan.md`；本文只深入拆分后的预览渲染模块。

## 0. 结论摘要

当前拆分后的依赖方向基本合理：**解析与分块不依赖 DOM，DOM patch 不依赖 marked，
公开入口只负责组合**。下一步不应继续按行数拆文件，也不应优先换解析器或引入打包器。
真正剩余的收益集中在三处：

1. **编辑后仍有多次全文扫描和全 DOM 查询**：分块缓存只省掉 marked + DOMPurify，
   标题、代码、图片、公式和 bridge 元数据仍可能按全文收费。
2. **复合列表组每帧重建**：6000 项列表已切成 50 项左右的稳定块，但合并后的 key/HTML
   仍逐帧重新生成，热编辑尚未达到块级缓存的理论成本。
3. **异步生命周期缺少统一代际**：Mermaid 观察器、晚到的 Promise、高亮 idle 队列各自管理。
   这里首先是旧结果覆盖新文档和内存保留风险，其次才是耗时问题。

推荐顺序：**补异步正确性与相位测量 → 限定增强范围 + 列表结构共享 → 复用源码结构 →
再评估变更区间输入或首屏虚拟化**。每个候选方案单独落地、单独基准，不做“大改一把梭”。

## 0.1 实施结果（2026-10-31）

已落地：Mermaid 单观察器与代际、图源码指纹（修复相同占位 HTML 引发的 no-op 误跳过）、
列表类型复用、普通文本首字符快路径、两组块缓存、标题单次扫描与无标题快路径、无代码/图片
增强快路径、未变 DOM 范围对象复用。列表上限经 20/50/100/200 项实测选择 100 项。

最终三轮 hotEdit 中位数：段落 8.3ms、松散列表 13.3ms、标题 4.2ms、混合 4.3ms；
列表 hotNoop 中位数 5.3ms。独立基线 worktree 的同阶段列表 hotEdit 为 24.3ms。
负载波动明显，数字只用于量级判断。

以下实验没有保留：复合列表 HTML 延迟拼接、上一轮复合组 Map 复用（未改善且增加普通文档成本）、
首帧按组构建 DOM（混合冷启动明显变差）。这些结果说明后续优化必须继续逐相位 A/B，
不能把“减少字符串拼接”直接等同于端到端收益。

## 1. 当前事实与基准

### 1.1 已有正确性基础

拆分后完整套件为 **1842 项测试通过、0 失败**；iOS Simulator 编译与仓库守卫通过。
本次新增 6 项测试，覆盖此前没有直接守卫的边界：

- 数学：代码/价格不误识别，真实 KaTeX 渲染，整树 diff 保留已渲染节点；
- 状态：256KB 单块拒绝、4MB 总预算、FIFO 淘汰；
- Markdown：主预览移除 script、事件属性和 `javascript:` URL，保留本地 asset scheme；
- 增强：绝对路径编码与不改写相对/远程 URL，围栏内标题不进入源码行映射。

对缓存写入、数学归一化、消毒和资源改写做过反向验证，四项均会变红。

### 1.2 最新同机热路径读数

`MEDITOR_PREVIEW_BENCH=1 ./scripts/test.sh --filter PreviewRenderBenchTests`：

| 语料 | 源码规模 | hotEdit | hotNoop |
|---|---:|---:|---:|
| 段落×3000 | 849KB | 8.9ms | 6.6ms |
| 松散列表×6000 | 128KB | 16.3ms | 6.5ms |
| 标题×2000 | 22KB | 4.8ms | 2.1ms |
| 混合 | 114KB | 5.3ms | 3.9ms |

这些数字用于定位候选方向，不作为 CI 门槛。进程间受 JIT、GC 和负载影响，后续对比应
同机同轮、至少三轮取中位数。操作计数继续走 `renderStats`，不拿 wall time 做普通单测断言。

**解释限制**：`hotNoop` 直接反复调用 `renderInto`，仍要提取、切块和比较；真实 App 的
`bridge.update` 对相同 revision 已在入口 O(1) 返回。因此不能把 hotNoop 直接当作用户
每次输入的必经成本，也不应把它列为第一优化对象。

## 2. 模块职责与允许依赖

| 模块 | 应拥有 | 不应拥有 | 允许依赖 |
|---|---|---|---|
| `render/state.js` | 块缓存、缓存预算、渲染计数、上一轮 no-op 状态 | DOM 范围、marked 规则、图表状态 | 无 |
| `render/markdown.js` | marked 快路径、围栏共用判据、整篇解析、表格修正、DOMPurify | 块缓存、DOM、异步图表 | `state` |
| `render/blocks.js` | 安全切块、语义边界合并、列表复合组、块级解析出口 | DOM 节点、标题/图片后处理 | `state`、`markdown` |
| `render/math.js` | 数学提取、KaTeX 渲染、数学 DOM 归一化 | Markdown 切块、Mermaid 状态 | 浏览器 DOM、KaTeX |
| `render/mermaid.js` | Mermaid 围栏提取、加载、观察器、主题与导出前渲染 | 通用 Markdown 解析、其他增强 | 浏览器 DOM、Mermaid |
| `render/dom-patch.js` | 组范围记录、块对齐 patch、全树 diff、表格包裹 | marked、缓存、源文档扫描 | `state`、`math.normalizedHTML` |
| `render/enhancements.js` | 标题行/id、代码高亮与 Copy、资源 URL | 块缓存、图表加载、no-op 状态 | 浏览器 DOM、hljs |
| `render.js` | 主流程组合、no-op 判定、公开 `MEditorRender` API | 具体解析/patch 算法 | 上述模块 |
| `bridge.js` | Swift 协议、revision、快照 LRU、滚动/TOC、导出 HTML | 块缓存与 marked 内部规则 | 公开 `MEditorRender` |

### 2.1 边界评价

- `MEditorRenderCore` 是**内部装配 namespace**，不是对 Swift 或插件的新公开协议。
  测试可以直接观察它，但外部消费方仍只能使用 `MEditorRender`。
- `state` 共享计数是合理的观测需求，不应继续长成“什么都往里放”的 service locator。
  特别是 `lastGroupPatch` 留在 DOM 模块是正确的。
- `math.normalizedHTML` 是 DOM patch 的合法窄端口；不应让 DOM 模块反向了解 KaTeX 渲染细节。
- `blocks` 输出的 `{ key, html }` 是当前最重要的内部契约。后续优化应扩展其元数据，
  而不是让 DOM 层重新解析 Markdown 来猜边界。
- Quick Look 的 DOM-less `ql-render.js` 继续保持独立；当前没有证据证明统一两条管线
  能降低维护成本，强行复用浏览器模块反而会破坏 Quick Look 约束。

### 2.2 需要先收口的交界

1. **patch 结果太薄**：`patchDOMGroups` 只返回 Bool。调用方知道“成功了”，却不知道
   哪些新节点被替换，于是所有增强仍只能对 `targetEl` 全量查询。
2. **源文档结构重复推导**：blocks、Markdown 预处理和标题行映射分别扫源文本。
   应逐步形成单 revision 的 `SourceStructure`，但不能为省扫描而共用不兼容的围栏规则。
3. **缓存预算口径不一致**：`state` 注释写“源码字节”，实现实际使用 JS `String.length`
   （UTF-16 code units），bridge 快照则显式 `length * 2`。调预算前应先统一命名和估算口径，
   否则中文文档与英文文档的内存结论不可比。
4. **异步代际缺失**：见下一节，先于进一步性能压榨处理。

## 3. 异步生命周期：正确性优先项

### 3.1 Mermaid 观察器与晚到渲染

`renderMermaidDiagrams` 每次创建局部 `IntersectionObserver`，没有显式 disconnect；
`renderOneMermaid` 在 Promise resolve 后按 id 查当前 DOM。由此有两个待验证风险：

- 被替换/删除的旧节点仍可能被旧观察器及闭包保留，频繁编辑图表文档时积累内存；
- 文档 A 的晚到渲染可能在新文档 B 中找到同 id 占位，写入 A 的旧 SVG。

**方案**：模块内持有唯一 observer 与 `generation`；每轮 render/restore 先断开旧观察器并
递增代际，异步回调捕获代际，只允许在代际一致且占位仍属于当前文档时写 DOM。
`renderAllDiagrams` 也必须遵守同一规则。先补“旧 Promise 不得覆盖新文档”和“重复更新
只保留当前观察器”测试，再测量堆保留，不能直接把 disconnect 当性能银弹。

### 3.2 高亮 idle 队列

高亮按批持有待处理节点。节点被 patch 替换后继续高亮 detached node 通常无害，但会保留
旧树并浪费工作。可加入 render generation，在批次执行前跳过非当前节点；是否值得做取决于
长文档连续编辑时的堆与 idle 时间测量，优先级低于 Mermaid。

## 4. 性能候选方案（按落地顺序）

### P0：先获得相位数据，不预设瓶颈

现有计数能证明“有没有走缓存”，不能回答剩余 16ms 分在哪。建议只在基准/诊断模式增加：

- `extractMermaid` / `extractMath`；
- `splitBlocks + mergeUnsafeBoundaries`；
- 块 parse + sanitize（命中/未命中分开）；
- `joinListGroups + joinGroupHTML`；
- DOM patch；
- headings / highlight / math / asset 各增强 pass；
- bridge 的 content key、metadata refresh、idle snapshot。

生产默认不逐相位 `performance.now()`，避免为测量本身增加每帧成本。基准同时记录
JS 堆或 WebContent 进程内存趋势；只看耗时无法判断缓存和异步保留是否改善。

**出口**：一张“语料 × 相位 × 内存”的表。后续 P1 项必须据此排序，而不是凭函数长度排序。

### P1-A：让增强只处理变化范围

**现状**：块对齐 patch 已保留未变节点，但 `highlightCodeBlocks`、`rewriteAbsoluteAssetPaths`
仍从根节点全量 `querySelectorAll`；数学也逐项 `getElementById`。这与已省下的 DOM diff
成本不匹配。

**方案**：把 patch 结果从 Bool 扩展为 `{ applied, start, end, insertedNodes }`，或提供只读
changed range。块对齐成功时只对插入节点做高亮、资源改写和数学渲染；全量替换/全树 diff
仍走全量 pass。标题 id 因跨块重名去重，第一版继续全局处理，不塞进本项。

**风险**：中。必须覆盖变化组内的嵌套代码/行内公式、表格包裹、缓存恢复和 full fallback。

**验证**：新增 `highlightScanned` / `assetScanned` 计数；断言改一段不扫描其他代码块和图片。
基准重点看混合文档与多公式文档，不只段落语料。

### P1-B：列表复合组结构共享与延迟拼接

**现状**：50 项分块解决了一个大列表整体重 parse 的问题，但 `joinListGroups` 每帧仍把
所有复合组的 key 和 HTML 重新拼出。6000 项列表 hotEdit 16.3ms，明显高于其他中小语料。

**方案**：

- 复合组内部保留 `keyParts` / `bodyParts`，避免反复 `previousGroup.key += ...`；
- 只有需要比较、patch 或整篇输出时才 flatten；
- 以上一轮块 key 为身份复用未变复合组的 joined key/HTML，变化组才重建；
- 保持当前“渲染与 DOM patch 消费同一组结构”的不变量。

**风险**：中。结构共享最容易误把旧 HTML 带给新源码，必须有代际或原文 key 校验。

**验证**：120 项列表仍是 1 个 `<ol>`、120 个 `<li>`；编辑只 parse 对应块；增加复合组
join 次数/字符数计数。候选目标是把列表热编辑压到 10ms 量级，**不是未测先承诺个位数**。

### P1-C：Mermaid 单观察器与代际取消

按 §3 落地。它首先是正确性和内存方案，若基准没有图表文档，不应声称能改善普通编辑帧率。
新增多图连续编辑与快速切文档语料，记录观察器数量、晚到写回次数和堆趋势。

### P2-A：单 revision 的 SourceStructure

**现状**：`splitBlocks`、`padStructureLines`、`collectHeadingLines` 等按各自需求扫源文本。
不同路径对围栏和容器有不同语义，不能简单用一个正则替代全部。

**方案**：在每次内容 revision 开始时生成一次只读结构：行边界、顶层围栏区间、标题行、
安全块边界。Markdown、blocks 和标题增强按需消费；引用定义与缩进围栏仍保留保守回退。

**风险**：中高。这里曾出现“分块与整篇不等价”和“代码内容被补空行”的真实回归，
必须逐条复用 `PreviewRenderEquivalenceTests` 的对抗语料，而不是只测普通标题。

**前置**：P0 证明源扫描确实占显著比例后再做；否则保留简单实现。

### P2-B：bridge 元数据增量刷新

`refreshDocumentCaches` / TOC 与源码锚点不应在每轮编辑都重新查询整棵 DOM。可利用 blocks
和 patch 的范围元数据，仅更新受影响标题；源行号随编辑 delta 平移。缓存恢复继续走现有
rehydrate 全量路径。

这项与 SourceStructure 共用数据，单独做一套“JS 侧行偏移表”不值得。TOC 发送仍按签名去重。

### P3-A：变更区间输入，消灭重复全文预处理

目前 Swift 每次把完整 Markdown 交给 JS，JS 再做 key、提取、切块和比较。理论上的进一步
极限是把编辑器已知的 `{ revision, changedRange, replacement }` 传到预览，仅重算受影响块。

**收益上限**：把普通单点编辑从 O(全文扫描) 降为 O(变更区 + 块对齐)，大文档收益最大。

**代价**：需要维护 JS 源文档镜像、跨块语义扩张、undo/程序化替换/Agent 写回、文档切换与
缓存恢复的统一协议。任何镜像失配都会显示错误文档。必须保留全文 render 作为校验与回退，
先离线对拍，再灰度接入。没有 P0/P1 数据前不建议启动。

### P3-B：首屏虚拟化

冷渲染的大头 historically 是 DOM 插入和布局，视口外占位有数量级潜力。但滚动同步、TOC、
查找、导出 `getRenderedHTML`、Mermaid/KaTeX 懒渲染都依赖完整 DOM。必须定义“导出前完整
实体化”和测量占位高度的方案，独立专项评估，不与热编辑优化混合。

## 5. 不建议当前投入的方向

- **换 marked / 引入 WASM 解析器**：热路径 parse 已被块缓存大幅压缩，冷路径 parse 也不是
  唯一大头；替换还会重写 CommonMark 边界与 patched marked 的性能守卫。
- **Worker 化整条渲染**：DOMPurify 和 DOM patch 需要 DOM，源码/HTML 序列化与代际协议会
  吃掉收益。只有 P0 证明纯 parse 仍占主导时，才考虑评估纯解析 Worker。
- **为减少文件数引入 bundler/ES Module**：当前普通 script 已满足 macOS、iOS、CSP 和测试
  加载，拆分后的额外本地脚本开销不是已知瓶颈。
- **盲目增大缓存**：块缓存与 bridge 快照都受内存和 GC 约束，先统一预算口径并测堆。
- **优先优化直接 `renderInto` 的 hotNoop**：真实 bridge 对同 revision 已 O(1)，先优化真实编辑。
- **把围栏判断合并成一个“万能正则”**：Mermaid、分块、标题和数学的上下文要求不同；
  可以共享扫描结果，不能牺牲各自语义。

## 6. 测试与基准扩展建议

### 6.1 必补行为用例

- Mermaid：旧 Promise 晚到不得覆盖新文档；重复更新断开旧观察器；导出等待只等当前代际。
- 增强范围：只处理插入节点，嵌套代码/行内公式/表格不遗漏，full fallback 仍完整处理。
- 列表结构共享：首尾编辑、跨 50 项边界插入、混合列表、列表转段落、重复原文组。
- SourceStructure：沿用现有对抗语料，并补 `~~~`、四反引号、缩进容器和未闭合围栏。
- 缓存预算：中英文长字符串分别记录估算口径，避免“字节”名义下实际按字符调参。

### 6.2 基准语料

现有四类保留，新增：

- 200 个代码块 + 100 张本地图片，验证增强范围；
- 200 个行内公式 + 50 个块级公式，验证数学扫描和重渲染；
- 50 张 Mermaid 图连续编辑/快速切文档，验证代际和内存；
- 1MB 单点编辑，比较全文输入与变更区间输入（仅 P3 原型）。

每项至少三轮中位数，记录 hotEdit、真实 bridge 路径、冷渲染和 WebContent 内存趋势。
CI 继续用操作计数和结构断言，wall time 只做本机同轮对比。

## 7. 推荐实施批次与验收

| 批次 | 内容 | 主要验收 |
|---|---|---|
| 0 | Mermaid 代际与观察器、相位/内存测量 | 旧结果零写回；获得相位表 |
| 1 | 增强范围限定、列表结构共享（分 PR） | 扫描/拼接计数下降；现有测试全绿；列表向 10ms 量级靠近 |
| 2 | SourceStructure、bridge 元数据增量 | 出口等价；源扫描次数下降；混合/大文档有实测收益 |
| 3 | 变更区间输入原型 | 全文对拍一致；失配可回退；1MB 单点编辑显著收益 |
| 4 | 首屏虚拟化独立专项 | 冷渲染改善且滚动/查找/导出语义无回退 |

**停止条件**：若 P0 显示某相位占比很小，或 P1 的同轮收益落入基准噪声（约 ±10–15%），
就不进入对应的复杂结构改造。性能“极致”在这里应理解为接近真实瓶颈的成本下限，
不是用更多状态和更隐晦的代际换取基准数字。
