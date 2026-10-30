// MEditor preview — Mermaid fence extraction and diagram lifecycle.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;

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

  function getMermaidDiagrams() {
    return latestDiagrams.map(function (d) { return { id: d.id, code: d.code }; });
  }

  core.mermaid = {
    extract: extractMermaid,
    render: renderMermaidDiagrams,
    restore: restoreMermaid,
    renderAll: renderAllDiagrams,
    configureFromTheme: configureMermaidFromTheme,
    refreshForTheme: refreshMermaidForTheme,
    getDiagrams: getMermaidDiagrams
  };
})(window);
