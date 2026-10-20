# 参与贡献

感谢你愿意贡献。本仓的**代码约定只有一份** —— 见 [`AGENTS.md`](./AGENTS.md)
（它同时是 AI 编码助手的权威入口）。本文只讲**人**的流程，不重复那份，避免出现两套说法。

## 快速上手

```bash
git clone https://github.com/migoric/Meditor.git
cd Meditor
swift build                  # 编译桌面端
./scripts/test.sh            # 全量测试（= swift test，显式指向 Xcode 工具链）
make test                    # 上面那条的别名
```

> ⚠️ **工具链要 Xcode 26**：`Package.swift` 是 `swift-tools-version: 6.2`，旧版 Xcode
> 打不开这个包（不是"能编但缺新 API"，是直接拒绝加载）。
> 部署下限是 macOS 14 / iOS 17（`platforms:` 声明）。
>
> ⚠️ **首次构建若卡在下载 Sparkle**：本机网络被中间人代理拦时 SwiftPM 拉不动二进制。
> 逃生舱是把 `Sparkle-for-Swift-Package-Manager.zip` 解出的 `Sparkle.xcframework`
> 放进 `Vendor/`（`Vendor/` 已 gitignore，`Package.swift` 会自动改走本地 binaryTarget）。

## 提交前必须跑

```bash
swift build
swiftlint lint --strict --config .swiftlint.yml Sources     # 与 CI 同一条；--strict = warning 也算失败
./scripts/test.sh
python3 scripts/check_service_layer_deps.py                 # 分层守卫
python3 scripts/check_dead_tokens.py                        # 设计 token 守卫
```

CI main gate：`Build & Test (macOS 26)`（含 SwiftLint + 覆盖率门槛）· `Build (iOS Simulator)`。
另有若干同样要绿的守卫 job（`Layer Guard` / `UI Guard` / `Worker Tests` …）。

> ⚠️ **分支保护目前没生效**（2026-10-20 实测）：仓库是 private + 免费计划，保护 API 返回 403、
> `branches/main` 报 `protected: false` ⇒ 上面的 check 名**不是强制的**，改 `name:` 不会卡死 PR。
> 但仓库转 public / 升级 Pro 后要立刻把这两个名字加回必需检查，届时改名才会卡住所有 PR
> （本仓 `AGENTS.md` §3 也记了这句）。

覆盖率门槛本地跑法（要 lcov）见 [`docs/engineering-practices.md`](./docs/engineering-practices.md) §3。

### 可选：仓内 git 钩子（每个克隆各开一次）

git **不会**自动启用仓库里的钩子，所以这一步是可选的：

```bash
git config core.hooksPath .githooks     # 之后每次 push 前跑静态检查（SwiftLint + 守卫脚本，约几秒）
SKIP_VERIFY=1 git push                  # 急着推时跳过
```

> ⚠️ 它**不是门禁**，只覆盖静态检查（**故意不含 `swift build` / `swift test`** —— 那要几分钟，
> 结果只会让人一律 `--no-verify`）。也只在**你的机器**上生效，别人的克隆和 CI 都不跑它，
> 所以别把任何「必须发生」的事只放在这里。真正的门禁是 CI 上那四个必需检查。

另外可以顺手让 `git blame` 跳过纯机械提交：

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

## 提 PR 的流程

`main` 是**受保护分支**（`enforce_admins` 也开着）：

1. 从 `main` 开分支（`feat/…` · `fix/…` · `docs/…` · `chore/…` · `refactor/…` · `ci/…`）
2. 提交、推送
3. 开 PR —— CI 必须全绿才能合并
4. 合并方式：squash / merge / rebase 都允许，仓库不强制线性历史

> 直接 `git push origin main` 会被拒 —— 这是设计，不是故障。

## 提交信息

沿用 Conventional Commits 前缀（`feat:` / `fix:` / `docs:` / `chore:` / `refactor:` / `test:` / `perf:`），
正文用中文讲清**为什么**（而不只是做了什么）。语义有变更的用 `!` 标记并在正文说明兼容性影响。

**提交标题会进用户看到的 Release Notes**：`release.yml` 用
`git log <上一个 tag>..<当前 tag>` 的提交标题拼 GitHub Release 正文（过滤 chore/merge 噪音）。
所以标题要能独立看明白 —— 它是唯一会自动流到发布页的那部分。

## 最容易踩的几个坑

| 坑 | 说明 |
|---|---|
| 新增了共享文件没改 iOS 工程 | iOS target 的 `Shared` 组是**手工枚举**（当前 49 条），不是文件系统同步组 ⇒ iOS 静默缺文件。见 `AGENTS.md` §2.3 |
| Service 里直接抓了 `AppState` | 依赖方向反了。走 `AgentDocumentAdapter` / `AgentHostPort` 端口 ⇒ `Layer Guard` 会拦 |
| 定义了没人用的 `DS.*` token | 它会诱导下一个人用错档 ⇒ `UI Guard` 会拦。真需要例外就登记理由 |
| 共享代码里读了 `AppSettings.shared` | iOS 上是假替身（`AppSettingsShim`），取到的是假值 |
| 新守卫没做反向验证 | 没做过反向验证的守卫很可能是**永远绿的空断言**。先改坏 → 看它变红 → 再恢复 |
| 顺手把 iOS 版本号对齐 macOS | 两端按设计各自独立演进，**别对齐**（`AGENTS.md` §4） |

## 发版流程

只有**两个动作是手写的**（版本单源只有两处），其余交给 CI。

```bash
# 1. 把 macOS 版本单源改到新版本（iOS 侧按需独立决定，不必对齐）
echo 0.12.0 > VERSION
# 2. 写 CHANGELOG.md 的本版条目
$EDITOR CHANGELOG.md
```

然后：

```bash
git push origin <你的分支>        # 开 PR，等四个必需检查全绿
# 合并到 main（此时 VERSION 已在 main 上）
git checkout main && git pull
git tag -a v0.12.0 -F /tmp/tag-message.md      # 版本必须与 VERSION 严格一致
git push origin v0.12.0
```

`release.yml` 在 `v*` tag 上自动跑（顺序固定）：

1. **校验**：tag 形如 `^v\d+\.\d+\.\d+$`，且 `v<VERSION>` 与 tag 名**逐字相等** ——
   不一致直接在第一步失败，不会产出半发布状态。
2. `swift test`（发布也要过测试；`swift test` 自己会先编译，不再额外跑一次 `swift build`）。
3. `scripts/bundle.sh` 打 Universal `.app` → 签名（Sparkle EdDSA）→ 压 `MEditor-vX.Y.Z.zip`。
4. 生成/更新 `appcast.xml`（自动更新通道），并从 tag 区间的提交标题生成 Release 正文。
5. 建 GitHub Release，回放校验 appcast 可取、字节数与安装包一致。

几条纪律：

- **tag 与 `VERSION` 不一致 ⇒ 不发布**。想发版先改 `VERSION` 并合进 `main`，再打 tag ——
  反过来会给 `main` 上留一个「版本说 0.11 但发布页说 0.12」的状态。
- `release.yml` 用 `macos-26` 构建：外观按**构建时 SDK** 决定，用旧 SDK 出的包在 Tahoe 上是
  旧式灰侧栏（没有 Liquid Glass），与用户系统无关。
- `scripts/bundle.sh` **没有测试**，而 `release.yml` 依赖它的正确性（已知覆盖缺口，改它要格外
  小心）。同目录的 `sign_update.swift` 自 0.12.1 起有端到端测试
  （`Tests/MEditorTests/SignUpdateScriptTests.swift`：真脚本子进程 + 公钥验签）。
- ⚠️ 自 2026-10-20 起 **PR CI 不再跑 `bundle.sh`**：它为产出 Universal 包要按 arm64 / x86_64
  各做一次 `swift build`（runner 上 x86_64 是纯交叉全量编译、无法复用缓存），而它产出的
  artifact 全仓没有任何消费方。⇒ **改 `bundle.sh` 后必须手工跑一次 Actions → Release Dry Run**，
  那条链路才是打包正确性的闸门（证书锚 designated requirement + `codesign --deep` + 资源层级）。
- `workflow_dispatch` 只能指向 `v*` tag；指向普通分支会被脚本拒绝。

### 发布签名身份（可选 secret）

`release.yml` 默认用 **ad-hoc** 签名（`codesign --sign -`）。它的 designated requirement 是
**cdhash**，每次构建都变 —— 而 MEditor 把 AI API key 放在钥匙串里、用系统默认 ACL
（`Sources/MEditor/Services/Storage/Keychain.swift`，item 只信任创建它的应用、按 code
signature 判定），于是**用户每次升级都会看到一次**「想要使用储存在钥匙串中的机密信息」
授权弹窗。配一张证书签名即可根治：证书的 designated requirement 是**证书锚**
（`certificate leaf = H"…"`），跨构建稳定，ACL 不失配。

| secret | 内容 |
|---|---|
| `MACOS_SIGNING_CERT_P12_BASE64` | `.p12`（含私钥）的 base64，**单行无换行** |
| `MACOS_SIGNING_CERT_PASSWORD` | 该 p12 的导出密码 |

```bash
# 生成自签名代码签名证书（Code Signing EKU，10 年）
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout cs.key -out cs.crt \
  -subj "/CN=MEditor Self-Signed Code Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# 导出 p12：必须用 legacy PBE 且密码非空，否则 macOS `security import` 报
# "MAC verification failed during PKCS12 import (wrong password?)"
openssl pkcs12 -export -inkey cs.key -in cs.crt -out cs.p12 \
  -passout pass:'<你的密码>' -name "MEditor Self-Signed Code Signing" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

base64 -i cs.p12 | tr -d '\n' | gh secret set MACOS_SIGNING_CERT_P12_BASE64
gh secret set MACOS_SIGNING_CERT_PASSWORD --body '<你的密码>'
```

两个都没配 ⇒ 走 ad-hoc，行为与配之前完全一致，**不阻断发布**。配了之后
`release.yml` 会多两步：`Import code signing identity`（建临时钥匙串并导入）和
`Verify signing requirement`（核对 designated requirement 确实是证书锚；若还是 cdhash
就直接失败，不出这种包）。

⚠️ **安全权衡**：证书私钥进了 CI secret，意味着能读到 secret 的人就能签出匹配用户钥匙串
ACL 的 app、静默读走 API key。自签名证书只解决「少弹一次框」，**不解决** Gatekeeper
（首次启动仍需右键 → Open）。要同时解决两者，需要 Developer ID Application 证书 + 公证
（Apple Developer Program，$99/年）——见 README 路线图。

## 报 issue

用 issue 模板（Bug 报告 / 功能建议）。安全漏洞**不要**开公开 issue —— 见 [`SECURITY.md`](./SECURITY.md)。

## 许可

贡献即表示同意以本仓的 [MIT 许可](./LICENSE) 发布你的贡献。
