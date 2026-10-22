// MEditor preview — Markdown rendering pipeline.
// All rendering happens synchronously on the main thread.
// highlight.js is loaded lazily and applied in idle-time batches.

(function (global) {
  'use strict';

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

  function extractMermaid(content) {
    var diagrams = [];
    var processed = content.replace(/```mermaid[^]*?```/g, function (match) {
      var code = match.replace('```mermaid', '').slice(0, -3).trim();
      var id = 'mermaid-' + diagrams.length;
      diagrams.push({ id: id, code: code });
      return '<div class="mermaid-placeholder" id="' + id + '"></div>';
    });
    return { processed: processed, diagrams: diagrams };
  }

  // ── 数学公式（KaTeX）────────────────────────────────────────────────
  // 与 mermaid 同一模式：在 marked 解析**之前**把 $$..$$ / $..$ 摘成占位元素，
  // 解析完（且过完 DOMPurify）再交给 KaTeX 渲染。
  //
  // 为什么不直接在 marked renderer 里产出 KaTeX HTML：
  //   1. DOMPurify 会洗掉 KaTeX 定位所依赖的 inline style 与 MathML 标签，排版散架；
  //   2. 占位符模式让块级缓存与增量 patch 照常生效——KaTeX HTML 很大，
  //      每敲一个字符重算全文公式会明显拖慢输入。
  // 安全性：渲染发生在 DOMPurify **之后**，且 KaTeX 默认 trust:false
  //（\href / \includegraphics 等可注入命令被禁），输出不经过用户可控的 HTML 解析。
  var MATH_BLOCK_CLASS = 'meditor-math-block';
  var MATH_INLINE_CLASS = 'meditor-math-inline';
  var MATH_ID_PREFIX = 'meditor-math-';

  /** 等长占位串：遮蔽代码时用，保证扫描索引与原文一一对应。 */
  function maskSameLength(match) {
    var out = '';
    for (var i = 0; i < match.length; i++) out += '\u0000';
    return out;
  }

  /** tex 指纹：让 nodesEqual 能分辨「同一位置的公式内容变了」。 */
  function hashTex(tex) {
    var h = 5381;
    for (var i = 0; i < tex.length; i++) {
      h = ((h << 5) + h + tex.charCodeAt(i)) | 0;
    }
    return (h >>> 0).toString(36);
  }

  /**
   * 摘出数学片段并替换为占位元素，返回 { processed, items }。
   *
   * 代码块（``` / ~~~）与行内代码（`）里的 `$` 不参与识别——先把它们原地遮蔽成
   * 等长占位串再扫描，索引仍与原文对齐。
   * inline 规则沿用 KaTeX auto-render 的启发式：`$...$` 首尾不能是空白，
   * 挡住「价格 $5 到 $10」这类写法被误判成公式。
   */
  function extractMath(content) {
    var src = content || '';
    var masked = src
      .replace(/```[^]*?```/g, maskSameLength)
      .replace(/~~~[^]*?~~~/g, maskSameLength)
      .replace(/`[^`\n]*`/g, maskSameLength);

    var items = [];
    var out = '';
    var cursor = 0;
    var re = /\$\$([^]*?)\$\$|\$([^\n$]+?)\$/g;
    var m;
    while ((m = re.exec(masked)) !== null) {
      var display = m[1] !== undefined;
      var tex = display ? m[1] : m[2];
      if (!display && (/^\s/.test(tex) || /\s$/.test(tex))) continue;
      if (!tex || !tex.trim()) continue;
      var trimmed = tex.trim();
      var id = MATH_ID_PREFIX + items.length;
      items.push({ id: id, tex: trimmed, display: display });
      out += src.slice(cursor, m.index);
      out += display
        ? '<div class="' + MATH_BLOCK_CLASS + '" id="' + id + '" data-tex-hash="' + hashTex(trimmed) + '"></div>'
        : '<span class="' + MATH_INLINE_CLASS + '" id="' + id + '" data-tex-hash="' + hashTex(trimmed) + '"></span>';
      cursor = m.index + m[0].length;
    }
    out += src.slice(cursor);
    return { processed: out, items: items };
  }

  /** 把占位元素交给 KaTeX 渲染（幂等：已渲染过的元素跳过）。 */
  function renderMath(items) {
    if (!items || items.length === 0) return;
    // katex.min.js 缺失（打包漏文件）时静默降级：公式以原本的占位宽度留白，不报错。
    if (typeof katex === 'undefined' || typeof katex.render !== 'function') return;
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      var el = document.getElementById(item.id);
      if (!el || el.firstChild) continue;   // 未挂载 / 已渲染过
      try {
        katex.render(item.tex, el, {
          displayMode: item.display,
          throwOnError: false,
          strict: false,
          trust: false
        });
      } catch (e) {
        // 不改 className：归一化比较靠它认占位符，换了会导致每轮都重渲染。
        el.textContent = 'Math: ' + String((e && e.message) || e);
        el.classList.add('katex-error');
      }
    }
  }

  /**
   * 归一化含数学占位符的节点，供块级比较使用。
   *
   * DOM 里数学节点装的是 KaTeX 渲染结果，而新解析出的 HTML 里是空占位符——
   * 直接比 innerHTML 永不相等，会导致**每次编辑都重建整块并重渲染全部公式**
   *（inline 公式尤其致命，它会把所在段落整个拖下水）。
   * 这里克隆后只清空占位符内容，让两边可比；不含数学的节点返回 null 走快路径。
   */
  function normalizedMathHTML(el) {
    if (el.innerHTML.indexOf(MATH_ID_PREFIX) === -1) return null;
    var clone = el.cloneNode(true);
    var placeholders = clone.querySelectorAll('.' + MATH_INLINE_CLASS + ', .' + MATH_BLOCK_CLASS);
    for (var i = 0; i < placeholders.length; i++) {
      var node = placeholders[i];
      while (node.firstChild) node.removeChild(node.firstChild);
    }
    return clone.innerHTML;
  }

  // Paragraph-level parse cache: avoids re-parsing unchanged paragraphs.
  // Key = paragraph text (exact match, no hash collision risk).
  // Only caches blocks under 2KB to bound memory usage.
  var paragraphCache = new Map();
  var PARAGRAPH_CACHE_LIMIT = 300;
  var PARAGRAPH_CACHE_MAX_BLOCK = 2048;

  /** 顶层围栏开栏行：零缩进 + ≥3 个反引号或波浪号（理由见 splitBlocks）。 */
  var FENCE_OPEN = /^(`{3,}|~{3,})/;
  /** 闭合围栏行：CommonMark 允许 0–3 空格缩进，其后只能有空白。 */
  var FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})\s*$/;
  /** 带缩进的围栏行——可能是列表项里的围栏，其容器上下文我们还原不了。 */
  var FENCE_INDENTED = /^\s+(`{3,}|~{3,})/;

  /**
   * 按空行切块，**顶层围栏代码块内部不切**。
   *
   * 不能直接用 `content.split(/\n{2,}/)`：围栏里经常有空行（用空行分段的
   * shell 脚本、配置样例），切开后首行成了未闭合代码块、代码正文被当普通
   * 段落、收尾的 ``` 漏成正文。
   *
   * 保守边界：带缩进的围栏（4 空格）通常是列表项的内容，单独把代码块切出来
   * 会丢掉列表上下文（渲染成缩进代码块、或位置错乱）。遇到这种一律返回 null
   * 让调用方全文解析——与支持围栏之前的行为一致，宁可少缓存，不可渲染错。
   *
   * @returns {string[]|null} 块数组；围栏未闭合或有带缩进的围栏时返回 null。
   */
  function splitBlocks(content) {
    var lines = content.split('\n');
    var blocks = [];
    var current = [];
    var fence = null;          // { char: '`' | '~', len: n } —— 非 null 即在围栏内

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];

      if (fence) {
        var close = FENCE_CLOSE.exec(line);
        if (close && close[1].charAt(0) === fence.char && close[1].length >= fence.len) {
          fence = null;
        }
        current.push(line);
        continue;
      }

      var open = FENCE_OPEN.exec(line);
      if (open) {
        fence = { char: open[1].charAt(0), len: open[1].length };
        current.push(line);
        continue;
      }

      // 缩进围栏 ⇒ 容器（列表）里的代码块，切块会破坏它的上下文
      if (FENCE_INDENTED.test(line)) return null;

      // 只有真空行才是块分隔符（与 \n{2,} 同义；含空白的行留给 marked 判定）
      if (line === '') {
        if (current.length > 0) {
          blocks.push(current.join('\n'));
          current = [];
        }
        continue;
      }

      current.push(line);
    }

    if (fence) return null;     // 围栏未闭合（流式写入 / 编辑中途）
    if (current.length > 0) blocks.push(current.join('\n'));
    return blocks;
  }

  /**
   * Render markdown by splitting into blocks (paragraphs separated by blank lines),
   * caching each block's HTML independently. Only changed blocks hit marked.parse.
   * Falls back to full parse for cross-block structures (link reference definitions)
   * and for unterminated fences.
   */
  function renderMarkdownCached(content) {
    // Fallback: link reference definitions are cross-block state.
    if (/^\[.+\]:\s/m.test(content)) {
      return renderMarkdown(content);
    }

    // 围栏内部不切块 ⇒ 含代码块的文档也能命中块级缓存。
    // 此前这里是「任意位置出现围栏就放弃分块」，而技术文档几乎必然含代码块，
    // 等于缓存对目标用户基本失效（757KB 实测全量 marked.parse 98.7ms，
    // 每一轮防抖更新都要重付一次）。
    var blocks = splitBlocks(content);
    if (!blocks || blocks.length <= 2) {
      return renderMarkdown(content);
    }

    var htmlParts = [];

    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      if (!block.trim()) { htmlParts.push(''); continue; }

      if (block.length <= PARAGRAPH_CACHE_MAX_BLOCK && paragraphCache.has(block)) {
        htmlParts.push(paragraphCache.get(block));
      } else {
        var blockHTML = sanitizeHTML(marked.parse(fixTableSeparators(block), { gfm: true, breaks: false }));
        if (block.length <= PARAGRAPH_CACHE_MAX_BLOCK) {
          paragraphCache.set(block, blockHTML);
          if (paragraphCache.size > PARAGRAPH_CACHE_LIMIT) {
            var firstKey = paragraphCache.keys().next().value;
            paragraphCache.delete(firstKey);
          }
        }
        htmlParts.push(blockHTML);

        // Evict oldest if over limit
        if (paragraphCache.size > PARAGRAPH_CACHE_LIMIT) {
          var firstKey = paragraphCache.keys().next().value;
          paragraphCache.delete(firstKey);
        }
      }
    }

    return htmlParts.join('\n');
  }

  function renderMarkdown(content) {
    var processed = content
      .replace(/^(#{1,6}\s+[^\n]+)\n(?!\n)/gm, '$1\n\n')
      .replace(/^(---+|\*\*\*+|___+)\s*\n(?!\n)/gm, '$1\n\n');
    processed = fixTableSeparators(processed);
    return sanitizeHTML(marked.parse(processed, { gfm: true, breaks: false }));
  }

  // marked 不做任何消毒，其输出直接 innerHTML 会让恶意 markdown 注入
  // <script>/onerror 等载荷（XSS，进而借 meditor-asset:// 读盘外泄）。
  // 所有渲染出口统一在这里过 DOMPurify；ALLOWED_URI_REGEXP 在默认白名单
  // 协议上额外放行 file: 和 meditor-asset:（本地图片路径，点击导航由
  // Swift 侧 PreviewLinkNavigator 拦截，不会在 webview 内打开）。
  var SANITIZE_URI_REGEXP = /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|file|meditor-asset):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;

  function sanitizeHTML(html) {
    // 消毒库缺失时兜底放行——template.html 的 CSP（script-src 'self'）仍挡着内联脚本。
    if (typeof DOMPurify === 'undefined' || typeof DOMPurify.sanitize !== 'function') return html;
    return DOMPurify.sanitize(html, { ALLOWED_URI_REGEXP: SANITIZE_URI_REGEXP });
  }

  function fixTableSeparators(text) {
    if (text.indexOf('|') === -1) return text;
    var lines = text.split('\n');
    var modified = false;
    for (var i = 1; i < lines.length; i++) {
      var line = lines[i];
      if (!/^\|?[\s|:\-]+\|?$/.test(line) || line.indexOf('-') === -1) continue;
      var prev = lines[i - 1];
      if (!prev || prev.indexOf('|') === -1) continue;
      var hc = countPipeCols(prev), sc = countPipeCols(line);
      if (hc > 0 && sc > 0 && sc !== hc) {
        var parts = splitPipeCols(line);
        while (parts.length < hc) parts.push('---');
        if (parts.length > hc) parts = parts.slice(0, hc);
        lines[i] = '| ' + parts.join(' | ') + ' |';
        modified = true;
      }
    }
    return modified ? lines.join('\n') : text;
  }

  function countPipeCols(line) {
    var t = line.trim();
    if (t.charAt(0) === '|') t = t.substring(1);
    if (t.charAt(t.length - 1) === '|') t = t.substring(0, t.length - 1);
    return t.length === 0 ? 0 : t.split('|').length;
  }

  function splitPipeCols(line) {
    var t = line.trim();
    if (t.charAt(0) === '|') t = t.substring(1);
    if (t.charAt(t.length - 1) === '|') t = t.substring(0, t.length - 1);
    return t.split('|').map(function(s) { return s.trim(); });
  }

  function stampHeadingLines(rootEl, sourceText) {
    var lines = collectHeadingLines(sourceText);
    if (lines.length === 0) return;
    var headings = rootEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
    var n = Math.min(headings.length, lines.length);
    for (var i = 0; i < n; i++) {
      headings[i].setAttribute('data-source-line', String(lines[i]));
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

  function highlightCodeBlocks(rootEl) {
    var blocks = Array.prototype.slice.call(rootEl.querySelectorAll('pre code'));
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

  // Mermaid（3.3MB）不再随 template.html 同步加载——template 里没有它的
  // <script> 标签，这里按需动态注入（Swift 侧 ensureMermaidProvisioned 负责
  // 在首次出现 ```mermaid 时把文件复制进预览缓存目录）。
  // 注意 src 必须锚定 window.location（preview.html 所在目录）：页面的
  // <base href> 被改成了 meditor-asset:// 文档目录，相对 src 会解析错。
  var mermaidLoadPromise = null;

  function loadMermaidIfNeeded() {
    if (typeof mermaid !== 'undefined') return Promise.resolve();
    if (mermaidLoadPromise) return mermaidLoadPromise;
    mermaidLoadPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = new URL('mermaid.min.js', window.location.href).href;
      s.onload = function () { resolve(); };
      s.onerror = function () {
        mermaidLoadPromise = null; // 允许下次重试
        reject(new Error('mermaid.min.js 加载失败'));
      };
      document.head.appendChild(s);
    });
    return mermaidLoadPromise;
  }

  /** 加载/渲染失败时把占位块替换为错误提示，避免页面上留下无声空白。 */
  function failMermaidPlaceholders(diagrams, message) {
    (diagrams || []).forEach(function (d) {
      var el = document.getElementById(d.id);
      if (!el) return;
      var div = document.createElement('div');
      div.className = 'error-block';
      div.textContent = 'Mermaid: ' + message;
      el.outerHTML = div.outerHTML;
    });
  }

  // 最近一次 renderInto 提取出的全部 mermaid 图（id 按文档顺序稳定），
  // 供 renderAllDiagrams 找到还没懒渲染的占位。
  var latestDiagrams = [];

  function configureMermaidFromTheme() {
    if (typeof mermaid === 'undefined') return;
    var themeVar = getComputedStyle(document.documentElement)
      .getPropertyValue('--mermaid-theme').trim().replace(/['"]/g, '');
    mermaid.initialize({ startOnLoad: false, theme: themeVar || 'default' });
  }

  function renderMermaidDiagrams(diagrams) {
    if (!diagrams) return;
    latestDiagrams = diagrams;
    if (diagrams.length === 0) return;
    loadMermaidIfNeeded().then(function () {
      configureMermaidFromTheme();
      if (typeof window.IntersectionObserver !== 'function') {
        diagrams.forEach(renderOneMermaid);
        return;
      }
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          observer.unobserve(entry.target);
          var d = diagrams.filter(function (x) { return x.id === entry.target.id; })[0];
          if (d) renderOneMermaid(d);
        });
      }, { rootMargin: '200px' });
      diagrams.forEach(function (d) {
        var el = document.getElementById(d.id);
        if (el) observer.observe(el);
      });
    }).catch(function (e) {
      failMermaidPlaceholders(diagrams, String(e && e.message || e));
    });
  }

  /** 立即渲染所有仍是占位的 mermaid 图（导出/发布前调用），全部完成后 resolve。 */
  function renderAllDiagrams() {
    return loadMermaidIfNeeded().then(function () {
      configureMermaidFromTheme();
      var pending = latestDiagrams.filter(function (d) {
        var el = document.getElementById(d.id);
        return el && el.classList.contains('mermaid-placeholder');
      });
      return Promise.all(pending.map(renderOneMermaid));
    }).then(function () { return true; }, function () { return true; });
  }

  function renderOneMermaid(d) {
    return mermaid.render(d.id + '-svg', d.code).then(function (r) {
      var el = document.getElementById(d.id);
      if (el && r && r.svg) {
        el.outerHTML = '<div class="mermaid-container">' + r.svg + '</div>';
        if (window.MEditor && window.MEditor.invalidateLayoutMetrics) {
          window.MEditor.invalidateLayoutMetrics();
        }
      }
    }).catch(function (e) {
      var el = document.getElementById(d.id);
      if (el) el.outerHTML = '<div class="error-block">Mermaid: ' + String(e && e.message || e) + '</div>';
    });
  }

  function refreshMermaidForTheme() {
    if (typeof mermaid === 'undefined') return;
    configureMermaidFromTheme();
  }

  /** Rewrite absolute-path image/resource references (`/Users/.../pic.png`,
   *  `file:///Users/.../pic.png`) to the custom `meditor-asset://` scheme so
   *  they bypass WKWebView's `allowingReadAccessTo` single-directory
   *  restriction. Relative references (`./pic.png`, `../assets/pic.png`)
   *  are left untouched — they resolve correctly via the `<base href>`
   *  (itself a `meditor-asset://` URL, see bridge.js `setBaseURL`). */
  function rewriteAbsoluteAssetPaths(rootEl) {
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

  /** Full render pipeline with incremental DOM update.
   *  Instead of innerHTML replacing the entire tree, we diff at the
   *  block level (top-level children of #content) and only replace
   *  changed nodes. This preserves hljs state on unchanged code blocks
   *  and cuts DOM rebuild cost by 60-90% during typical editing. */
  function renderInto(targetEl, content) {
    try {
      var extracted = extractMermaid(content || '');
      // 数学在 mermaid 之后摘：mermaid 代码块此时已被换成占位 div，
      // 里面的 `$` 不会误入公式识别。
      var math = extractMath(extracted.processed);
      var html = renderMarkdownCached(math.processed);

      // Incremental update: compare block-level nodes
      if (targetEl.children.length > 0 && html.length < 500000) {
        var updated = patchDOM(targetEl, html);
        if (updated) {
          stampHeadingLines(targetEl, content || '');
          highlightCodeBlocks(targetEl);
          renderMermaidDiagrams(extracted.diagrams);
          renderMath(math.items);
          rewriteAbsoluteAssetPaths(targetEl);
          return;
        }
      }

      // Fallback: full replace (first render or very large docs)
      targetEl.innerHTML = html;
      if (html.indexOf('<table') !== -1) {
        var tables = targetEl.querySelectorAll('table');
        for (var t = 0; t < tables.length; t++) {
          var wrapper = document.createElement('div');
          wrapper.className = 'table-wrapper';
          tables[t].parentNode.insertBefore(wrapper, tables[t]);
          wrapper.appendChild(tables[t]);
        }
      }
      stampHeadingLines(targetEl, content || '');
      highlightCodeBlocks(targetEl);
      renderMermaidDiagrams(extracted.diagrams);
      renderMath(math.items);
      rewriteAbsoluteAssetPaths(targetEl);
    } catch (e) {
      targetEl.innerHTML = '<div class="error-block">Render error: ' + String(e && e.message || e) + '</div>';
    }
  }

  /** Block-level DOM diff. Returns true if patch was applied, false to fallback. */
  function patchDOM(targetEl, newHTML) {
    // Create a temporary container to parse the new HTML
    var temp = document.createElement('div');
    temp.innerHTML = newHTML;

    var oldNodes = Array.prototype.slice.call(targetEl.children);
    var newNodes = Array.prototype.slice.call(temp.children);

    // If structure is radically different, bail to full replace
    if (Math.abs(oldNodes.length - newNodes.length) > oldNodes.length * 0.5 + 5) {
      return false;
    }

    var maxLen = Math.max(oldNodes.length, newNodes.length);
    var patched = 0;

    for (var i = 0; i < maxLen; i++) {
      if (i >= newNodes.length) {
        // Extra old nodes: remove
        targetEl.removeChild(targetEl.lastElementChild);
        patched++;
      } else if (i >= oldNodes.length) {
        // Extra new nodes: append
        targetEl.appendChild(newNodes[i].cloneNode(true));
        patched++;
      } else if (!nodesEqual(oldNodes[i], newNodes[i])) {
        // Different: replace
        var replacement = newNodes[i].cloneNode(true);
        targetEl.replaceChild(replacement, oldNodes[i]);
        patched++;
      }
      // else: same — keep existing DOM node (preserves hljs state, scroll, etc.)
    }

    // Wrap tables in new/replaced nodes
    if (newHTML.indexOf('<table') !== -1) {
      var tables = targetEl.querySelectorAll('table:not(.table-wrapper table)');
      for (var t = 0; t < tables.length; t++) {
        if (tables[t].parentElement.className === 'table-wrapper') continue;
        var wrapper = document.createElement('div');
        wrapper.className = 'table-wrapper';
        tables[t].parentNode.insertBefore(wrapper, tables[t]);
        wrapper.appendChild(tables[t]);
      }
    }

    return true;
  }

  /** Fast shallow equality check for two DOM elements. */
  function nodesEqual(a, b) {
    if (a.tagName !== b.tagName) return false;
    // For code blocks, compare textContent (cheaper than innerHTML)
    if (a.tagName === 'PRE') {
      return a.textContent === b.textContent;
    }
    // 含数学占位符的节点：DOM 里是 KaTeX 渲染结果、新 HTML 里是空占位符，
    // 直接比 innerHTML 永不相等（每次编辑都整块重建 + 重渲染公式）。
    // 归一化后外层走同一套字符串比较；不含数学的节点返回 null 走下面的快路径。
    var aNormalized = normalizedMathHTML(a);
    var bNormalized = normalizedMathHTML(b);
    if (aNormalized !== null || bNormalized !== null) {
      return aNormalized === bNormalized;
    }
    // For everything else, compare outerHTML length first (fast reject),
    // then full comparison only if lengths match
    if (a.innerHTML.length !== b.innerHTML.length) return false;
    return a.innerHTML === b.innerHTML;
  }

  global.MEditorRender = {
    renderInto: renderInto,
    configureMermaidFromTheme: configureMermaidFromTheme,
    refreshMermaidForTheme: refreshMermaidForTheme,
    renderAllDiagrams: renderAllDiagrams
  };
})(window);
