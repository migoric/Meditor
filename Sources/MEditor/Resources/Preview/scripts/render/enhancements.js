// MEditor preview — heading anchors, code highlighting, and asset URLs.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;

  var LANG_ALIASES = {
    'shell': 'bash', 'sh': 'bash', 'zsh': 'bash',
    'js': 'javascript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
    'ts': 'typescript', 'tsx': 'typescript',
    'py': 'python', 'gyp': 'python',
    'rb': 'ruby', 'gemspec': 'ruby', 'rs': 'rust',
    'go': 'go', 'golang': 'go',
    'c++': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
    'cs': 'csharp', 'c#': 'csharp',
    'kt': 'kotlin', 'kts': 'kotlin',
    'yml': 'yaml', 'html': 'xml', 'xhtml': 'xml', 'svg': 'xml',
    'make': 'makefile', 'mk': 'makefile', 'mak': 'makefile',
    'patch': 'diff', 'gql': 'graphql', 'toml': 'ini',
    'txt': 'plaintext', 'text': 'plaintext',
    'console': 'plaintext', 'shellsession': 'plaintext'
  };

  /**
   * GitHub 风格的标题锚点 id。
   *
   * marked v12 早就不产出 header id 了（v5 起移除），而 markdown 预览的
   * `<base href="meditor-asset://…">` 又让 `#fragment` 没法直接落地——两头都缺，
   * 结果是文档里的 `[跳到某节](#某节)` 点了毫无反应。id 在这里统一补上，
   * 点击由 HTMLAnchorGuard 接管（`scripts/anchor-guard.js`）。
   *
   * 规则对齐 GitHub：小写、去掉标点和 emoji、空白转 `-`；同名标题按出现顺序
   * 追加 `-1`、`-2`。**必须在 DOM 上做而不是 marked renderer 里**：块缓存按
   * 块独立 parse，跨块的去重计数在那边拿不到。
   */
  function slugifyHeading(text) {
    return String(text || '')
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '')
      .replace(/\s+/g, '-');
  }

  /** 同一批标题只查询一次 DOM，同时写源码行号与 id。 */
  function stampHeadings(rootEl, sourceText) {
    if (sourceText.indexOf('#') === -1 && !/<h[1-6][\s>]/i.test(sourceText)) return;
    var lines = collectHeadingLines(sourceText);
    var headings = rootEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
    if (headings.length === 0) return;
    var lineCount = Math.min(headings.length, lines.length);
    var used = Object.create(null);
    for (var i = 0; i < headings.length; i++) {
      var el = headings[i];
      if (i < lineCount) el.setAttribute('data-source-line', String(lines[i]));
      // 作者显式写的 id 优先：markdown 里的原始 HTML、以及老文档里手工锚点都靠它。
      // 标题文字改了怎么办？那种情况下 patchDOM 会换掉整个节点（innerHTML 不同），
      // 新节点没有 id，自然重新生成——所以「不改已有 id」不会让 id 变陈旧。
      if (el.id) { used[el.id] = true; continue; }
      var base = slugifyHeading(el.textContent) || 'section';
      var id = base;
      var n = 1;
      while (used[id]) { id = base + '-' + n; n++; }
      used[id] = true;
      el.setAttribute('id', id);
    }
  }

  function collectHeadingLines(content) {
    var lines = content.split('\n');
    var out = [];
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      if (/^\s*```/.test(lines[i])) { inFence = !inFence; continue; }
      if (inFence) continue;
      if (/^#{1,6}\s+\S/.test(lines[i])) out.push(i);
    }
    return out;
  }

  // hljs is loaded synchronously in template.html — always available
  function loadHighlightIfNeeded() {
    return Promise.resolve();
  }

  function highlightCodeBlocks(rootEl, sourceText) {
    if (typeof sourceText === 'string' && sourceText.indexOf('```') === -1
        && sourceText.indexOf('~~~') === -1 && !/<pre[\s>]/i.test(sourceText)
        && !/^(?: {4}|\t)/m.test(sourceText)) return;
    // 幂等：已带 hljs 的块跳过。patchDOM 保留未变节点后，每帧重高亮全是
    // 浪费；缓存命中恢复（bridge）也靠这个守卫让补高亮近零成本。
    var blocks = Array.prototype.slice.call(rootEl.querySelectorAll('pre code'))
      .filter(function (el) { return !el.classList.contains('hljs'); });
    if (blocks.length === 0) return;
    blocks.forEach(attachCopyButton);
    loadHighlightIfNeeded().then(function () {
      var FIRST_BATCH = 6, IDLE_BATCH = 4;
      var first = Math.min(FIRST_BATCH, blocks.length);
      for (var i = 0; i < first; i++) highlightOneBlock(blocks[i]);
      if (blocks.length <= first) return;
      var remaining = blocks.slice(first);
      var next = function () {
        var batch = remaining.splice(0, IDLE_BATCH);
        for (var j = 0; j < batch.length; j++) highlightOneBlock(batch[j]);
        if (remaining.length > 0) scheduleIdle(next);
      };
      scheduleIdle(next);
    }).catch(function () {});
  }

  function scheduleIdle(fn) {
    if (typeof window.requestIdleCallback === 'function') {
      window.requestIdleCallback(fn, { timeout: 200 });
    } else {
      setTimeout(fn, 16);
    }
  }

  function highlightOneBlock(block) {
    var lang = null;
    var match = block.className.match(/language-([a-zA-Z0-9_+#-]+)/);
    if (match) { lang = match[1].toLowerCase(); }
    if (lang && LANG_ALIASES[lang]) { lang = LANG_ALIASES[lang]; }
    if (lang && hljs.getLanguage(lang)) {
      try {
        block.innerHTML = hljs.highlight(block.textContent, { language: lang, ignoreIllegals: true }).value;
        block.classList.add('hljs');
      } catch (e) { block.classList.add('hljs'); }
    } else {
      block.classList.add('hljs');
    }
  }

  function attachCopyButton(codeEl) {
    var pre = codeEl.parentElement;
    if (!pre || pre.tagName !== 'PRE') return;
    if (pre.querySelector('.meditor-copy-btn')) return;
    pre.classList.add('meditor-codeblock');
    var btn = document.createElement('button');
    btn.className = 'meditor-copy-btn';
    btn.type = 'button';
    btn.textContent = 'Copy';
    btn.setAttribute('aria-label', 'Copy code');
    btn.addEventListener('click', function (ev) {
      ev.stopPropagation();
      var text = codeEl.textContent || '';
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyHandler) {
          window.webkit.messageHandlers.copyHandler.postMessage({ text: text });
          return;
        }
      } catch (e) {}
      if (navigator.clipboard) navigator.clipboard.writeText(text).catch(function () {});
      btn.textContent = 'Copied';
      btn.classList.add('meditor-copy-btn--copied');
      setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('meditor-copy-btn--copied'); }, 1200);
    });
    pre.appendChild(btn);
  }

  /** Rewrite absolute-path image/resource references (`/Users/.../pic.png`,
   *  `file:///Users/.../pic.png`) to the custom `meditor-asset://` scheme so
   *  they bypass WKWebView's `allowingReadAccessTo` single-directory
   *  restriction. Relative references (`./pic.png`, `../assets/pic.png`)
   *  are left untouched — they resolve correctly via the `<base href>`
   *  (itself a `meditor-asset://` URL, see bridge.js `setBaseURL`). */
  function rewriteAbsoluteAssetPaths(rootEl, sourceText) {
    if (typeof sourceText === 'string' && !/!\[|<(?:img|source)[\s>]/i.test(sourceText)) return;
    var els = rootEl.querySelectorAll('img[src], source[src]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var raw = el.getAttribute('src');
      var rewritten = toMeditorAssetURL(raw);
      if (rewritten) el.setAttribute('src', rewritten);
    }
  }

  function toMeditorAssetURL(raw) {
    if (!raw) return null;
    var path = null;
    if (raw.indexOf('file://') === 0) {
      try { path = decodeURIComponent(raw.slice('file://'.length)); } catch (e) { path = raw.slice('file://'.length); }
    } else if (raw.charAt(0) === '/') {
      path = raw;
    } else {
      return null; // relative path — handled by <base href>, or already an http(s)/data/meditor-asset URL
    }
    return 'meditor-asset://local' + path.split('/').map(encodeURIComponent).join('/');
  }

  core.enhancements = {
    stampHeadings: stampHeadings,
    highlightCodeBlocks: highlightCodeBlocks,
    rewriteAbsoluteAssetPaths: rewriteAbsoluteAssetPaths
  };
})(window);
