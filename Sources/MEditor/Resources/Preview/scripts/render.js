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

  /**
   * 从 `from` 起找下一个**可能是围栏**的标记位置（行首 0–3 空格之后的 ``` / ~~~）。
   *
   * 为什么不用「按行切分再逐行测」：这条路径每一帧都跑，240KB 文档有 6,000 行，
   * 每行一次 `slice` + 一次正则 ≈ 4–5ms。围栏只出现在少数几行，用 `indexOf`
   * 在两个标记之间跳，代价只跟**标记个数**有关。
   *
   * 4 空格缩进是缩进代码块，里面的 ``` 只是字面文本，不是围栏（CommonMark）。
   */
  function findFenceMarker(src, from) {
    var i = from;
    while (i < src.length) {
      var tick = src.indexOf('```', i);
      var tilde = src.indexOf('~~~', i);
      var pos;
      if (tick === -1) pos = tilde;
      else if (tilde === -1) pos = tick;
      else pos = tick < tilde ? tick : tilde;
      if (pos === -1) return -1;
      if (isAtLineStart(src, pos)) return pos;
      i = pos + 1;
    }
    return -1;
  }

  /** `pos` 之前只有行首或 0–3 个空格？ */
  function isAtLineStart(src, pos) {
    var k = pos - 1;
    var spaces = 0;
    while (k >= 0 && src.charCodeAt(k) === 32 && spaces <= 3) {
      spaces += 1;
      k -= 1;
    }
    if (spaces > 3) return false;
    return k < 0 || src.charCodeAt(k) === 10;
  }

  /** `[from, to)` 是否只有空白（空格 / 制表 / CR）。 */
  function isBlankRange(src, from, to) {
    for (var i = from; i < to; i++) {
      var c = src.charCodeAt(i);
      if (c !== 32 && c !== 9 && c !== 13) return false;
    }
    return true;
  }

  /**
   * 摘出 ```mermaid 围栏块，换成占位 div，marked 之后再交给 mermaid 渲染。
   *
   * **围栏配对必须按 CommonMark 规则扫描**，不能像改前那样用
   * `/```mermaid[^]*?```/g` 找最近的收尾。那条正则不认围栏规则，代价是：
   * 正文里只要出现一处 ```mermaid（行中间的、被外层围栏包着的、教程里描述写法的），
   * 它就会和后面**任意**一个 ``` 配成一对，中间内容被整段摘走当成交给 mermaid
   * 的代码——CHANGELOG 实测吞掉 19,370 字符。而且是**消失**而不是退化成代码块，
   * 用户没有任何线索。
   *
   * 现在的判定：
   *   - 开栏行 0–3 空格缩进，≥3 个同字符；反引号围栏的 info 里不能再有反引号
   *    （否则行内代码 ```` ``` ``` ```` 会被当成围栏）；
   *   - 关栏行只能有围栏字符与空白，且长度 ≥ 开栏长度（```` 能关 ```，反之不能）；
   *   - **所有**围栏都要跨过（含 `~~~`、含 `swift` 这类非 mermaid 语言），
   *     围栏内的 ``` 只是文本；
   *   - 只有「反引号开栏 + info 首 token 恰为 `mermaid`（区分大小写）」才出图。
   *     这两个限定与 Swift 侧 `MermaidBlocks` 是同一口径——诊断校验的块必须
   *     恰好是预览会渲染成图的块，否则报的是用户看不见的错。
   *
   * 未闭合的 mermaid 围栏**不出图**（没有关栏行就没有块边界，marked 会把它
   * 当普通代码块渲染到文末），保持与预览一致。
   */
  function extractMermaid(content) {
    var src = content || '';
    // 快路径：没有 ``` 或压根没出现 "mermaid" ⇒ 不可能有 mermaid 围栏。
    // 这份函数每帧都跑，绝大多数文档根本不含这两个串。
    if (src.indexOf('```') === -1 || src.indexOf('mermaid') === -1) {
      return { processed: src, diagrams: [] };
    }

    var diagrams = [];
    var pieces = [];
    var cursor = 0;        // 已原样写出的位置
    var open = null;       // { char, len, info, lineStart, bodyStart }
    var pos = 0;

    while (true) {
      var mk = findFenceMarker(src, pos);
      if (mk === -1) break;

      var ch = src.charAt(mk);
      var len = 1;
      while (mk + len < src.length && src.charAt(mk + len) === ch) len += 1;
      var markerEnd = mk + len;
      var nl = src.indexOf('\n', mk);
      var lineEnd = nl === -1 ? src.length : nl;
      var lineStart = mk === 0 ? 0 : src.lastIndexOf('\n', mk - 1) + 1;

      if (open) {
        // 关栏：同字符 + 长度不小于开栏 + 行尾只有空白。
        // 出图只认反引号开栏（与 Swift 侧 MermaidBlocks 同口径）——
        // ~~~mermaid 是合法围栏但不产图，此前漏判 char 会被摘成 diagram。
        if (ch === open.char && len >= open.len && isBlankRange(src, markerEnd, lineEnd)) {
          if (open.char === '`' && open.info === 'mermaid') {
            var id = 'mermaid-' + diagrams.length;
            diagrams.push({ id: id, code: src.slice(open.bodyStart, lineStart).trim() });
            pieces.push(src.slice(cursor, open.lineStart));
            pieces.push('<div class="mermaid-placeholder" id="' + id + '"></div>');
            // 只吃到关栏行行尾、**保留换行**：占位 div 与后面的正文必须各占一行，
            // 否则会并成同一个 HTML 块、正文被吞进 div 里。
            cursor = lineEnd;
          }
          open = null;
        }
        pos = lineEnd + 1;
        continue;
      }

      // 开栏
      var s = markerEnd;
      while (s < lineEnd && (src.charCodeAt(s) === 32 || src.charCodeAt(s) === 9)) s += 1;
      var e = s;
      while (e < lineEnd) {
        var c = src.charCodeAt(e);
        if (c === 32 || c === 9 || c === 13) break;
        e += 1;
      }
      if (ch === '`' && src.indexOf('`', markerEnd) !== -1 && src.indexOf('`', markerEnd) < lineEnd) {
        pos = lineEnd + 1;   // info 里带反引号 ⇒ 不是围栏（行内代码）
        continue;
      }
      // info string 取首个 token：```mermaid theme=dark 也算 mermaid 块
      open = { char: ch, len: len, info: src.slice(s, e), lineStart: lineStart, bodyStart: lineEnd + 1 };
      pos = lineEnd + 1;
    }

    pieces.push(src.slice(cursor));
    return { processed: pieces.join(''), diagrams: diagrams };
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
    // 快路径：没有 '$' 就不可能有公式——省掉三趟全长遮蔽正则（每趟都产生
    // 一个与原文等长的新字符串）与全文扫描。收益主要是省分配（实测正则本身
    // 仅 ~0.2ms/420KB），但这条路径每帧都跑。
    if (src.indexOf('$') === -1) return { processed: src, items: [] };
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
  function normalizedMathHTML(el, html) {
    if ((html || el.innerHTML).indexOf(MATH_ID_PREFIX) === -1) return null;
    var clone = el.cloneNode(true);
    var placeholders = clone.querySelectorAll('.' + MATH_INLINE_CLASS + ', .' + MATH_BLOCK_CLASS);
    for (var i = 0; i < placeholders.length; i++) {
      var node = placeholders[i];
      while (node.firstChild) node.removeChild(node.firstChild);
    }
    return clone.innerHTML;
  }

  /**
   * 给 marked 的三条块规则加「前置判据」，把 JSC 的 O(n) 失败路径短路掉。
   *
   * 背景（实测，jsc 与 WKWebView 同引擎）：JSC 的 YARR 对**部分** anchored 正则不做
   * 「只在位置 0 尝试」的优化，一旦匹配失败就会沿整串走一遍。`html` 规则含反向引用
   * `\1`，120KB 输入上失败一次要 **1.9ms**；而 marked 每产出一个 block token 就要把
   * ~12 条规则对**剩余全文**各试一遍 ⇒ O(n²)（120KB 技术文档整篇解析 1256ms，
   * 同一份 marked 在 V8 上只要 8.9ms）。
   *
   * 三条规则的首个有效字符是固定的（html 必是 `<`、blockquote 必是 `>`、hr 必是
   * `-`/`_`/`*`，且前面最多 3 个空格），用 charCodeAt 判一下就能免掉整趟扫描。
   * 判据只做「不可能匹配时提前返回」，能匹配时仍交给原正则 ⇒ 语义不可能变。
   *
   * ⚠️ 数值下标：`<` 60 / `>` 62 / `-` 45 / `_` 95 / `*` 42。
   */
  function installMarkedFastPathGuards() {
    var rules = typeof marked !== 'undefined' && marked.Lexer &&
      marked.Lexer.rules && marked.Lexer.rules.block && marked.Lexer.rules.block.gfm;
    if (!rules) return;   // marked 版本变了：宁可不加判据，也不要抛错

    function firstNonSpaceIn(src, codes) {
      var i = 0;
      while (i < 3 && src.charCodeAt(i) === 32) i++;
      return codes.indexOf(src.charCodeAt(i)) !== -1;
    }

    function guarded(re, cheap) {
      return {
        source: re.source, flags: re.flags, global: false,
        ignoreCase: re.ignoreCase, multiline: re.multiline,
        sticky: false, unicode: re.unicode, lastIndex: 0,
        exec: function (src) { return cheap(src) ? re.exec(src) : null; },
        test: function (src) { return cheap(src) ? re.test(src) : false; }
      };
    }

    var guards = {
      html: function (src) { return firstNonSpaceIn(src, [60]); },
      blockquote: function (src) { return firstNonSpaceIn(src, [62]); },
      hr: function (src) { return firstNonSpaceIn(src, [45, 95, 42]); }
    };
    for (var name in guards) {
      if (rules[name]) rules[name] = guarded(rules[name], guards[name]);
    }
  }

  installMarkedFastPathGuards();

  // Paragraph-level parse cache: avoids re-parsing unchanged paragraphs.
  // Key = paragraph text (exact match, no hash collision risk).
  // Value = **已消毒**的 HTML（命中即跳过 marked.parse 与 DOMPurify 两道）。
  //
  // 预算按**源码字节**而不是条目数：条目数 × 单块上限会被两个上限相乘地卡死——
  // 旧配置「300 条 × 单块 2KB」意味着真实文档里 2–5KB 的段落（带表格的小节、
  // 长列表项）**一条都进不来**，实测 178KB 文档改一段仍然等同冷启。
  var paragraphCache = new Map();
  var paragraphCacheBytes = 0;
  var PARAGRAPH_CACHE_MAX_BYTES = 4 * 1024 * 1024;
  var PARAGRAPH_CACHE_MAX_BLOCK = 256 * 1024;

  /**
   * 渲染计数：只数不改行为，给测试把「性能主张」钉住。
   *
   * 「分块缓存生效」这个说法无法用产物正确性的测试证明——删掉整个缓存、每次都整篇
   * 解析，产物依然逐字节正确。所以需要出口：命中/重解析/整篇兜底/消毒各调用了几次。
   * 测试断言的是这组比值，不是耗时（耗时在 CI 机器上不稳定）。
   */
  var renderStats = { fullParse: 0, blockParse: 0, blockHit: 0, sanitize: 0, noopSkip: 0,
    patchGroupsCompared: 0, patchGroupsReplaced: 0, patchBail: 0 };
  /**
   * 上一次成功渲染的 join 产物（no-op 短路用，见 renderInto）。
   *
   * ⚠️ 这是**整个 WKWebView 的 JS 上下文级状态**，而预览的 webview 跨文档复用
   * （切 tab 只换内容，不重建 NSView）。所以任何**绕过 renderInto 直接改 DOM**
   * 的路径都必须调 `invalidateLastRender()`，否则这里会停在别的文档的产物上。
   * 目前唯一的这种路径是 bridge 的缓存命中恢复（直接写 `contentEl.innerHTML`）。
   */
  var lastRenderedHTML = null;
  /** 组路径（html 为 null 推迟拼接）的 no-op 判据：上轮的组 key 序列。 */
  var lastRenderedGroupKeys = null;

  /** 外部改写了 DOM 之后作废短路状态（见 lastRenderedHTML 的 ⚠️）。 */
  function invalidateLastRender() {
    lastRenderedHTML = null;
    lastRenderedGroupKeys = null;
  }

  function sameGroupKeys(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
    return true;
  }

  /**
   * 顶层开栏判定：零缩进 + ≥3 个反引号或波浪号；反引号围栏的 info 里
   * 再出现反引号 ⇒ 该行**不是**围栏（CommonMark：那种写法是行内代码）。
   * splitBlocks / padStructureLines 都走这一个判据（extractMermaid 有自己的
   * 行循环，含 info 解析，口径已逐条对齐）——三套围栏判定若各写一份，
   * 失同步就是「分块与整篇解析出口不等价」的直接来源。
   *
   * @param {string} line 一行原文（不含 \n）
   * @returns {{char: string, len: number}|null}
   */
  function fenceOpenInfo(line) {
    var m = /^(`{3,}|~{3,})/.exec(line);
    if (!m) return null;
    if (m[1].charAt(0) === '`' && line.indexOf('`', m[1].length) !== -1) return null;
    return { char: m[1].charAt(0), len: m[1].length };
  }

  /** 闭合围栏行：CommonMark 允许 0–3 空格缩进，其后只能有空白。 */
  var FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})\s*$/;
  /** 带缩进的围栏行——可能是列表项里的围栏，其容器上下文我们还原不了。 */
  var FENCE_INDENTED = /^\s+(`{3,}|~{3,})/;

  /** 无缩进的列表项行（`- ` / `* ` / `+ ` / `1. ` / `1) `）。 */
  var LIST_ITEM_LINE = /^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)/;

  /**
   * 会**跨空行**的 HTML 块起始（CommonMark 类型 1–5）。
   * 类型 6/7（块级标签、完整标签）到下一个空行就结束，按空行切是安全的。
   */
  var HTML_SPANNING_OPEN = /^ {0,3}(?:<(script|pre|style|textarea)(?=[\s>]|$)|<!--|<\?|<!\[CDATA\[|<![A-Z])/i;

  function hasListItemLine(block) {
    var lines = block.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (LIST_ITEM_LINE.test(lines[i])) return true;
    }
    return false;
  }

  function startsWithListItem(block) {
    var lines = block.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] !== '') return LIST_ITEM_LINE.test(lines[i]);
    }
    return false;
  }

  /**
   * 跨空行 HTML 的结束标记是否已经出现（`rest` 里）。
   *
   * 这是跨空行 HTML 判据的后半段，单独提出来是因为合并组要**增量**累积
   * ——历史上这里每次合并都把整组拼成一个字符串再重扫，O(n²)。
   */
  function spanningClosed(rest, name, head) {
    if (name) return rest.toLowerCase().indexOf('</' + name + '>') !== -1;
    if (head.indexOf('<!--') !== -1) return rest.indexOf('-->') !== -1;
    if (head.indexOf('<?') !== -1) return rest.indexOf('?>') !== -1;
    if (head.indexOf('CDATA') !== -1) return rest.indexOf(']]>') !== -1;
    return rest.indexOf('>') !== -1;                 // <!DOCTYPE 之类
  }

  /**
   * 块开头是一个跨空行的 HTML 块时的状态：`{ name, head, closed }`。
   * `closed === false` 即「这个结构在块内还没闭合」，需要把下一块也合进来。
   *
   * `HTML_SPANNING_OPEN` 锚定 `^` ⇒ 只有组**首段**能决定它，合并进来的后续段
   * 只可能改变 `closed`。
   */
  function spanningState(block) {
    var m = HTML_SPANNING_OPEN.exec(block);
    if (!m) return null;
    var name = m[1] ? m[1].toLowerCase() : null;
    var head = m[0];
    return {
      name: name,
      head: head,
      closed: spanningClosed(block.slice(head.length), name, head)
    };
  }

  /** 块级 HTML 起始行（`<div …`、`</div>`、`<!--`…）。 */
  var HTML_BLOCK_START = /^ {0,3}<[a-zA-Z!/?]/;

  /** HTML 空元素：不会再有闭合标签。 */
  var VOID_ELEMENTS = {
    area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1,
    input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1
  };

  /**
   * 块以 `<tag …>` 开头时的开闭计数状态：`{ tag, openRe, closeRe, opens, closes }`。
   * `opens > closes` 即「这个元素在块内还没闭合」，需要把下一块也合进来。
   *
   * 为什么要管类型 6/7 的块级标签（本来不跨空行）：单独把 `<div class="x">` 送去
   * sanitize 时 DOMPurify 会当成不完整片段丢掉，整篇解析里它却是合法父节点
   * ⇒ 两侧产物不同。所以按「开闭标签计数」判，与规范无关，只关心消毒器看到的
   * 片段是否自洽。
   *
   * 标签名由块**首段**决定（正则锚定 `^`），后续合并进来的段只累加计数。
   */
  function elemState(block) {
    if (!HTML_BLOCK_START.test(block)) return null;
    var m = /^ {0,3}<([a-zA-Z][\w-]*)\b/.exec(block);
    if (!m) return null;
    var tag = m[1].toLowerCase();
    if (VOID_ELEMENTS[tag]) return null;
    var st = {
      tag: tag,
      openRe: new RegExp("<" + tag + "\\b", "gi"),
      closeRe: new RegExp("</" + tag + "\\s*>", "gi"),
      opens: 0,
      closes: 0
    };
    addElemCounts(st, block);
    return st;
  }

  /** 把一段文本里的开/闭标签数累加进状态（`match` 对 g 正则会重置，这里也显式清 lastIndex）。 */
  function addElemCounts(st, block) {
    st.openRe.lastIndex = 0;
    st.closeRe.lastIndex = 0;
    st.opens += (block.match(st.openRe) || []).length;
    st.closes += (block.match(st.closeRe) || []).length;
  }

  /**
   * 合并判据：右块接在左组后面会不会改变语义。
   *
   * 左组用**摘要**判断（`hasList` / `span` / `elem`），不再每轮把整组拼成字符串重扫。
   *
   * 这里是上一版真正的 O(n²)：`left + '\n\n' + right` 只是 second-order 的表象
   * ——JSC 把 `+` 的结果当 rope（cons string），不立即复制。真正贵的是**每轮都要
   * 把整组 flatten 一次**再交给 `hasListItemLine`（内部 `split('\n')`）、
   * `spanningState`（`indexOf`）、`elemState`（两次 `match`），这四条都是 O(整组)。
   *
   * 实测一份 240KB 松散列表：切成约 8,000 块、块块都要合并 ⇒ 合并耗掉 888ms，
   * 而同一份文档的整篇解析只要 70ms（优化比不优化慢 12 倍）；嵌套列表 1769ms
   * vs 339ms。现在这三条判据都改成随合并增量维护摘要，同一份文档降到 72ms / 357ms。
   */
  function shouldJoinGroup(g, right) {
    if (/^[ \t]/.test(right)) return true;                        // 缩进续行
    if (startsWithListItem(right) && g.hasList) return true;       // 松散列表
    if (g.span !== null && !g.span.closed) return true;            // 跨空行 HTML（类型 1–5）
    if (g.elem !== null && g.elem.opens > g.elem.closes) return true;  // 未闭合的块级标签
    return false;
  }

  /** 把右块并入左组：只更新摘要，不拼接字符串。 */
  function absorbIntoGroup(g, right) {
    if (!g.hasList) g.hasList = hasListItemLine(right);
    if (g.span !== null && !g.span.closed) {
      g.span.closed = spanningClosed(right, g.span.name, g.span.head);
    }
    if (g.elem !== null) addElemCounts(g.elem, right);
  }

  /**
   * 把「切在这里会改变语义」的相邻块合回去。
   *
   * 按空行切对**跨空行的结构**无解，实测有这些差异（整篇解析 vs 分块解析）：
   * - 松散列表 `1. 甲\n\n2. 乙` 被切成两个 `<ol>`、丢 `<li><p>`；
   * - 列表项的第二段（`- 甲\n\n  续段`）掉出列表；
   * - `<!--\n\n注释\n\n-->` 被拆开，`-->` 漏成正文；
   * - `<div>` 与 `</div>` 落在不同块 ⇒ DOMPurify 逐块消毒时把未闭合片段丢掉，
   *   与整篇消毒结果不同。
   *
   * 合并永远**不会**产生错误输出（整篇解析就是参考答案），代价只是丢掉这一段
   * 的缓存粒度 ⇒ 判据取「宁可多合，不可切错」，与 splitBlocks 的取舍一致。
   *
   * 实现上组内用 `parts` 数组累积、最后一次性 `join`：判据依赖的三个整块属性
   * （有没有列表项行 / 跨行 HTML 是否已闭合 / 块级标签开闭计数）都是可增量维护的
   * ⇒ 每块只被扫常数次，总量 O(n)。逐块重扫整组才是平方的来源，见 shouldJoinGroup。
   *
   * @returns {string[]} 合并后的块数组
   */
  function mergeUnsafeBoundaries(blocks) {
    if (blocks.length < 2) return blocks;

    var groups = [];
    var g = null;

    for (var i = 0; i < blocks.length; i++) {
      var right = blocks[i];
      if (g !== null && shouldJoinGroup(g, right)) {
        g.parts.push(right);
        absorbIntoGroup(g, right);
      } else {
        g = {
          parts: [right],
          hasList: hasListItemLine(right),
          span: spanningState(right),
          elem: elemState(right)
        };
        groups.push(g);
      }
    }

    var out = new Array(groups.length);
    for (var k = 0; k < groups.length; k++) out[k] = groups[k].parts.join('\n\n');
    return out;
  }

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
   * **未闭合围栏不返回 null**：从开栏行到文末整体算作一块。这条路径是打字过程中
   * 每一帧都会走的（敲下 ``` 的那一刻），此前返回 null 等于每敲一个键都付一次
   * 整篇 marked + 整篇 DOMPurify。整块切法在语义上是等价的——CommonMark 里未闭合
   * 围栏本来就吞到文末，单独解析这一段与整篇解析该段的结果相同。
   *
   * @returns {string[]|null} 块数组；仅在遇到带缩进的围栏时返回 null。
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

      var open = fenceOpenInfo(line);
      if (open) {
        fence = open;
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

    // 围栏未闭合（流式写入 / 刚敲下开栏行）：余下全文算一块，**不回退整篇解析**。
    // `current` 此时已经攒了从开栏行前那一块起、到文末的全部行（含空行——
    // 围栏内的空行走上面的 continue，不会被当分隔符）。
    if (fence) {
      if (current.length > 0) blocks.push(current.join('\n'));
      return mergeUnsafeBoundaries(blocks);
    }

    if (current.length > 0) blocks.push(current.join('\n'));
    return mergeUnsafeBoundaries(blocks);
  }

  /**
   * Render markdown by splitting into blocks (paragraphs separated by blank lines),
   * caching each block's HTML independently. Only changed blocks hit marked.parse.
   * Falls back to full parse for cross-block structures (link reference definitions)
   * and for indented fences (list-item containers we cannot reconstruct).
   *
   * 未闭合围栏**不再**回退整篇：见 splitBlocks 的说明。这条路径是打字时的每一帧。
   *
   * 命中分块路径时除了拼好的 HTML 还返回**组数组**（`{ key, html }`，key 即组原文），
   * 让 renderInto 能做块对齐的 DOM patch——「哪些组没变」的信息走到 DOM 层，
   * 未变化组零解析、零序列化、零比较。回退整篇解析时 groups 为 null。
   */
  function renderMarkdownBlocks(content) {
    // Fallback: link reference definitions are cross-block state.
    // 冒号后的空白不是必需的（`[bar]:https://x` 也是合法定义），此前要求 `\s`
    // 会把这种写法漏过去 ⇒ 定义块单独解析成空串、正文留 `[bar]`，链接静默丢失。
    // 定义还能出现在容器里（blockquote `> [x]: /u`、列表项缩进 `    [x]: /u`），
    // 同样是文档级生效——判据放宽到「任意前导空白/引用符」，宁可多回退
    // （代码块里写 `[a]: b` 会误触发整篇解析，只丢缓存），不可漏检丢链接。
    if (/^[ \t>]*\[[^\]\n]+\]:/m.test(content)) {
      return { html: renderMarkdown(content), groups: null, totalLen: 0 };
    }

    // 围栏内部不切块 ⇒ 含代码块的文档也能命中块级缓存。
    // 此前这里是「任意位置出现围栏就放弃分块」，而技术文档几乎必然含代码块，
    // 等于缓存对目标用户基本失效（757KB 实测全量 marked.parse 98.7ms，
    // 每一轮防抖更新都要重付一次）。
    var blocks = splitBlocks(content);
    if (!blocks || blocks.length <= 2) {
      return { html: renderMarkdown(content), groups: null, totalLen: 0 };
    }

    var groups = new Array(blocks.length);
    var totalLen = 0;

    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      var html = '';
      if (block.trim()) {
        var cached = cacheGet(block);
        if (cached !== null) {
          renderStats.blockHit++;
          html = cached;
        } else {
          renderStats.blockParse++;
          html = sanitizeHTML(marked.parse(fixTableSeparators(block), { gfm: true, breaks: false }));
          cachePut(block, html);
        }
      }
      groups[i] = { key: block, html: html };
      totalLen += html.length + 1;
    }

    return { html: null, groups: groups, totalLen: totalLen };
  }

  /** 组 HTML 拼回整篇（与旧的 htmlParts.join('\n') 同口径）。 */
  function joinGroupHTML(groups) {
    var parts = new Array(groups.length);
    for (var i = 0; i < groups.length; i++) parts[i] = groups[i].html;
    return parts.join('\n');
  }

  function renderMarkdownCached(content) {
    var rendered = renderMarkdownBlocks(content);
    return rendered.groups ? joinGroupHTML(rendered.groups) : rendered.html;
  }

  /**
   * 读缓存。超单块上限的块不进缓存（一次改动就要整块重算，缓存它只占内存）。
   * @returns {string|null} 命中返回已消毒 HTML；未命中返回 null。
   */
  function cacheGet(block) {
    if (block.length > PARAGRAPH_CACHE_MAX_BLOCK) return null;
    return paragraphCache.has(block) ? paragraphCache.get(block) : null;
  }

  /** 写缓存，并按源码字节预算做 FIFO 淘汰（Map 的插入顺序即写入顺序）。 */
  function cachePut(block, html) {
    if (block.length > PARAGRAPH_CACHE_MAX_BLOCK) return;
    if (!paragraphCache.has(block)) paragraphCacheBytes += block.length;
    paragraphCache.set(block, html);
    while (paragraphCacheBytes > PARAGRAPH_CACHE_MAX_BYTES && paragraphCache.size > 1) {
      var oldest = paragraphCache.keys().next().value;
      paragraphCacheBytes -= oldest.length;
      paragraphCache.delete(oldest);
    }
  }

  /**
   * 结构行后补空行：标题 / 分隔线后紧跟非空行时插入空行（marked 需要）。
   * 必须围栏感知：两条裸正则会把空行插进围栏内部的 `# 注释` / `---` 之后，
   * 改写代码内容。已知边界：缩进围栏（列表项内）不做状态跟踪——与旧实现同。
   */
  function padStructureLines(content) {
    var lines = content.split('\n');
    var out = [];
    var fence = null;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      out.push(line);
      if (fence) {
        var close = FENCE_CLOSE.exec(line);
        if (close && close[1].charAt(0) === fence.char && close[1].length >= fence.len) {
          fence = null;
        }
        continue;
      }
      var open = fenceOpenInfo(line);
      if (open) { fence = open; continue; }
      var next = i + 1 < lines.length ? lines[i + 1] : '';
      if (next !== '' && next !== '\r'
          && (/^#{1,6}\s+\S/.test(line) || /^(---+|\*\*\*+|___+)[ \t\r]*$/.test(line))) {
        out.push('');
      }
    }
    return out.join('\n');
  }

  function renderMarkdown(content) {
    renderStats.fullParse++;
    var processed = fixTableSeparators(padStructureLines(content));
    return sanitizeHTML(marked.parse(processed, { gfm: true, breaks: false }));
  }

  // marked 不做任何消毒，其输出直接 innerHTML 会让恶意 markdown 注入
  // <script>/onerror 等载荷（XSS，进而借 meditor-asset:// 读盘外泄）。
  // 所有渲染出口统一在这里过 DOMPurify；ALLOWED_URI_REGEXP 在默认白名单
  // 协议上额外放行 file: 和 meditor-asset:（本地图片路径，点击导航由
  // Swift 侧 PreviewLinkNavigator 拦截，不会在 webview 内打开）。
  var SANITIZE_URI_REGEXP = /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|file|meditor-asset):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;

  function sanitizeHTML(html) {
    renderStats.sanitize++;
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

  /** 给缺 id 的标题补 id（作者自己写了 id 的一律不动）。 */
  function stampHeadingIDs(rootEl) {
    var headings = rootEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
    if (headings.length === 0) return;
    var used = Object.create(null);
    for (var i = 0; i < headings.length; i++) {
      var el = headings[i];
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

  function highlightCodeBlocks(rootEl) {
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

  /**
   * bridge 的缓存命中恢复路径用：快照里的 mermaid 是「视口懒渲染」之前的形态。
   *
   * `renderMermaidDiagrams` 给每个占位挂 IntersectionObserver，只画滚进视口的图；
   * 而缓存命中会把 `contentEl.innerHTML` 整体换掉 —— 上一轮挂的观察器随旧节点一起
   * 失效，没滚到的那几张就再也没人管：表现为「切走再切回，图永久空白」。
   *
   * 这里按源码重新提取一次（id 由围栏顺序决定，与生成快照时同一份源码 ⇒ 编号一致），
   * 把观察器挂回占位。已经渲染过的图在 DOM 里是 `.mermaid-container`（占位 div 被
   * outerHTML 整个换掉、id 也一并没了），`getElementById` 取不到 ⇒ 天然幂等。
   */
  function restoreMermaid(content) {
    var extracted = extractMermaid(content || '');
    renderMermaidDiagrams(extracted.diagrams);
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
   *  and cuts DOM rebuild cost by 60-90% during typical editing.
   *
   *  分块路径下走**块对齐 patch**（patchDOMGroups）：组数组带着「哪些组变了」
   *  一直到 DOM 层，未变化组不再付出 temp.innerHTML 解析与 nodesEqual 的
   *  innerHTML 序列化比较（885KB 文档无变化热更新 ~41ms 的主要构成）。 */
  function renderInto(targetEl, content) {
    try {
      var extracted = extractMermaid(content || '');
      // 数学在 mermaid 之后摘：mermaid 代码块此时已被换成占位 div，
      // 里面的 `$` 不会误入公式识别。
      var math = extractMath(extracted.processed);
      var rendered = renderMarkdownBlocks(math.processed);
      var groups = rendered.groups;
      var html = rendered.html;

      // no-op 短路：产物与上轮完全一致时跳过 patchDOM 及全部后续 pass。
      // 存的是 join 产物（**不是** DOM 的 innerHTML——Copy 按钮 / hljs span /
      // KaTeX 结果会污染 DOM，那样比永远不等、短路永不触发）。前提是 DOM 仍等于
      // 上轮画出来的那份：任何外部改写 DOM 的路径必须先 invalidateLastRender()，
      // 否则这里会拿上一个文档的产物比，误判 no-op 后什么都不画（见该函数注释）。
      // 组信息可用时 html 为 null（拼接推迟到真正需要时）——此时比组 key 序列，
      // 绝不能拿 null 比 null（那样 no-op 短路永远命中，什么都不画）。
      var groupKeys = groups ? groups.map(function (g) { return g.key; }) : null;
      var noChange = html !== null
        ? (html === lastRenderedHTML)
        : (groupKeys !== null && lastRenderedGroupKeys !== null
           && sameGroupKeys(groupKeys, lastRenderedGroupKeys));
      if (noChange) { renderStats.noopSkip++; return; }

      // Incremental update: 块对齐优先（对组信息可用的文档**不设体积上限**——
      // 500KB 上限护的是整篇 temp.innerHTML + 全树比较，而块对齐的成本只随
      // 变化组走，恰恰是大文档收益最大）；对齐失稳 / 无组信息回退全树 diff。
      var totalLen = groups ? rendered.totalLen : html.length;
      if (targetEl.children.length > 0) {
        var updated = groups ? patchDOMGroups(targetEl, groups) : false;
        if (!updated && totalLen < 500000) {
          if (groups) html = joinGroupHTML(groups);
          updated = patchDOM(targetEl, html);
          // 全树 diff 成功后重建组范围记录，下一帧起恢复块对齐
          if (updated && groups) recordGroupRanges(targetEl, groups);
          if (!groups) lastGroupPatch = null;
        }
        if (updated) {
          lastRenderedHTML = html;
          lastRenderedGroupKeys = groupKeys;
          stampHeadingLines(targetEl, content || '');
          stampHeadingIDs(targetEl);
          highlightCodeBlocks(targetEl);
          renderMermaidDiagrams(extracted.diagrams);
          renderMath(math.items);
          rewriteAbsoluteAssetPaths(targetEl);
          return;
        }
        lastGroupPatch = null;   // 落到全量替换：范围记录作废
      }

      // Fallback: full replace (first render or very large docs)
      if (groups && html === null) html = joinGroupHTML(groups);
      targetEl.innerHTML = html;
      if (html.indexOf('<table') !== -1) wrapTablesIn(targetEl);
      stampHeadingLines(targetEl, content || '');
      stampHeadingIDs(targetEl);
      highlightCodeBlocks(targetEl);
      renderMermaidDiagrams(extracted.diagrams);
      renderMath(math.items);
      rewriteAbsoluteAssetPaths(targetEl);
      lastRenderedHTML = html;
      lastRenderedGroupKeys = groupKeys;
      // 首帧就建立组范围记录（自校验，对不上就放弃），让第一次更新就能走块对齐
      if (groups) recordGroupRanges(targetEl, groups);
      else lastGroupPatch = null;
    } catch (e) {
      targetEl.innerHTML = '<div class="error-block">Render error: ' + String(e && e.message || e) + '</div>';
      lastGroupPatch = null;
    }
  }

  /**
   * 上一帧块对齐 patch 留下的「组 → #content 顶层子节点范围」记录：
   * `{ target, groups: [{ key, start, count }] }`。count 以**包裹后**的 DOM
   * 为准（table 先包 .table-wrapper 再计数），start 冗余存一份便于排查。
   *
   * 凡是绕过 renderInto 直接改写 #content 的入口（bridge 的缓存命中恢复）
   * 都必须调 notifyExternalDOMReset 作废它——按过期范围替换会错位。
   */
  var lastGroupPatch = null;

  /** 给 rootEl 下未包裹的 table 包一层 .table-wrapper（横向滚动容器）。 */
  function wrapTablesIn(rootEl) {
    var tables = rootEl.querySelectorAll('table:not(.table-wrapper table)');
    for (var t = 0; t < tables.length; t++) {
      if (tables[t].parentElement && tables[t].parentElement.className === 'table-wrapper') continue;
      var wrapper = document.createElement('div');
      wrapper.className = 'table-wrapper';
      tables[t].parentNode.insertBefore(wrapper, tables[t]);
      wrapper.appendChild(tables[t]);
    }
  }

  /**
   * 块对齐增量 patch：按组原文 key 做前后缀对齐（首个变化组之前的部分逐组
   * 相等、尾部同理，中间一段视为变化区），只对变化组做 `temp.innerHTML`
   * （单组体积）并替换对应 DOM 子区间；未变化组零解析、零序列化、零比较。
   *
   * - 文首插入 ⇒ 前缀 0、后缀全对上 ⇒ 只插一组，后续组的节点原样保留不错位；
   * - mermaid/math 占位 div 在组 HTML 里，随组替换后由 patch 之后的
   *   renderMermaidDiagrams / renderMath 重新填充；
   * - 对齐失稳（无记录 / 记录的总子节点数与真实 DOM 对不上）⇒ 返回 false，
   *   调用方回退全树 patchDOM——宁可慢一帧，不可按错范围替换。
   */
  function patchDOMGroups(targetEl, groups) {
    var old = (lastGroupPatch && lastGroupPatch.target === targetEl) ? lastGroupPatch.groups : null;
    if (!old) { renderStats.patchBail++; return false; }

    var i;
    var oldCount = 0;
    for (i = 0; i < old.length; i++) oldCount += old[i].count;
    if (oldCount !== targetEl.children.length) { renderStats.patchBail++; return false; }

    // 前后缀对齐：key 是组原文，渲染对同一原文确定 ⇒ key 相等即 HTML 相等。
    // 重复组（两处一样的段落）按位置对齐也安全——同 key 同产物，替换是恒等操作。
    var p = 0;
    while (p < old.length && p < groups.length && old[p].key === groups[p].key) p++;
    var s = 0;
    while (s < old.length - p && s < groups.length - p &&
           old[old.length - 1 - s].key === groups[groups.length - 1 - s].key) s++;

    renderStats.patchGroupsCompared += groups.length;
    var midNew = groups.length - p - s;

    // 变化区对应的 DOM 子节点区间 [start, end)
    var start = 0;
    for (i = 0; i < p; i++) start += old[i].count;
    var end = start;
    for (i = p; i < old.length - s; i++) end += old[i].count;
    var refNode = end < targetEl.children.length ? targetEl.children[end] : null;

    // 只解析变化组；表格在插入前就包好，保证「计数的结构 = 进 DOM 的结构」
    var fragment = document.createDocumentFragment();
    var midCounts = new Array(midNew);
    var temp = document.createElement('div');
    for (i = 0; i < midNew; i++) {
      var g = groups[p + i];
      temp.innerHTML = g.html;
      if (g.html.indexOf('<table') !== -1) wrapTablesIn(temp);
      midCounts[i] = temp.children.length;
      while (temp.firstElementChild) fragment.appendChild(temp.firstElementChild);
    }

    // children 是 live 集合：逐个删 [start, end)，删完 refNode 仍指向后缀首节点
    for (i = start; i < end; i++) targetEl.removeChild(targetEl.children[start]);
    if (refNode) targetEl.insertBefore(fragment, refNode);
    else targetEl.appendChild(fragment);

    renderStats.patchGroupsReplaced += midNew;

    // 记录新范围：前/后缀组沿用在位节点的 count（同 key ⇒ 同顶层结构），
    // 变化组用刚数出的 count。
    var recorded = new Array(groups.length);
    var pos = 0;
    for (i = 0; i < p; i++) {
      recorded[i] = { key: groups[i].key, start: pos, count: old[i].count };
      pos += old[i].count;
    }
    for (i = 0; i < midNew; i++) {
      recorded[p + i] = { key: groups[p + i].key, start: pos, count: midCounts[i] };
      pos += midCounts[i];
    }
    for (i = 0; i < s; i++) {
      recorded[p + midNew + i] = {
        key: groups[p + midNew + i].key,
        start: pos,
        count: old[old.length - s + i].count
      };
      pos += old[old.length - s + i].count;
    }
    lastGroupPatch = { target: targetEl, groups: recorded };
    return true;
  }

  /**
   * 全量替换 / 全树 diff 之后重建组范围记录：逐组解析数顶层元素
   *（总量 ≈ 一次全文解析，只在建记录这一帧付出）。与真实 DOM 对不上
   *（结构不确定）就放弃记录——宁可下一帧仍走全树 diff，不可按错范围替换。
   */
  function recordGroupRanges(targetEl, groups) {
    var temp = document.createElement('div');
    var recorded = new Array(groups.length);
    var pos = 0;
    for (var i = 0; i < groups.length; i++) {
      var html = groups[i].html;
      temp.innerHTML = html;
      if (html.indexOf('<table') !== -1) wrapTablesIn(temp);
      var count = temp.children.length;
      recorded[i] = { key: groups[i].key, start: pos, count: count };
      pos += count;
    }
    if (pos !== targetEl.children.length) {
      renderStats.patchBail++;
      lastGroupPatch = null;
      return false;
    }
    lastGroupPatch = { target: targetEl, groups: recorded };
    return true;
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
    if (newHTML.indexOf('<table') !== -1) wrapTablesIn(targetEl);

    return true;
  }

  /**
   * `code` 元素的 className 归一化：剥掉 hljs 加的那个 class、压掉多余空白。
   * hljs 只加 `hljs` 一个 class（语言 class 是 marked 给的），所以剥掉它之后
   * 高亮前后可比。两侧都走这里，避免「只归一化一侧」的隐含顺序依赖。
   */
  function normalizeCodeClass(codeEl) {
    return codeEl.className
      .replace(/(?:^|\s)hljs(?=\s|$)/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /** Fast shallow equality check for two DOM elements. */
  function nodesEqual(a, b) {
    if (a.tagName !== b.tagName) return false;
    // For code blocks, compare textContent (cheaper than innerHTML).
    // Copy 按钮挂在 PRE 内（attachCopyButton），比 PRE 的 textContent 会带上
    // 按钮文字（"Copy"）导致永不相等——含代码块的文档每次更新都整体重建所有
    // PRE（随后被迫重高亮）。改比 code 子节点的 className + textContent。
    if (a.tagName === 'PRE') {
      var ac = a.querySelector('code');
      var bc = b.querySelector('code');
      if (ac && bc) {
        // 高亮过后 code 会多一个 hljs class——归一化掉再比，否则照样永不相等。
        // 两边都归一化（不是只剥 live DOM 那侧）：新 HTML 目前来自 marked 输出、
        // 天然没有 hljs，但「缓存里只存未高亮的 HTML」是个隐含前提——哪天高亮后
        // 的片段进了块缓存，只剥一侧就会退化成永不相等。
        return normalizeCodeClass(ac) === normalizeCodeClass(bc)
          && ac.textContent === bc.textContent;
      }
      return a.textContent === b.textContent;
    }
    // 含数学占位符的节点：DOM 里是 KaTeX 渲染结果、新 HTML 里是空占位符，
    // 直接比 innerHTML 永不相等（每次编辑都整块重建 + 重渲染公式）。
    // 归一化后外层走同一套字符串比较；不含数学的节点返回 null 走下面的快路径。
    // innerHTML 每读一次就把整棵子树重新序列化（JSC 不缓存）——各取一次存局部，
    // 探测复用这份字符串（此前一轮比较要读 ~6 次）。
    var aHTML = a.innerHTML;
    var bHTML = b.innerHTML;
    var aNormalized = normalizedMathHTML(a, aHTML);
    var bNormalized = normalizedMathHTML(b, bHTML);
    if (aNormalized !== null || bNormalized !== null) {
      return aNormalized === bNormalized;
    }
    // For everything else, compare outerHTML length first (fast reject),
    // then full comparison only if lengths match
    if (aHTML.length !== bHTML.length) return false;
    return aHTML === bHTML;
  }

  global.MEditorRender = {
    renderInto: renderInto,
    // bridge 的缓存命中恢复会绕过 renderInto 直接写 contentEl.innerHTML；
    // 写完必须调这个，否则 no-op 短路会拿上一个文档的产物做比较（见该函数注释）。
    invalidateLastRender: invalidateLastRender,
    // 纯函数出口：测试要做「分块 vs 整篇」的出口等价性比对，只能拿到这两个
    // 中间层（renderInto 会顺带 patchDOM，差异被 DOM 归一化吃掉）。
    renderMarkdown: renderMarkdown,
    renderMarkdownCached: renderMarkdownCached,
    // 渲染计数（见 renderStats 注释）：测试用它把「缓存真的生效」钉住，
    // 因为产物正确性测试对「整篇重解析」同样是绿的。
    getRenderStats: function () {
      var bytes = 0;
      var keys = paragraphCache.keys();
      for (var it = keys.next(); !it.done; it = keys.next()) bytes += it.value.length;
      return {
        fullParse: renderStats.fullParse,
        blockParse: renderStats.blockParse,
        blockHit: renderStats.blockHit,
        sanitize: renderStats.sanitize,
        noopSkip: renderStats.noopSkip,
        cacheEntries: paragraphCache.size,
        cacheBytes: bytes,
        // 块对齐 patch：对齐时看了多少组 / 实际替换了多少组 / 回退全树 diff 几次。
        // 「无变化更新 ⇒ patchGroupsReplaced === 0 且 patchBail === 0」可被测试断言。
        patchGroupsCompared: renderStats.patchGroupsCompared,
        patchGroupsReplaced: renderStats.patchGroupsReplaced,
        patchBail: renderStats.patchBail
      };
    },
    resetRenderStats: function () {
      renderStats.fullParse = 0;
      renderStats.blockParse = 0;
      renderStats.blockHit = 0;
      renderStats.sanitize = 0;
      renderStats.noopSkip = 0;
      renderStats.patchGroupsCompared = 0;
      renderStats.patchGroupsReplaced = 0;
      renderStats.patchBail = 0;
    },
    // 绕过 renderInto 直接改写 #content 的入口（bridge 的缓存命中恢复）
    // 必须调它作废组范围记录——按过期范围做块对齐替换会错位。
    notifyExternalDOMReset: function (targetEl) {
      if (lastGroupPatch && (!targetEl || lastGroupPatch.target === targetEl)) {
        lastGroupPatch = null;
      }
    },
    configureMermaidFromTheme: configureMermaidFromTheme,
    refreshMermaidForTheme: refreshMermaidForTheme,
    renderAllDiagrams: renderAllDiagrams,
    // bridge 的缓存命中恢复路径用：快照可能在 idle 高亮批跑完前落盘，
    // 恢复页需幂等补高亮（已带 hljs 的块跳过）。
    highlightCodeBlocks: highlightCodeBlocks,
    // 同上，补的是 mermaid 的懒渲染观察器（不补 = 没滚到的图永久空白）。
    restoreMermaid: restoreMermaid,
    // 测试出口：DOM 里的占位元素会被异步换成 SVG 或错误块（mermaid 库缺失时
    // 直接变成 error-block），从页面结构上数不清「到底摘了几个、边界在哪」。
    // 这里直接给出最近一次 renderInto 的提取结果，让围栏配对的断言能精确到代码内容。
    getMermaidDiagrams: function () {
      return latestDiagrams.map(function (d) { return { id: d.id, code: d.code }; });
    }
  };
})(window);
