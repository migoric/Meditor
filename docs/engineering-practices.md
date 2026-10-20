# 工程实践：单作者项目的质量保障

单作者 + 无人工 review 的现实约束下，质量保障靠下面几条自动化 / 制度化机制。
本文说明每条**是什么、为什么、怎么跑**。

> 代码层面的约定（分层、共享内核、Swift 6 并发、版本单源）见 [`AGENTS.md`](../AGENTS.md)；
> 人的流程（开分支、提 PR、发版）见 [`CONTRIBUTING.md`](../CONTRIBUTING.md)。
> 本文只讲**机制**，不重复那两处。

## 1. CI 硬性闸门（禁止直接推 main）

- branch protection 已开启（main，`enforce_admins` 也开着）：直接 push 会被拒绝，改动必须走 PR。
  核查命令：`gh api repos/migoric/Meditor/branches/main --jq .protected` → `true`。
  > 历史注记：仓库 2026-10-20 短暂转 private 期间，免费计划的保护接口直接 403、`protected` 变
  > `false`，那段时间**没有任何强制执行**。同日转回 public 后重建了规则。别拿旧结论当现状，
  > 判断这类事一律查 API。
- **必需检查**（分支保护里写死的名字）：
  `Build & Test (macOS 26)` · `Build (iOS Simulator)`。
  （`SwiftLint` / `Coverage Gate` 两个 job 已在 2026-10-20 的流水线瘦身里并入 `Build & Test`，
  不再是独立 check。）
- 另有若干**同样要绿**的守卫 job（`iOS Shared Source Guard` / `Layer Guard` / `UI Guard`
  / `Worker Tests`），见 §5 与 `AGENTS.md` §3。
- 任何检查变红时 main 不可合入 —— 红测试永远进不了 main。
- 紧急修复 main 时：Settings → Branches → 临时关闭 enforceAdmins，修完立即恢复。

> ⚠️ 改 job 的 `name:` 等于改必需检查的名字 —— 会让所有 PR 卡在一个永不出现的检查上，
> 而保护规则不会提示你。改名前先读这一节。
>
> ⚠️ 同理，**`on.pull_request` 绝不能加 `paths-ignore`**：被路径过滤掉的 workflow 不产生
> check run，必需检查会一直等 ⇒ 纯文档 PR 永远合不了。`paths-ignore` 只加在 `push` 上
> （省 main 上的无谓运行），PR 一律全跑。

## 2. SwiftLint（`.swiftlint.yml`）

- 策略：**安全规则硬性 error，风格噪音整体禁用**。
  - error：`force_cast`、`force_try`、`force_unwrapping`（opt-in + severity: error）、`empty_count`。
  - 禁用：`identifier_name` / `line_length` / `comma` / `colon` 等纯风格规则
    （历史代码与默认规则冲突，不强行重构）。
- **本地与 CI 用同一条命令，且都是 `--strict`**：

      swiftlint lint --strict --config .swiftlint.yml Sources

  `--strict` = **warning 也算失败**。当前基线是 0 violation，闸门从此对警告敏感。
- runner：macOS 上直接下载官方便携版（universal 二进制，版本**钉死**在 workflow 里），不用 brew
  —— `releases/latest` 会静默升级并引入新规则。

> 历史漂移（已更正）：本节曾写「warning 不阻塞」，与 CI 的 `--strict` 不符。
> 这类「同一件事在两处有两种说法」的漂移，本仓的处理原则是**以 CI 为准并改文档**，
> 而不是改 CI 去迁就文档。

## 3. 覆盖率门槛（`scripts/coverage_gate.py`）

- 两条**聚合**门槛：整体（whole `Sources/MEditor`）与非 View 逻辑代码。
  2026-08 实测基线 **17.4% / 46.8%**，默认地板 **15% / 40%**（留了抖动余量）。
- **路径门槛**：CI 传若干 `--min-dir <路径前缀>=<百分比>`，给关键目录单独设地板
  （`Services/AI/Agent` / `Services/MCP` / `Managers` / `ViewModels` / `Models` / `Skills`）。
  前缀匹配（不是顶层目录名），所以 `--min-dir Services/AI/Agent=75` 是有效的。
  某个地板对应的目录**完全没有覆盖数据**也算失败 —— 那通常意味着改名/拼错，而不是「目录本来就空」。
- 本地生成 lcov：

      swift test --enable-code-coverage
      xcrun llvm-profdata merge -o default.profdata .build/**/codecov/*.profraw
      xcrun llvm-cov export .build/**/MEditorPackageTests.xctest/Contents/MacOS/MEditorPackageTests \
          -instr-profile default.profdata --format=lcov > coverage.lcov
      python3 scripts/coverage_gate.py coverage.lcov

- ⚠️ **基线数字会腐烂**：上面那两个百分比是 2026-08 的读数，引用前请复算。
  聚合门槛只挡大回归；单 PR 的增量覆盖靠 §4 的人工/AI 审查补。
- ⚠️ `Views/` 与「非 View 逻辑」是分开统计的 —— 存在「把代码放进 `Views/` 就绕过逻辑门槛」
  的路径。此前 `Views/` **完全没有门槛**（35584 行、覆盖率约 2%，设常规地板等于没设）。
  现在给它设了一个**极低但存在**的棘轮地板（`--min-dir Views=1`）：不指望它推动 View 层
  提覆盖率（那需要 View 层测试策略，是独立议题），只保证这条绕过路径不再让覆盖率无限下滑，
  并把该口径问题显式摆在门禁里。真正解决需要给 View 层可测的部分（View model / 布局计算）
  拆出可注入 seam —— 见 §4 的讨论。

## 4. AI 自审（`scripts/ai_review.sh`）

- 单作者最大的盲区是「写代码的人审查自己的代码」—— AI 是成本最低的第二视角。
- 用法：`bash scripts/ai_review.sh`（工作区改动，含 staged + unstaged）或
  `bash scripts/ai_review.sh origin/main`（PR 范围）。
- 无 base 时脚本用 `git diff HEAD`，因此 `git add` 过的暂存改动也会被审查；
  想确保改动全部进入审查，先 `git add` 再跑也可以。
- 脚本会先做 lint 自检：**lint 失败不会中断 review**，但会在结尾明确报出失败状态，
  提示先修复 —— 不要把「提示词已生成」误当成 lint 通过。
- 随后把 diff + 项目风险清单（并发 / 数据安全 / 会话恢复 / 强制解包 / Agent 写入链路）
  拼成审查提示词，有 claude CLI 时直接交给它，否则打印提示词。
- 审查发现的 Critical 问题必须在本 PR 内修复；历史上有过「全量 review 修复发现 Critical
  并发安全 bug」的记录，说明这类审查确实有效。

## 5. 机械守卫（`scripts/check_*.py`）

前四条是「跑起来看」的机制；这一条是**静态断言**，把已经踩过的坑钉住，防止复发。

| 脚本 | 守什么 | CI job |
|---|---|---|
| `check_ios_shared_sources.py` | iOS `Shared` 组的引用完整（配置在 pbxproj 里的手工清单，当前 49 条） | `iOS Shared Source Guard` |
| `check_service_layer_deps.py` | Service 层不得命名 ViewModel 类型（`AppState`） | `Layer Guard` |
| `check_dead_tokens.py` | `DS.*` 设计 token 必须有人引用 | `UI Guard` |

> 一个脚本一个 job（而不是塞进同一个 job）：报错时必需检查的名字直接告诉你**是哪一类问题**，
> 不用翻日志。三个都是 ubuntu runner 上的纯文本检查，秒级完成。

两条共同的纪律：

1. **棘轮式**。名单只许收紧：已修好的文件不得回退；登记为「允许例外」的项一旦被采用，
   也要从名单里删掉。这样豁免不会悄悄变成永久。
2. **必须反向验证过**。新增一条守卫时先把实现改坏、确认它变红、再恢复。
   没做过反向验证的守卫很可能是**永远绿的空断言** —— 它不产生任何保护，却让人以为有。

守卫跑在 ubuntu runner 上（纯文本检查，不依赖编译产物），秒级完成。
