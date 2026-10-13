# 安全策略

## 支持的版本

仅**最新发布版本**接受安全修复；本仓处于 `0.x` 阶段，不维护长期分支。

| 版本 | 支持 |
|---|---|
| 最新 release | ✅ |
| 其余 | ❌ |

## 上报漏洞

**请勿用公开 issue 报漏洞。** 走 GitHub 的私有通道：

→ [**Report a vulnerability**](https://github.com/retrychx/Meditor/security/advisories/new)（Security → Advisories）

请尽量附上：受影响版本与平台（macOS / iOS）、最小复现、影响面（能读到什么 / 能改到什么 /
能执行什么）、以及你建议的缓解方式。

**响应预期**（尽力而为，非 SLA）：3 个工作日内确认收到；确认后在修复发布时一并公开致谢。

## 范围

MEditor 是一个**本地优先**的桌面 / 移动应用，但它有若干**会暴露到信任边界之外**的面。
以下缺陷属于本仓责任。

**在内**

- **Agent 写入链路**：写确认 / 写前 diff 审阅（`AgentDocumentAdapter`）、路径约束
  （`AgentWriteConfinement`）的绕过 —— 表现为写到工作区之外、或未经确认落盘。
- **命令沙箱**（`Services/AI/Agent/CommandSandbox.swift`）的分级判定绕过：
  本该归入高风险（需确认）的命令被判成 safe。
- **文件工具**（`Services/AI/Agent/Tools/`）的路径穿越与注入。
- **预览渲染管线**：`MeditorAssetSchemeHandler`（自定义 scheme 服务本地资源）、
  `Utils/JSBridge.swift`（WebView ↔ App 桥）的越界读取或越权调用。
- **局域网分享**（`Services/Network/LocalShareServer.swift`）：鉴权缺失 / 越界目录访问 /
  未授权写。
- **在线发布后端**（`worker/`，Cloudflare Workers）：token 鉴权、配额、过期逻辑的绕过
  （`worker/index.js` 的鉴权与配额分支）。
- **MCP server**（`Services/MCP/MCPServer.swift`，stdio）：把 Agent 工具暴露给外部客户端时的
  越权调用与输入校验缺失。
- **凭据**：`Services/Storage/Keychain.swift` 的读写缺陷（API key 泄露到日志 / 磁盘 / 分享链接）。
- **自动更新通道**：`release.yml` 的签名与 appcast 生成缺陷 —— 能构造出被应用接受的伪造更新
  等同于任意代码执行。

**不在内**（按设计属于使用者或上游的责任）

- **提示词注入与模型输出内容**：模型让 Agent 做某事、Agent 按写确认/沙箱流程处理 ——
  属于应用层语义问题，不是本仓的运行边界缺陷（除非它**绕过了**上表里的某个机制）。
- **用户自己批准执行的命令**：确认条点「允许」之后的后果由使用者承担。
- **第三方依赖自身的漏洞**：请报给上游；我们会跟进 `dependabot` 告警。
- **本地已沦陷的机器**：进程已被同用户的其他程序控制时，本应用不提供额外隔离。

## 已知边界（如实标注）

- **LAN 分享与在线发布是有意为之的出网行为**，都需使用者显式发起；它们的**强度**
  （是否需要口令、链接有效期）由产品设计决定，不作为漏洞受理。
- **Agent 的"确认条"不是安全边界，是防误操作的闸**。它拦的是模型手滑，不是恶意提示词 ——
  真正的边界是 `CommandSandbox` 的分级与 `AgentWriteConfinement` 的路径约束。
- **iOS 端能力面小于 macOS**（无 MCP / 无局域网分享 / 无命令执行），
  因此上述部分条目在 iOS 上不适用。
- 本应用**不做遥测**，不主动上传文档内容；唯一的出网是使用者配置的 AI 后端、
  分享/发布功能与自动更新检查。
