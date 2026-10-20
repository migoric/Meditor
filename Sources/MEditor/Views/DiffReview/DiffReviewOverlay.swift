import SwiftUI
import WebKit

// MARK: - DiffReviewOverlay

/// Inline AI diff view that replaces the document content area when diff mode is active.
/// Controlled by `AppState.diffReview.isPresented`.
///
/// Layout:
///   ┌─ DiffModeBar ──────────────────────────────────┐
///   │  [✦ AI改写中… ▸▸]  或  [X处待处理][全部接受][全部跳过][✕] │
///   ├────────────────────────────────────────────────┤
///   │  左：原文（段落高亮）  │  右：AI结果（流式/diff）         │
///   └────────────────────────────────────────────────┘
@MainActor
struct DiffReviewOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            DiffModeBar()
            Divider()
            HSplitView {
                leftPane
                rightPane
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Left pane (original)

    private var leftPane: some View {
        VStack(spacing: 0) {
            paneHeader(L("diff.original"), icon: "text.alignleft", accent: Color(hex: "EF4444"))
            Divider()
            if state.diffReview.isStreaming {
                // During streaming: show original paragraphs as-is (no diff markers)
                DiffWebView(
                    paragraphs: originalParagraphsUnchanged,
                    isRight: false,
                    isHTMLMode: false,
                    rawHTML: ""
                )
            } else {
                DiffWebView(
                    paragraphs: leftParagraphsForReview,
                    isRight: false,
                    isHTMLMode: false,
                    rawHTML: ""
                )
            }
        }
        .frame(minWidth: 300)
    }

    // MARK: - Right pane (AI result)

    private var rightPane: some View {
        VStack(spacing: 0) {
            if state.diffReview.isStreaming {
                paneHeader(
                    L("ai.inline.working", state.diffReview.streamingAction),
                    icon: "sparkles",
                    accent: Color.appAccent,
                    showSpinner: true
                )
                Divider()
                StreamingTextView(text: state.diffReview.streamedContent)
            } else {
                paneHeader(
                    state.diffReview.mode == .markdownVsHTML
                        ? L("diff.aiGeneratedHTML")
                        : L("diff.aiAction", state.diffReview.streamingAction.isEmpty
                            ? L("ai.inline.rewrite") : state.diffReview.streamingAction),
                    icon: "sparkles",
                    accent: Color(hex: "22C55E")
                )
                Divider()
                if state.diffReview.mode == .markdownVsHTML {
                    DiffWebView(
                        paragraphs: [],
                        isRight: true,
                        isHTMLMode: true,
                        rawHTML: state.diffReview.modifiedContent
                    )
                } else {
                    DiffWebView(
                        paragraphs: rightParagraphsForReview,
                        isRight: true,
                        isHTMLMode: false,
                        rawHTML: "",
                        onAction: { action, diffIdStr in
                            // 两个「全局」动作没有具体 diffId，必须先处理掉再解析 UUID。
                            switch action {
                            case "acceptAll":
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.diffReview.acceptAll()
                                }
                                return
                            case "skipAll":
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.diffReview.skipAll()
                                }
                                return
                            default:
                                break
                            }
                            guard let uuid = UUID(uuidString: diffIdStr) else { return }
                            if action == "accept" {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.diffReview.accept(uuid)
                                }
                            } else if action == "skip" {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    state.diffReview.skip(uuid)
                                }
                            }
                        }
                    )
                }
            }
        }
        .frame(minWidth: 300)
    }

    // MARK: - Pane header

    private func paneHeader(
        _ title: String,
        icon: String,
        accent: Color,
        showSpinner: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .animation(.none, value: title)
            if showSpinner {
                ProgressView().scaleEffect(0.6)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Paragraph data

    /// 流式阶段的原文段落在开始流式时算一次即可（原文不变）。
    /// 每帧重算会把长文档的 split 打进每帧布局里。
    private static var cachedOriginalParagraphs: (content: String, entries: [DiffWebView.ParaEntry])?

    /// Original paragraphs shown during streaming (no diff markers).
    private var originalParagraphsUnchanged: [DiffWebView.ParaEntry] {
        let content = state.diffReview.originalContent
        if let cached = Self.cachedOriginalParagraphs, cached.content == content {
            return cached.entries
        }
        let entries = ParagraphDiffer.splitParagraphs(content)
            .map { DiffWebView.ParaEntry(text: $0, diffId: "", status: "unchanged") }
        Self.cachedOriginalParagraphs = (content, entries)
        return entries
    }

    private var leftParagraphsForReview: [DiffWebView.ParaEntry] {
        let blocks = ParagraphDiffer.splitParagraphs(state.diffReview.originalContent)
        // 字典索引（O(段落数+diff 数)）：此前在 map 里做 diffs.first(where:) 是 O(n·m)。
        let byIndex = Dictionary(
            state.diffReview.diffs.map { ($0.originalIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return blocks.enumerated().map { i, text in
            let match = byIndex[i]
            return DiffWebView.ParaEntry(
                text:   text,
                diffId: match?.id.uuidString ?? "",
                status: match.map { $0.status.jsString } ?? "unchanged"
            )
        }
    }

    private var rightParagraphsForReview: [DiffWebView.ParaEntry] {
        let blocks = ParagraphDiffer.splitParagraphs(state.diffReview.modifiedContent)
        let byIndex = Dictionary(
            state.diffReview.diffs.map { ($0.modifiedIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return blocks.enumerated().map { j, text in
            let match = byIndex[j]
            return DiffWebView.ParaEntry(
                text:   text,
                diffId: match?.id.uuidString ?? "",
                status: match.map { $0.status.jsString } ?? "unchanged"
            )
        }
    }
}

// MARK: - DiffModeBar

/// Slim top bar shown across both panes in diff mode.
@MainActor
private struct DiffModeBar: View {
    @Environment(AppState.self) private var state

    /// refineInput 的双向绑定（DiffReviewState 是 @Observable）。
    private var refineInputBinding: Binding<String> {
        Binding(
            get: { state.diffReview.refineInput },
            set: { state.diffReview.refineInput = $0 }
        )
    }

    private func submitRefine() {
        let text = state.diffReview.refineInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.diffReview.refineInput = ""
        state.diffReview.onRefine?(text)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status icon + label
            HStack(spacing: 6) {
                Image(systemName: state.diffReview.isStreaming ? "sparkles" : "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                if state.diffReview.isStreaming {
                    Text(L("ai.inline.working", state.diffReview.streamingAction))
                        .font(.system(size: 13, weight: .semibold))
                    ProgressView().scaleEffect(0.65)
                } else {
                    Text(L("diff.review"))
                        .font(.system(size: 13, weight: .semibold))
                }
            }

            Spacer()

            if !state.diffReview.isStreaming {
                // 连续微调：对刚生成的结果继续说「再短一点」式指令迭代
                if state.diffReview.mode == .markdownVsMarkdown, state.diffReview.onRefine != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appAccent)
                        TextField(L("diff.refinePlaceholder"), text: refineInputBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(width: 170)
                            .onSubmit(submitRefine)
                        Button(action: submitRefine) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(state.diffReview.refineInput.isEmpty
                                                 ? Color.secondary.opacity(0.4)
                                                 : Color.appAccent)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.diffReview.refineInput.isEmpty)
                        .help(L("diff.refineHelp"))
                        .accessibilityLabel(L("diff.refineHelp"))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                    Divider().frame(height: 18)
                }

                // Pending count badge
                if state.diffReview.pendingCount > 0 {
                    Text(L("diff.pendingCount", state.diffReview.pendingCount))
                        .contentTransition(.numericText())
                        .animation(.default, value: state.diffReview.pendingCount)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                } else if !state.diffReview.diffs.isEmpty {
                    Text(L("diff.allHandled"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "22C55E"))
                }

                // 本次审阅的总改动数（全部接受/逐块接受的粒度参照）
                if !state.diffReview.diffs.isEmpty {
                    Text(L("diff.totalCount", state.diffReview.diffs.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 18)

                // Accept all
                if state.diffReview.mode == .markdownVsHTML {
                    Button {
                        state.diffReview.acceptAll()
                    } label: {
                        Label(L("beautify.save"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        state.diffReview.acceptAll()
                    } label: {
                        Label(L("diff.acceptAll"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.diffReview.pendingCount == 0)

                    Button {
                        state.diffReview.skipAll()
                    } label: {
                        Text(L("diff.skipAll"))
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.diffReview.pendingCount == 0)
                }

                Divider().frame(height: 18)
            }

            // Close
            Button {
                state.diffReview.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help(L("diff.closeHelp"))
            .accessibilityLabel(L("diff.closeHelp"))
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Color.primary.opacity(0.08).frame(height: 1)
        }
    }
}

// MARK: - StreamingTextView

/// Live-updating text view that renders streaming markdown content.
/// Shown in the right pane while AI is generating.
private struct StreamingTextView: View {
    let text: String
    /// 用户上翻后不再强制拽回底部（类 iOS 贴底语义）
    @State private var pinnedToBottom = true

    /// 流式展示只看结尾：大文档的全文流（拼接后的整篇）如果整个塞进
    /// SwiftUI Text，每次 chunk 都全量 CoreText 排版，排版风暴会把
    /// MainActor 饿死（CPU 99%、流式"卡住"的实测根因）。
    /// 截尾到最近 ~6K 字符，足够观察生成过程。
    private var displayText: String {
        let limit = 6000
        if text.count <= limit { return text }
        return "…\n" + String(text.suffix(limit))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText.isEmpty ? " " : displayText)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(20)

                    // Invisible anchor at the bottom for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("streamBottom")
                        .onAppear { pinnedToBottom = true }
                        .onDisappear { pinnedToBottom = false }
                }
            }
            // 不用动画：流式高频更新时，每个 chunk 重启滚动动画会把
            // SwiftUI UpdateCycle 打满（主线程布局风暴，其他 MainActor 任务饿死）
            .onChange(of: text) { _, _ in
                guard pinnedToBottom else { return }
                proxy.scrollTo("streamBottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - DiffWebView

struct DiffWebView: NSViewRepresentable {

    struct ParaEntry: Equatable {
        let text:   String
        let diffId: String
        /// "unchanged" | "pending" | "accepted" | "skipped"
        let status: String
    }

    let paragraphs: [ParaEntry]
    let isRight:    Bool
    let isHTMLMode: Bool
    let rawHTML:    String
    var onAction: ((String, String) -> Void)? = nil  // (action, diffId)

    private static let handlerName = "diffAction"

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator(onAction: onAction) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(context.coordinator, name: Self.handlerName)
        config.userContentController = uc
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(isRight ? L("diff.aiGeneratedHTML") : L("diff.original"))
        context.coordinator.webView  = webView
        context.coordinator.lastContentSignature = contentSignature
        loadContent(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAction = onAction

        let newRevision = paragraphs.map { "\($0.diffId):\($0.status)" }.joined(separator: "|")
            + rawHTML.count.description
        guard newRevision != context.coordinator.lastRevision else { return }
        context.coordinator.lastRevision = newRevision

        // Content (text) unchanged — only diff statuses changed → update via JS
        if context.coordinator.lastContentSignature == contentSignature {
            applyStatusUpdates(webView: webView)
        } else {
            context.coordinator.lastContentSignature = contentSignature
            loadContent(into: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    // MARK: Private

    private var contentSignature: String {
        paragraphs.map(\.text).joined(separator: "||") + String(rawHTML.prefix(64))
    }

    private func loadContent(into webView: WKWebView) {
        let html = buildHTML()
        let base = PreviewResourceLocator.resourcesRoot()
        webView.loadHTMLString(html, baseURL: base)
    }

    private func applyStatusUpdates(webView: WKWebView) {
        // 批量：把所有状态变更序列化成 JSON，一次 JS 调用更新完——
        // 此前每条 diff 一次 evaluateJavaScript（跨进程往返）。
        let payload = paragraphs
            .filter { !$0.diffId.isEmpty }
            .map { ["diffId": $0.diffId, "status": $0.status] }
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "if(window.updateDiffStatuses)window.updateDiffStatuses(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: HTML

    private func buildHTML() -> String {
        if isHTMLMode && isRight { return rawHTML }
        return buildMarkdownHTML()
    }

    private func buildMarkdownHTML() -> String {
        let paraJSON = paragraphs
            .map { p in
                #"{"text":\#(jsonEscape(p.text)),"diffId":"\#(p.diffId)","status":"\#(p.status)"}"#
            }
            .joined(separator: ",")

        return """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.65;color:#1a1a1a;padding:16px 20px;word-break:break-word}
@media(prefers-color-scheme:dark){body{color:#e2e2e2;background:#1c1c1e}}
.para-block{padding:10px 14px;margin:5px 0;border-radius:6px;transition:background .2s,opacity .2s}
.para-block:first-child{margin-top:0}
.diff-left-pending{background:rgba(239,68,68,.08);border-left:3px solid #EF4444}
.diff-right-pending{background:rgba(34,197,94,.12);border-left:3px solid #22C55E}
.diff-accepted{background:rgba(34,197,94,.05);opacity:.65}
.diff-skipped{opacity:.4}
.diff-focused{outline:2px solid #22C55E;outline-offset:2px}
.diff-actions{margin-top:8px;display:flex;gap:8px}
.btn-accept{background:#22C55E;color:#fff;border:none;padding:4px 14px;border-radius:4px;cursor:pointer;font-size:12px;font-weight:600}
.btn-skip{background:transparent;color:#9ca3af;border:1px solid #d1d5db;padding:4px 12px;border-radius:4px;cursor:pointer;font-size:12px}
.btn-accept:hover{background:#16a34a}
.btn-skip:hover{color:#6b7280;border-color:#9ca3af}
h1,h2,h3,h4,h5,h6{margin:.5em 0 .25em;font-weight:600;line-height:1.3}
h1{font-size:1.55em}h2{font-size:1.35em}h3{font-size:1.15em}
p{margin:.35em 0}
ul,ol{padding-left:1.4em;margin:.3em 0}
li{margin:.15em 0}
code{background:rgba(0,0,0,.07);padding:2px 5px;border-radius:3px;font-family:ui-monospace,monospace;font-size:.87em}
@media(prefers-color-scheme:dark){code{background:rgba(255,255,255,.1)}}
pre{background:rgba(0,0,0,.06);padding:10px 14px;border-radius:6px;overflow-x:auto;margin:.5em 0}
@media(prefers-color-scheme:dark){pre{background:rgba(255,255,255,.08)}}
pre code{background:none;padding:0}
blockquote{border-left:3px solid #d1d5db;padding-left:12px;color:#6b7280;margin:.5em 0}
a{color:#3b82f6;text-decoration:none}a:hover{text-decoration:underline}
hr{border:none;border-top:1px solid #e5e7eb;margin:1em 0}
table{border-collapse:collapse;width:100%;margin:.5em 0}
th,td{border:1px solid #e5e7eb;padding:6px 12px;text-align:left}
th{background:rgba(0,0,0,.04);font-weight:600}
img{max-width:100%}
</style>
<script>\(Self.loadMarkedJS())</script>
</head>
<body>
<div id="content"></div>
<script>
(function(){
  var paragraphs=[\(paraJSON)];
  var isRight=\(isRight ? "true" : "false");

  function postAction(action,diffId){
    try{window.webkit.messageHandlers.diffAction.postMessage({action:action,diffId:diffId});}catch(e){}
  }

  function cls(status){
    if(status==='pending') return isRight?' diff-right-pending':' diff-left-pending';
    if(status==='accepted') return ' diff-accepted';
    if(status==='skipped')  return ' diff-skipped';
    return '';
  }

  window.updateDiffStatus=function(diffId,newStatus){
    var blocks=document.querySelectorAll('[data-diffid="'+diffId+'"]');
    blocks.forEach(function(b){
      b.className='para-block'+cls(newStatus);
      var a=b.querySelector('.diff-actions');
      if(a&&newStatus!=='pending')a.remove();
    });
  };

  // 批量版本：一次 evaluateJavaScript 更新全部 diff 状态，避免逐条跨进程往返。
  window.updateDiffStatuses=function(list){
    (list||[]).forEach(function(item){
      if(item&&item.diffId)window.updateDiffStatus(item.diffId,item.status);
    });
  };

  function render(){
    var c=document.getElementById('content');
    c.innerHTML='';
    paragraphs.forEach(function(p){
      var block=document.createElement('div');
      block.className='para-block'+cls(p.status);
      if(p.diffId)block.setAttribute('data-diffid',p.diffId);
      var mc=document.createElement('div');
      mc.innerHTML=typeof marked!=='undefined'?marked.parse(p.text):'<pre>'+p.text+'</pre>';
      block.appendChild(mc);
      if(isRight&&p.status==='pending'&&p.diffId){
        var acts=document.createElement('div');
        acts.className='diff-actions';
        var bA=document.createElement('button');bA.className='btn-accept';bA.textContent='\(L("diff.accept"))';
        (function(id){bA.addEventListener('click',function(){postAction('accept',id);});})(p.diffId);
        var bS=document.createElement('button');bS.className='btn-skip';bS.textContent='\(L("diff.skip"))';
        (function(id){bS.addEventListener('click',function(){postAction('skip',id);});})(p.diffId);
        acts.appendChild(bA);acts.appendChild(bS);block.appendChild(acts);
      }
      c.appendChild(block);
    });
  }
  render();

  // ── 键盘审阅 ────────────────────────────────────────────────────────────
  // 此前这块 diff 只能用鼠标：30 段改动要一路点「接受 / 跳过」，而这是整条
  // 核心链路里最贵的一段交互。快捷键只在 WebView 内有焦点时生效（用户点了
  // 任一 diff 栏之后），不抢窗口其它地方的按键。
  var pendingIdx=-1;
  function pendingIds(){
    return paragraphs.filter(function(p){return p.status==='pending'&&p.diffId;})
                     .map(function(p){return p.diffId;});
  }
  function focusAt(i){
    var ids=pendingIds(); if(!ids.length)return;
    if(i<0)i=0; if(i>=ids.length)i=ids.length-1;
    pendingIdx=i;
    document.querySelectorAll('.diff-focused').forEach(function(b){b.classList.remove('diff-focused');});
    var el=document.querySelector('[data-diffid="'+ids[i]+'"]');
    if(el){el.classList.add('diff-focused');el.scrollIntoView({block:'center'});}
  }
  function focusedId(){
    var ids=pendingIds();
    return (pendingIdx>=0&&pendingIdx<ids.length)?ids[pendingIdx]:null;
  }
  document.addEventListener('keydown',function(e){
    if(!isRight)return;
    var tag=(document.activeElement&&document.activeElement.tagName)||'';
    if(tag==='INPUT'||tag==='TEXTAREA')return;
    var k=e.key;
    // 按钮自己已有焦点时把 Enter/空格让给它，否则一次回车会「按钮点击 + 快捷键」各走一遍
    if(tag==='BUTTON'&&(k==='Enter'||k===' '))return;
    if((e.metaKey||e.ctrlKey)&&k==='Enter'){e.preventDefault();postAction('acceptAll','');return;}
    if(k==='j'||k==='ArrowDown'){e.preventDefault();focusAt(pendingIdx+1);return;}
    if(k==='k'||k==='ArrowUp'){e.preventDefault();focusAt(pendingIdx-1);return;}
    if(k==='Enter'){var id=focusedId();if(id){e.preventDefault();postAction('accept',id);focusAt(pendingIdx);}return;}
    if(k==='s'){var id2=focusedId();if(id2){e.preventDefault();postAction('skip',id2);focusAt(pendingIdx);}return;}
  });
})();
</script>
</body>
</html>
"""
    }

    private func jsonEscape(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str  = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    // MARK: marked.js (cached)

    private static var _markedJS: String?

    static func loadMarkedJS() -> String {
        if let cached = _markedJS { return cached }
        guard let root = PreviewResourceLocator.resourcesRoot(),
              let js   = try? String(contentsOf: root.appendingPathComponent("marked.min.js"), encoding: .utf8)
        else { return "" }
        _markedJS = js
        return js
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastRevision         = ""
        var lastContentSignature = ""
        var onAction: ((String, String) -> Void)?

        init(onAction: ((String, String) -> Void)?) { self.onAction = onAction }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body   = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let diffId = body["diffId"] as? String else { return }
            DispatchQueue.main.async { [weak self] in self?.onAction?(action, diffId) }
        }
    }
}
