// MEditor preview — marked configuration, sanitizing, and full-document parsing.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;
  var renderStats = core.stats;

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

  core.markdown = {
    render: renderMarkdown,
    sanitize: sanitizeHTML,
    fixTableSeparators: fixTableSeparators,
    fenceOpenInfo: fenceOpenInfo,
    fenceClose: FENCE_CLOSE
  };
})(window);
