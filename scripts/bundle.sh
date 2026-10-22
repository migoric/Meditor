#!/bin/bash
# bundle.sh — Create MEditor.app bundle (Universal: arm64 + x86_64)
# Usage: ./scripts/bundle.sh [debug|release]
#   default: debug
# Then: open .build/<config>/MEditor.app
#
# 双架构说明：swift build 默认只编 host 架构，打出来的包在另一种
# 架构的 Mac 上只能靠 Rosetta。这里显式编译 arm64 + x86_64 两份，
# 用 lipo 合成 Universal binary；资源包两份一致，取 x86_64 侧的即可。

set -euo pipefail

CONFIG="${1:-debug}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/$CONFIG"
APP_NAME="MEditor"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ARCHES=(arm64 x86_64)

echo "🔨 Building $APP_NAME ($CONFIG) for: ${ARCHES[*]}..."

# App Intents const-values 提取：Xcode 26 起 appintentsmetadataprocessor 只认
# swiftc 静态提取的 const values（SWIFT_ENABLE_EMIT_CONST_VALUES 对应的两个 flag）。
# SPM 默认不带这两个 flag，这里显式加上。两个 flag 缺一不可：
#   -const-gather-protocols-file（frontend flag，需 -Xfrontend 透传）决定提取哪些协议的实现；
#   -emit-const-values-path（driver flag）让 driver 把 per-primary 的
#     .swiftconstvalues 写进 supplementary output map——缺了它 frontend 根本不会产出文件。
# batch 模式下 driver 级的路径本身不落文件，实际产物在
# .build/<triple>/<config>/<Target>.build/*.swiftconstvalues；WMO（release）下
# driver 级路径才会作为聚合文件真正写出，两种形态下面的收集逻辑都覆盖。
APPINTENTS_PROTOCOLS="$PROJECT_DIR/scripts/appintents-protocols.json"
if [ ! -s "$APPINTENTS_PROTOCOLS" ]; then
  echo "error: 未找到 App Intents 协议清单: $APPINTENTS_PROTOCOLS" >&2
  exit 1
fi
# driver 级输出路径（WMO 下是聚合文件本身；batch 下仅作开关，不真正写入）
APPINTENTS_CONST_OUT="$BUILD_DIR/MEditor.swiftconstvalues"
CONST_GATHER_FLAGS=(
  -Xswiftc -emit-const-values-path -Xswiftc "$APPINTENTS_CONST_OUT"
  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
  -Xswiftc -Xfrontend -Xswiftc "$APPINTENTS_PROTOCOLS"
)

BINARIES=()
QL_BINARIES=()
RESOURCE_DIR=""
QL_RESOURCE_FILE=""
for ARCH in "${ARCHES[@]}"; do
  swift build -c "$CONFIG" --arch "$ARCH" --package-path "$PROJECT_DIR" "${CONST_GATHER_FLAGS[@]}"
  TRIPLE_DIR="$PROJECT_DIR/.build/${ARCH}-apple-macosx/$CONFIG"
  BINARIES+=("$TRIPLE_DIR/$APP_NAME")
  QL_BINARIES+=("$TRIPLE_DIR/MEditorQuickLook")
  # 资源 bundle 各架构内容一致，记录第一份即可
  if [ -z "$RESOURCE_DIR" ] && [ -d "$TRIPLE_DIR/${APP_NAME}_${APP_NAME}.bundle/Resources" ]; then
    RESOURCE_DIR="$TRIPLE_DIR/${APP_NAME}_${APP_NAME}.bundle/Resources"
  fi
  # Quick Look 扩展的 SwiftPM 资源 bundle（包名_目标名）：ql-render.js
  if [ -z "$QL_RESOURCE_FILE" ] && [ -f "$TRIPLE_DIR/${APP_NAME}_MEditorQuickLook.bundle/Resources/ql-render.js" ]; then
    QL_RESOURCE_FILE="$TRIPLE_DIR/${APP_NAME}_MEditorQuickLook.bundle/Resources/ql-render.js"
  fi
done

# const-values 自愈：SwiftPM 对「先无 flag 构建、后带 flag 构建」的增量序列
# 可能跳过 const values 生成（CI release 流水线预编译污染的实测场景）。
# 缺失时 touch Intents 源文件，强制重编第一个架构（metadata 与架构无关，只需一份）。
HEAL_TRIPLE_DIR="$PROJECT_DIR/.build/${ARCHES[0]}-apple-macosx/$CONFIG"
if [ ! -f "$APPINTENTS_CONST_OUT" ] && \
   ! find "$HEAL_TRIPLE_DIR/$APP_NAME.build" -name "*.swiftconstvalues" -print -quit 2>/dev/null | grep -q .; then
  echo "♻️  const values 缺失，强制重编 ${ARCHES[0]} 以重新提取..."
  touch "$PROJECT_DIR/Sources/$APP_NAME/Intents/"*.swift
  swift build -c "$CONFIG" --arch "${ARCHES[0]}" --package-path "$PROJECT_DIR" "${CONST_GATHER_FLAGS[@]}"
fi

echo "📦 Creating $APP_NAME.app bundle ($CONFIG, universal)..."

# Create bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Lipo both architectures into a universal binary
lipo -create "${BINARIES[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Strip 符号表：universal 里 38.8 MB → 14.7 MB，下载包 9.4 MB → 6.4 MB。
# 删的只是 __LINKEDIT 里的 nlist 数组 + 字符串表（「名称 → 地址」的索引），
# __TEXT（代码 / 常量 / C 字符串 / __swift5_* 元数据）逐字节不变——验证方式：
#   比较 load commands 之后到 __TEXT 末尾的字节，两者 sha256 相同。
# 代价仅限「拿地址回查函数名」，而那条链要 dSYM 才成立，发布包从来没有 dSYM。
# ⚠️ 必须在签名之前：strip 会让已有签名失效（构建产物带的是 swift build 的
#   ad-hoc 签名），这里 strip 完由文件末尾那次 codesign 统一签。
STRIP_BEFORE=$(stat -f %z "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
echo "🗜  $APP_NAME binary: $STRIP_BEFORE → $(stat -f %z "$APP_BUNDLE/Contents/MacOS/$APP_NAME") bytes (stripped)"

# SwiftPM 链接 Sparkle.xcframework 时 rpath 指向构建目录（Vendor/ 或 .build/artifacts）——
# .app 里 dyld 找不到框架会启动即崩（Library not loaded: @rpath/Sparkle.framework）。
# 补一条 @executable_path/../Frameworks，指向 bundle 内嵌的框架。
RPATH="@executable_path/../Frameworks"
if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -A1 LC_RPATH | grep -qF "$RPATH"; then
  install_name_tool -add_rpath "$RPATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# Copy Info.plist (with document type associations)
cp "$PROJECT_DIR/Sources/$APP_NAME/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Inject version from the single source of truth for the macOS app: <repo>/VERSION.
# (iOS takes its version from MARKETING_VERSION/CURRENT_PROJECT_VERSION in
# Mobile/MEditorMobile.xcodeproj instead.) To bump the version, edit VERSION —
# do NOT edit the version keys in Sources/MEditor/Info.plist.
# CI 发版时可用环境变量覆盖：MEDITOR_VERSION（= git tag 去 v）与
# MEDITOR_BUILD_NUMBER（= GITHUB_RUN_NUMBER，单调递增整型）——
# Sparkle 按 CFBundleVersion 比较新旧，老包（VERSION=1.1 时代）装的是
# "1.1"，若继续用点分版本比较会被判成「已是最新」，必须走整型 build 号。
VERSION_FILE="$PROJECT_DIR/VERSION"
if [ ! -s "$VERSION_FILE" ]; then
  echo "error: version file not found or empty: $VERSION_FILE" >&2
  exit 1
fi
APP_VERSION="${MEDITOR_VERSION:-$(tr -d '[:space:]' < "$VERSION_FILE")}"
BUILD_NUMBER="${MEDITOR_BUILD_NUMBER:-$APP_VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

# Sparkle（自动更新）配置：feed 指向 workers.dev；公钥验更新包 EdDSA 签名。
# 公钥文件随仓库走（scripts/sparkle-ed-public-key.txt），私钥只在 CI secret。
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://meditor-app.863129776.workers.dev/update/appcast.xml" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://meditor-app.863129776.workers.dev/update/appcast.xml" "$APP_BUNDLE/Contents/Info.plist"
# 显式禁用 Installer Launcher XPC Service。它只对沙箱 app 必要，且必须由
# SMJobBless 安装，会引入一次系统授权；非沙箱 app 启用它反而会让 Sparkle
# 直接报错（源码原文：“If your app is not sandboxed, please remove or disable
# SUEnableInstallerLauncherService”）。Sparkle 的默认值已是 NO，这里显式写死
# 是为了把“我们不要 XPC 提权安装路径”变成看得见的意图。
/usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool false" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :SUEnableInstallerLauncherService false" "$APP_BUNDLE/Contents/Info.plist"
ED_PUBKEY_FILE="$PROJECT_DIR/scripts/sparkle-ed-public-key.txt"
if [ -s "$ED_PUBKEY_FILE" ]; then
  ED_PUBKEY="$(tr -d '[:space:]' < "$ED_PUBKEY_FILE")"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $ED_PUBKEY" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ED_PUBKEY" "$APP_BUNDLE/Contents/Info.plist"
else
  echo "warning: $ED_PUBKEY_FILE 缺失——本包无法校验更新签名，自动更新将不可用" >&2
fi

# Copy resources (icons, JS libraries, etc.)
if [ -n "$RESOURCE_DIR" ]; then
  cp -R "$RESOURCE_DIR/" "$APP_BUNDLE/Contents/Resources/"
fi

# Embed Sparkle.framework（自动更新）：SPM 只负责链接，不嵌包。
# 首选构建产物目录（.build/<triple>/<config>/Sparkle.framework）——Vendor 和
# 远程 binaryTarget 两种模式 SPM 都会把框架拷到可执行文件旁边，路径最稳定；
# Vendor/ 与 .build/artifacts 只作兜底（artifacts 的解包层级随 SPM 版本变，
# v0.6.6/0.6.7 的 CI 包就是因为 artifacts 路径没匹配上、只告警不报错，
# 打出缺框架的包，启动即崩）。
SPARKLE_FW=""
for ARCH in "${ARCHES[@]}"; do
  CAND="$PROJECT_DIR/.build/${ARCH}-apple-macosx/$CONFIG/Sparkle.framework"
  if [ -d "$CAND" ]; then
    SPARKLE_FW="$CAND"
    break
  fi
done
if [ -z "$SPARKLE_FW" ] && [ -d "$PROJECT_DIR/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" ]; then
  SPARKLE_FW="$PROJECT_DIR/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [ -z "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(find "$PROJECT_DIR/.build/artifacts" -type d -name "Sparkle.framework" \
    -path "*macos*" 2>/dev/null | head -1)"
fi
# 二进制无条件链接 Sparkle，缺框架的包必然启动即崩——直接失败，不许出货
if [ -z "$SPARKLE_FW" ]; then
  echo "error: 未找到 Sparkle.framework（构建产物 / Vendor / .build/artifacts 都没有）" >&2
  exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"

# ---- Quick Look 预览扩展（.appex，手工组装，不经 Xcode 工程）----
# 结构 = 普通 bundle：Contents/{MacOS,Resources,Info.plist}，
# CFBundlePackageType=XPC! + NSExtension 声明（见 Sources/MEditorQuickLook/Info.plist）。
# 渲染资源（marked/highlight/css）直接从上面已拷进主 app 的 Resources/Preview 复制，
# 保证与 app 预览管线同源、单一来源；ql-render.js 来自扩展自己的 SwiftPM 资源 bundle。
QL_NAME="MEditorQuickLook"
QL_APPEX="$APP_BUNDLE/Contents/PlugIns/$QL_NAME.appex"
echo "🔍 Assembling Quick Look extension ($QL_NAME.appex)..."
rm -rf "$QL_APPEX"
mkdir -p "$QL_APPEX/Contents/MacOS" "$QL_APPEX/Contents/Resources"
lipo -create "${QL_BINARIES[@]}" -output "$QL_APPEX/Contents/MacOS/$QL_NAME"
# 扩展同样 strip（理由见主二进制那段）。appex 在 lipo 之后、下面单独 codesign
# 之前，顺序天然正确。
strip -x "$QL_APPEX/Contents/MacOS/$QL_NAME" 2>/dev/null
cp "$PROJECT_DIR/Sources/$QL_NAME/Info.plist" "$QL_APPEX/Contents/Info.plist"
# 扩展版本与主 app 保持一致（同一份 VERSION / CI 环境变量）
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$QL_APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$QL_APPEX/Contents/Info.plist"
# 渲染资源与主 app 同源（从已拷进主 app 的 Resources/Preview 里挑需要的复制，
# 单一来源不双份维护）。扩展走 JavaScriptCore 离线渲染，只需要 marked/highlight/css；
# template.html、scripts/、mermaid（~3.3MB）是 WebView 管线用的，不拷。
mkdir -p "$QL_APPEX/Contents/Resources/Preview"
# 只拷 QL 真正用到的资源：QLMarkdownRenderer 内联的只有 themes.css / base.css
# 两份样式表（QLPreviewReply 的 HTML 不带 base URL，引不了外部 css）。
# 历史上这里是 `cp -R css`，会把整个 css/ 目录搬过去；KaTeX 落地后 css/ 里
# 多了 katex.min.css + fonts/（约 320KB），QL 用不上，白白撑大 appex。
for item in marked.min.js highlight.min.js; do
  cp "$APP_BUNDLE/Contents/Resources/Preview/$item" "$QL_APPEX/Contents/Resources/Preview/"
done
mkdir -p "$QL_APPEX/Contents/Resources/Preview/css"
for item in themes.css base.css; do
  cp "$APP_BUNDLE/Contents/Resources/Preview/css/$item" "$QL_APPEX/Contents/Resources/Preview/css/"
done
if [ -n "$QL_RESOURCE_FILE" ]; then
  cp "$QL_RESOURCE_FILE" "$QL_APPEX/Contents/Resources/ql-render.js"
else
  echo "error: 未找到 ql-render.js（MEditorQuickLook 的 SwiftPM 资源 bundle）" >&2
  exit 1
fi
plutil -lint "$QL_APPEX/Contents/Info.plist" > /dev/null

# ---- App Intents metadata（Shortcuts/Siri 发现的唯一入口）----
# SPM 不走 Xcode 的 ExtractAppIntentsMetadata 构建步，这里手工调
# appintentsmetadataprocessor 生成 Metadata.appintents 塞进 Resources。
# 缺 metadata 时 Shortcuts 会静默看不到任何 action——与 Sparkle 框架同策略：失败即中止。
APPINTENTS_PROCESSOR="$(xcrun -f appintentsmetadataprocessor 2>/dev/null || true)"
if [ -z "$APPINTENTS_PROCESSOR" ]; then
  echo "error: 未找到 appintentsmetadataprocessor（需要完整 Xcode 工具链）" >&2
  exit 1
fi
METADATA_SDK="$(xcrun --sdk macosx --show-sdk-path)"
METADATA_XCODE_BUILD="$(xcodebuild -version | tail -1 | awk '{print $3}')"
# const values 与架构无关，取第一个架构的构建产物即可
METADATA_TRIPLE_DIR="$PROJECT_DIR/.build/${ARCHES[0]}-apple-macosx/$CONFIG"
APPINTENTS_SRC_LIST="$(mktemp)"
APPINTENTS_CONST_LIST="$(mktemp)"
find "$PROJECT_DIR/Sources/$APP_NAME" -name "*.swift" | sort > "$APPINTENTS_SRC_LIST"
find "$METADATA_TRIPLE_DIR/$APP_NAME.build" -name "*.swiftconstvalues" | sort > "$APPINTENTS_CONST_LIST"
# WMO（release）下 const values 是 driver 级聚合文件而非 per-primary 产物
if [ -f "$APPINTENTS_CONST_OUT" ]; then
  echo "$APPINTENTS_CONST_OUT" >> "$APPINTENTS_CONST_LIST"
fi
if [ ! -s "$APPINTENTS_CONST_LIST" ]; then
  echo "error: 未找到 .swiftconstvalues（const-values 提取未生效）" >&2
  exit 1
fi
"$APPINTENTS_PROCESSOR" \
  --output "$APP_BUNDLE/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$APP_NAME" \
  --sdk-root "$METADATA_SDK" \
  --xcode-version "$METADATA_XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple "${ARCHES[0]}-apple-macosx14.0" \
  --source-file-list "$APPINTENTS_SRC_LIST" \
  --swift-const-vals-list "$APPINTENTS_CONST_LIST" \
  --no-app-shortcuts-localization
rm -f "$APPINTENTS_SRC_LIST" "$APPINTENTS_CONST_LIST"
if [ ! -f "$APP_BUNDLE/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
  echo "error: App Intents metadata 未生成（extract.actionsdata 缺失）" >&2
  exit 1
fi

# Validate Info.plist
plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null

# 签名身份：默认 ad-hoc（`-`）。设了 SIGNING_IDENTITY 就用证书签。
#
# 为什么值得多这一步：ad-hoc 的 designated requirement 是 **cdhash**
# （`codesign -d --requirements -` 会看到 `designated => cdhash H"…"`），
# 每次重编都变；而证书签的是 **证书锚**（`identifier "…" and certificate leaf = H"…"`），
# 跨构建稳定。这直接决定钥匙串 ACL 会不会失配——MEditor 把 AI API key 存在
# 钥匙串里（Sources/MEditor/Services/Storage/Keychain.swift 用系统默认 ACL，
# item 只信任创建它的应用，按 code signature 判定）：签名身份不稳时，用户每次
# 升级都会看到一次「想要使用储存在钥匙串中的机密信息」授权弹窗。
# CI 默认不配证书 ⇒ 行为与以前完全一致；配了 secret 才走证书路径。
SIGN_ID="${SIGNING_IDENTITY:--}"

# Ad-hoc sign the bundle (required for macOS to launch from .app)
# 签名顺序「由内向外」（codesign 只 seal 本层，不会代替你签嵌套代码）：
#   1. appex 单独签并带沙箱 entitlement——若对整个 .app 用 --deep，
#      主 app 的签名选项会套到嵌套代码上，entitlement 被丢掉，扩展必挂；
#   2. Sparkle.framework 内部逐层签：XPCServices → Updater.app → Autoupdate → 框架本体。
#      **不要用 --deep 签 Sparkle**：Sparkle 自己的错误提示就写着
#      “do not sign your app by passing --deep”，--deep 会把外层选项套到
#      Installer/Downloader 两个 XPC helper 上，破坏它们被判定的签名身份；
#   3. 主 bundle 最后签，且不再 --deep，避免覆盖前两步。
if command -v codesign &>/dev/null; then
  # appex 签名失败 = 扩展必挂，不容许静默通过（其余步骤维持原静默风格）
  codesign --force --sign "$SIGN_ID" \
    --entitlements "$PROJECT_DIR/Sources/$QL_NAME/Entitlements.plist" \
    "$QL_APPEX" 2>/dev/null || { echo "error: Quick Look 扩展签名失败" >&2; exit 1; }

  SPARKLE_B="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [ -d "$SPARKLE_B" ]; then
    for xpc in "$SPARKLE_B/XPCServices/"*.xpc; do
      [ -e "$xpc" ] && codesign --force --sign "$SIGN_ID" "$xpc" 2>/dev/null
    done
    if [ -d "$SPARKLE_B/Updater.app" ]; then
      # Updater.app 内部的可执行文件必须先签，再签它外层 bundle
      [ -f "$SPARKLE_B/Updater.app/Contents/MacOS/Updater" ] && \
        codesign --force --sign "$SIGN_ID" "$SPARKLE_B/Updater.app/Contents/MacOS/Updater" 2>/dev/null
      codesign --force --sign "$SIGN_ID" "$SPARKLE_B/Updater.app" 2>/dev/null
    fi
    [ -f "$SPARKLE_B/Autoupdate" ] && codesign --force --sign "$SIGN_ID" "$SPARKLE_B/Autoupdate" 2>/dev/null
  fi
  codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" 2>/dev/null
  codesign --force --sign "$SIGN_ID" "$APP_BUNDLE" 2>/dev/null

  # 把最终 designated requirement 打进日志：证书签名必须是 `certificate leaf = H"…"`
  # 而不是 `cdhash H"…"`。后者意味着每次构建都变，钥匙串 ACL 升级后必然失配。
  echo "🔏 signing identity: ${SIGN_ID}"
  codesign -d --requirements - "$APP_BUNDLE" 2>&1 | grep -E "^# designated|^designated" | head -2
fi

echo "✅ $APP_NAME.app created at:"
echo "   $APP_BUNDLE"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo ""
echo "🚀 Run: open \"$APP_BUNDLE\""
