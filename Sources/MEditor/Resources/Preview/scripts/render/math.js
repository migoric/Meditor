// MEditor preview — KaTeX extraction, rendering, and DOM comparison.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;

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

  core.math = {
    extract: extractMath,
    render: renderMath,
    normalizedHTML: normalizedMathHTML
  };
})(window);
