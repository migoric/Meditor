# MEditor 性能优化方案

> 拆分后预览模块的专项调研见 `docs/preview-render-architecture-performance-research.md`；
> 本文保留全局性能背景与历史数据。
>
> 2026-10-23 制定。所有结论经多轮实测（三套基准各 3 轮取中位数）或代码复核（论断带 文件:行号）。
> 基准工具在 `chore/preview-bench` / `chore/app-bench` 分支（**不进 main**）：
> node 侧纯 JS 基准 `bench_render.js`；XCTest 侧 `MEDITOR_BENCH=1`（Swift 路径）与
> `MEDITOR_PREVIEW_BENCH=1`（WKWebView 四相）。
> 行号引用会随代码漂移，引用前现场复核（见 AGENTS.md「读数会腐烂」）。

## 0. 方法与基准可信度

- 结论级数字稳定：文件树枚举 ±5%（20k 文件三轮 1481/1502/1546ms），renderInto 热路径
  41/44/43ms；进程间绝对值有 ±15% 抖动（JIT/GC/负载），所有数字按「中位数 + 量级」使用。
- 基准刻意不进 CI、不做断言：wall time 在 runner 上不稳定。回归门禁走操作计数
  （renderStats 模式），见 §5。

## 1. 瓶颈全景（实测 × 代码证据）

| 路径 | 实测（中位数） | 瓶颈定性 |
|---|---|---|
| 文件树整树枚举 `loadAll` | 20k 文件 1.5s（66μs/项） | Swift 侧唯一规模性问题；且一次外部变更触发 2~3 次整树重枚举（FileTreeManager / WorkspaceIndexService / Spotlight 各自为政） |
| 预览·冷渲染（885KB 文档） | parse 150 / sanitize 240 / innerHTML+布局 534ms | DOM 插入 > sanitize > parse；JS 模块不是最大头 |
| 预览·热更新（无可见变化） | 885KB 41ms / 2000 项列表 62-87ms | 块缓存只省了 parse+sanitize；下游 join 全文 → patchDOM 全量解析 → 每节点 ~6 趟 innerHTML 序列化，仍是 O(全文) |
| 编辑器·每击键 | 16MB ≈ 23ms | 行偏移表全量重建 O(n)；行号尺另维护一份且用慢 16.7× 的旧法（`Sources/MEditor/Views/Editor/LineNumberRulerView.swift:44`） |
| 编辑器·滚动回调 | 每滚动帧拷全串 | `Sources/MEditor/Views/Editor/EditorScrollSyncHandler.swift:20` 只为读长度 |
| 文件打开 / tab 切换 | 亚毫秒级（Swift 侧 `selectTab` ≈5μs） | Swift 侧无碍；**JS 侧另有链路**：切 tab 的缓存命中恢复走 `innerHTML` 全量替换且 scrollY 不归位——用户报告的「切 tab 抖」在这里，与吞吐量无关，属 UX 缺陷（另有专项在钉） |
| 启动 / 导出（PDF 以外） | — | 无碍（warmUp 已后台化；PDF 导出有 2 次多余整页重渲，见 §3.4） |

## 2. 文件树（唯一已实测落地的优化）

优化史要点（`git log --follow`）：#79 把两份列表的双枚举并为 `loadAll` 一次枚举；
#82 给排序做 name 预取（91.7→13.4ms / 4.5k 项）。**没做过的**：枚举器参数裁剪、
索引增量更新、FSEvents 路径级利用。

### 已实测（原型在 `chore/app-bench`，落地前需再过一轮 review）

三处纯裁剪，`Sources/MEditor/Services/File/FileService.swift`：

1. 删 `.localizedNameKey` 预取（全仓零消费方，每项白付一次资源 key 填充）；
2. `supportedExtensions` 提出 `loadImmediateChildren` 循环（该属性每次访问重建 Set）；
3. `loadAll` 只排一次序：`files` 从排好的 `items` 派生（比较器目录恒排前、同类按 name，
   过滤保持相对顺序，逐位一致），重新 new 实例隔离可变字段。

**实测：整树枚举 -41%（1502→888ms @20k），单目录展开 -80%（12.8→2.6ms @100 项）。**
FileService/FileTreeManager 33 条测试全绿。

### 待做（结构性）

4. **FSEvents 传路径、增量失效（2026-10-31 已落地）**：普通文件变化只重读对应索引项；
   目录/root/空路径保留全量回退。路径用 `realpath` 统一，删除目录连同后代索引移除。
   内容索引与 Spotlight 不再因每次文件保存各自枚举整树。
5. **三方枚举合一（已落地）**：打开工作区由组合根（AppState）分发一次 `scanWorkspace`
   产物，FileTree / WorkspaceIndexService / Spotlight 不再各自枚举。
6. QuickOpen 空查询分支复用 `indexedFiles` 的既有顺序，不再每次重排
   （`Sources/MEditor/Views/AppShell/QuickOpenSheet.swift` 每次击键 O(f log f)）。
7. 备选项（需产品决策）：`loadAll` 加 `.skipsHiddenFiles`——`.github` 等点目录会从
   树/索引中消失，且 `FileServiceTests` 有钉住现状的测试，改之前先改测试意图。

## 3. 预览管线（收益最大的一段）

核心洞察（`Sources/MEditor/Resources/Preview/scripts/render.js:1047-1115`）：patchDOM 的
diff 决策不贵，**为 diff 付出的序列化贵**——`temp.innerHTML = 全文` 每帧全量解析，
`nodesEqual` 每个顶层节点读 ~6 次 innerHTML（JSC 不缓存，每次全子树序列化）。

按落地顺序：

1. **no-op 短路 + 序列化降倍**：join 产物与上轮全等则跳过 patchDOM 及全部后续 pass；
   `nodesEqual` 的 innerHTML 各取一次存局部（6 趟→2 趟）。低风险，立竿见影。
   实现陷阱一：必须存**上轮的 join 产物**——存 DOM 的 innerHTML 是错的
   （Copy 按钮 / hljs span / KaTeX 结果污染，永远不等，短路永不触发）。
   实现陷阱二（2026-10-23 review 实测，已修）：这个变量是**整个 WKWebView 的 JS 上下文级
   状态**，而预览 webview 跨文档复用（切 tab 只换内容）。任何绕过 `renderInto` 直接改
   DOM 的路径（当前唯一一处：bridge 的缓存命中恢复 `contentEl.innerHTML = entry.html`）
   都必须调 `MEditorRender.invalidateLastRender()`，否则会停在**上一个文档**的产物上，
   之后切回未缓存文档时短路误判 no-op ⇒ **预览显示的是别的文件**。触发面不小：
   文档 >120KB 永不进缓存，或 `RENDER_CACHE_LIMIT=3` 被淘汰（开 4 个以上文件即可）。
   守卫：`PreviewStalePreviewTests`。
2. **块序号对齐 DOM 替代全树 diff**（最大单项）：`renderMarkdownCached` 已知哪些块变了，
   把变化信息透传到 DOM 层，按块下标定位 `#content` 顶层子区间做 replace/insert/delete；
   未变化块零解析零序列化。风险点：文首插入导致整体移位需块对齐（块原文是天然 key）、
   对齐单位是 mergeUnsafeBoundaries 合并后的组、table 包裹改变子节点结构。预期把
   「62ms 列表热更新」打到个位数毫秒。
   > 更正（2026-10-23 对拍复核）：PRE 节点**每帧必被替换**——Copy 按钮挂在 PRE 内，
   > `nodesEqual` 比 textContent 带上按钮文字导致永不相等（render.js `attachCopyButton`
   > + `nodesEqual` 的 PRE 分支）。重高亮是「节点没保住」的结果，不是「没加幂等守卫」；
   > 正确修法是比较时剥掉按钮（比 code 子节点），已由本方案配套的修复 PR 落地。
3. **小相位**：`extractMath` 加 `indexOf('$')` 快路径——量级纠偏：实测 420KB 上
   该正则仅 ~0.2ms，收益是「省分配」而非「省时间」，优先级最低；
   highlight 幂等（跳过已带 hljs class 的块——对 PRE 无效，因为 PRE 在更正前
   每帧被替换；真正的修复见上条）；
   splitBlocks / padStructureLines / collectHeadingLines 三处 `split('\n')` 融合成一次
   行扫描（顺带收口三套围栏判定，与 #95 的同源风险）。
4. **首屏虚拟化**（独立专项，不混入上面）：视口外块用估算高度占位。砍冷渲染
   innerHTML+布局的大头，但滚动同步 / TOC / 导出 `getRenderedHTML` 都假设全 DOM 已布局，
   风险最高。

### 明确不做

- 换 cmark-gfm 替代 marked：数据不支持——parse 只占冷渲染 ~19%，且块缓存已把它
  移出热路径。
- 压缩 sanitize 触发面里的「link 引用定义回退」：跨块状态是 CommonMark 语义，
  风险大于收益。

## 4. 编辑器主线程（大文件体验的总闸）

1. **行号尺共享调度器的行偏移表**（或把分块快扫移植过去）：消灭每击键第二次、
   且慢 16.7× 的全扫。低风险，纯删重。
2. **行偏移表增量维护**（按编辑 delta 平移编辑点之后的偏移）：16MB 下 23ms/击键
   降到 O(编辑点后)。这是「16MB 打开上限能不能上调」的前提——上限本身是合理防线，
   不修这条之前不放宽（放宽 = 把「明确拒绝」换成「打开后每敲一字掉帧」）。
   注意 5 个显式 rebuild 调用点都要改造，`rebuildCount` 测试断言同步更新。
3. 热路径消 `textView.string` 全串拷贝：长度判断改 `textStorage.length`，
   滚动回调尤其值得（每滚动帧都在拷）。

## 5. 其余模块

- **启动**：无碍。warmUp 文件 I/O 全在 `Task.detached`，主线程只建 WebView；
  恢复 tab 读盘已异步。可选：恢复 N 个 tab 的读盘并发限流（20 tab = 20 并发磁盘读）。
- **PDF 导出**：`PreviewExporter.captureViaReload` 劫持预览 webview 整页重渲、导出后
  再重渲恢复——挪到离屏/池化 webview 消掉第二次全量渲染和用户可见的闪烁；
  `inlineCSS`/`stripScripts` 移出主线程。P1。
- **全局搜索**：`WorkspaceIndexService.search` 每次查询都全量排序（提前退出在排序之后）——
  缓存排序键序，增删失效。低风险。
- **AppState / Managers**：未发现 O(n²)；`TabManager.openFile` 的 tab 去重扫描量级小，无碍。

## 6. 验证基建

patchDOM 相位目前零计数，无法断言「无变化更新 = 0 节点替换」。按 renderStats 的
既有模式补计数出口（并入 `getRenderStats()`）：`patchCompared / patchReplaced /
noopSkip / highlightApplied / blocksMounted`。每处优化落地时配一条计数断言，
沿用「产物正确性测不出性能回退，计数比值才能钉住」的测试哲学。

## 7. 落地顺序与状态

| 批 | 内容 | 预期收益 | 状态 |
|---|---|---|---|
| 1 | 文件树三刀 | 枚举 -41% / 展开 -80% | ✅ 已实测，在 `chore/app-bench` 待摘出落地 |
| 2 | 预览 no-op 短路 + 序列化降倍 → 块对齐 DOM | 热更新 O(全文) → O(块数) | 方案就绪 |
| 3 | 编辑器：行号尺删重 → 行偏移增量 | 每击键省一次 O(n) 慢扫；16MB 上限的前提 | ✅ 已落地（`perf/incremental-line-offsets`） |
| 4 | FSEvents 增量 / 三方枚举合一 / PDF 离屏 / 搜索排序缓存 | 结构性 | 方案就绪，单独 PR 逐个来 |
| 5 | 首屏虚拟化 | 冷渲染大头 | 独立专项，风险最高，最后做 |

## 附录：基准原始数据（2026-10-23，M 系列本机，中位数 ms）

> 对拍注记（2026-10-23，另一组独立复测）：**冷渲染与热更新不能用同一套数字讲**——
> 冷渲染的大头是 DOM 插入 + 布局（往空容器插数千节点触发完整样式匹配），
> 热路径的大头是序列化与全量 parse。「DOM 是冷路径最大头」与「热路径瓶颈在
> 序列化」各自成立，两段分开优化。另：`looseList2000` 语料的 `blocks=1`
> （mergeUnsafeBoundaries 把整个松散列表并成一组）——#88 只优化了合并的成本，
> 没优化合并的粒度，列表文档的块缓存实际不生效，是遗留项。

Swift 侧（`MEDITOR_BENCH=1`）：

| 路径 | 规模 | 耗时 |
|---|---|---:|
| 文件树整树枚举 | 1k / 5k / 20k 文件 | 75 / 319-377 / 1328-1546 |
| 单目录展开 | 100 项 | ~12（优化后 2.6） |
| 文件打开·读盘+解码 | 10KB / 511KB / 1MB / 15MB | 0.18 / 0.73 / 1.7 / 26 |
| tab 切换 | 20 tab 轮转 | 0.1（≈5μs/次） |

预览管线（WKWebView 四相，`MEDITOR_PREVIEW_BENCH=1`）：

| 语料 | parse | sanitize | innerHTML+布局 | renderInto 热路径 |
|---|---:|---:|---:|---:|
| 真实文档 ~13KB | ~2 | ~2 | ~10 | ~2 |
| CHANGELOG.md（56KB） | 9-14 | 8-11 | 30-56 | 4-5 |
| 标题×2000 outline（636KB） | 101-133 | 158-186 | 332-527 | 38-46 |
| 段落×3000（885KB） | 144-156 | 202-240 | 446-583 | 41-44 |
| 松散列表×2000（77KB） | 22-24 | 25-30 | 115-157 | 62-87 |
