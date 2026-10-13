<!--
提交 PR 前请确认（本仓 `main` 受保护，CI 全绿才能合）：
- swift build / swiftlint --strict / ./scripts/test.sh 全绿
- 动了共享内核 ⇒ 已同步 Mobile/MEditorMobile.xcodeproj 的 Shared 组（见 AGENTS.md §2.3）
- 新增或修改了守卫 ⇒ 已做反向验证
-->

## 做了什么

<!-- 一两句话说明这个 PR 解决的问题。关联 issue：Fixes #123 -->

## 为什么这么做

<!-- 设计取舍、被否掉的替代方案、以及任何"看起来可以更简单"的地方为什么不行 -->

## 验证

<!-- 贴关键输出。若是修 bug，说明「修复前的现象」与「为什么以前没被发现」 -->

```
swift build
./scripts/test.sh
→ Executed N tests, with 0 failures
```

## 兼容性

- [ ] 无破坏性变更
- [ ] 有破坏性变更（在下方说明迁移方式，并在提交信息里用 `!` 标记）

## 自查

- [ ] **新增/修改的守卫做过反向验证**：把实现改回有问题的样子 → 该检查确实变红 → 恢复。
      没做过反向验证的守卫很可能是永远绿的空断言（本仓有这类教训，见 `AGENTS.md` §6）
- [ ] 依赖方向未越界（Service 里没直接抓 `AppState`；`scripts/check_service_layer_deps.py` 通过）
- [ ] 没新增没人用的 `DS.*` token（`scripts/check_dead_tokens.py` 通过）
- [ ] **动了共享内核**（`Sources/MEditor/**` 里 iOS 也编译的那 49 条）⇒ 已同步 pbxproj，
      且没有引入未包裹的 AppKit 依赖、没有读 `AppSettings.shared`
- [ ] 文档与代码没有漂移（`AGENTS.md` §7 那张表：改语义同步 `CHANGELOG.md`，改现状同步 `docs/design-as-built.md`）
- [ ] 文档里新写的「某文件/机制负责某外观或行为」这类句子，**已落到调用点上核过**（文件存在 ≠ 生效）

## 风险自查（本项目的盲区清单）

- [ ] **并发**：涉及 `Task.detached` / 全局状态 / `@Observable` 时，是否有数据竞争？
      （`@MainActor` 边界、锁、缓存一致性；新增 `@unchecked Sendable` 是否写清了为什么安全）
- [ ] **数据安全**：文件读写是否保持「失败不破坏原内容」语义？路径拼接/转义是否有坑？
- [ ] **会话恢复**：涉及 SessionStore / bookmark 时，保存与加载两侧是否对称（沙箱/非沙箱）？
- [ ] **Agent 写入链路**：新增工具或写入入口是否仍走写确认 + 写前 diff 审阅？
      路径约束（`AgentWriteConfinement`）是否覆盖了新的路径来源？
- [ ] **回归测试**：新行为是否有对应测试用例？修复的 bug 是否有回归用例？
