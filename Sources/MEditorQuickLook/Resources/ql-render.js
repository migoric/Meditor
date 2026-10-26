// ql-render.js — Quick Look 预览扩展的 DOM-less 渲染驱动（运行在 JavaScriptCore / JSContext 里）。
//
// 为什么不是直接复用 scripts/render.js：render.js 是浏览器 IIFE，依赖 DOM、
// messageHandlers、增量更新等主 app 交互设施；QL 扩展是数据式预览（QLPreviewReply），
// 系统拿到的是一份静态 HTML，没有 WebView 让我们跑脚本。
// 因此这里只移植 render.js 的「纯函数」部分：
//   - 预处理规则（标题/分割线补空行、fixTableSeparators 修表格分隔行）
//   - marked.parse 参数（gfm: true, breaks: false）——解析器就是主 app 同一份 marked.min.js
//   - 语言别名表 + hljs 高亮（主 app 在渲染后批处理高亮，这里在解析时经 highlight 回调同步完成）
// 图表走 pele（零 DOM 依赖的同步渲染器，MIT，1.10.0 锁在 Resources/pele.global.js），
// 不是 mermaid：mermaid 靠 getBBox / canvas 量文本宽度，没有 DOM 连解析都过不去——
// 这才是本文件此前把 mermaid 降级成代码块的原因。pele 在没有 canvas 的环境里退回
// 内置字宽表，于是能在 JSContext 里直接出 SVG 字符串。降级链：pele 未加载 → 代码块。
//
// 有意省略：段落缓存（一次性渲染不需要）、data-source-line 锚点（QL 无编辑器滚动同步）。
(function (global) {
  'use strict';

  // 与主 app render.js 一致的语言别名表
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

  // 以下两个函数与 render.js 逐字一致
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

  // 移植自 render.js：把列数对不上的表格分隔行补齐/裁齐，让 marked 能识别为表格
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

  // 与主 app 的围栏口径对齐：只有「反引号围栏 + info 首 token 恰为 mermaid」才出图。
  // marked 的 renderer.code 只拿得到 infostring、拿不到围栏字符，所以在预处理阶段
  // 把**顶层** ~~~mermaid 的开栏信息串改名（渲染时再还原语言类名）。
  // 必须按行跟踪围栏状态：其他围栏内部的 `~~~mermaid` 是代码内容（mermaid 教程
  // 文档的典型形态），裸正则会把字面文本也改掉（已实测复现）。
  var QL_TILDE_SENTINEL = '__ql_tilde_mermaid__';

  function fenceOpen(line) {
    // 0–3 空格缩进 + ≥3 反引号/波浪号；反引号 info 含反引号 ⇒ 不是围栏
    var m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (!m) return null;
    if (m[1].charAt(0) === '`' && m[2].indexOf('`') !== -1) return null;
    return { char: m[1].charAt(0), len: m[1].length, info: m[2].replace(/^[ \t]+/, '') };
  }

  function fenceClose(line, fence) {
    var m = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
    return !!m && m[1].charAt(0) === fence.char && m[1].length >= fence.len;
  }

  function suppressTildeMermaid(text) {
    if (text.indexOf('~~~') === -1) return text;
    var lines = text.split('\n');
    var out = [];
    var fence = null;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (fence) {
        out.push(line);
        if (fenceClose(line, fence)) fence = null;
        continue;
      }
      var open = fenceOpen(line);
      if (open) {
        if (open.char === '~' && open.info.split(/[ \t]/)[0] === 'mermaid') {
          out.push(line.replace(/mermaid(?=[ \t]|$)/, QL_TILDE_SENTINEL));
        } else {
          out.push(line);
        }
        fence = open;
        continue;
      }
      out.push(line);
    }
    return out.join('\n');
  }

  // 移植自 render.js 的 renderMarkdown 预处理：
  // 标题/分割线后补空行（宽容处理紧贴下一段的写法）
  function preprocess(content) {
    var processed = suppressTildeMermaid(content)
      .replace(/^(#{1,6}\s+[^\n]+)\n(?!\n)/gm, '$1\n\n')
      .replace(/^(---+|\*\*\*+|___+)\s*\n(?!\n)/gm, '$1\n\n');
    return fixTableSeparators(processed);
  }

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ---- 图表渲染（pele）----
  //
  // 参数为什么是这几个值：
  // - fontSize 15 / fontFamily：与 base.css 的 body 完全同源。pele 靠**度量标签**
  //   定节点尺寸，字体对不上标签就会溢出或留白（它自己的文档也是这么要求的）。
  // - maxWidth 632 = QLPreviewReply 的 contentSize 720 − body 左右内边距
  //   （2.5rem + 3rem = 88px）。给了它，宽图会重排而不是缩成小字。
  // - autoDirection 保持默认开：QL 预览窗口本来就窄，`flowchart LR` 转竖向更好读。
  var MERMAID_OPTIONS = {
    fontSize: 15,
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro', 'Segoe UI', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', Helvetica, Arial, sans-serif",
    fontFamilyMono: 'Menlo, monospace',
    maxWidth: 632,
    autoDirection: true,
    directionBreakpoint: 480,
    padding: 8
  };

  var mermaidSeq = 0;

  /// 返回图表 HTML；pele 不可用时返回 null，由调用方降级成代码块。
  function renderMermaidDiagram(code) {
    if (!global.pele || typeof global.pele.render !== 'function') return null;
    var options = {};
    for (var k in MERMAID_OPTIONS) options[k] = MERMAID_OPTIONS[k];
    // render() 不像 mount() 那样自动给 ID 前缀；同页多图不给就会 id 互相覆盖
    // （pele 的 SVG 里 aria 标题、渐变、marker 都吃 id）。
    options.idPrefix = 'ql-mmd-' + (++mermaidSeq);
    try {
      return '<div class="mermaid-container">' + global.pele.render(code, options).svg + '</div>\n';
    } catch (e) {
      // PeleError.message 里含图表源码，进 HTML 前必须转义（pele 文档的明确要求）。
      var msg = (e && e.message) ? String(e.message) : String(e);
      return '<div class="error-block">Mermaid: ' + escapeHtml(msg) + '</div>\n';
    }
  }

  global.MEditorQL = {
    /// Markdown → 正文 HTML 片段（不含 <html> 外壳，外壳由 Swift 侧拼）。
    render: function (markdown) {
      // 代码高亮：marked v12 已移除 parse 的 highlight 选项，改用自定义 renderer。
      // v12 的 renderer.code 仍是位置参数签名 code(code, infostring, escaped)
      // （对象 token 签名是更晚版本的事）；返回值直接进 HTML，不高亮时必须自己转义。
      // 高亮结果与主 app 的 DOM 后处理输出等价（同样的 hljs.highlight 调用、
      // 同样的 language-x + hljs 类名）。
      var renderer = new marked.Renderer();
      renderer.code = function (code, infostring) {
        var rawLang = (infostring || '').match(/^\S*/)[0];
        if (rawLang === 'mermaid') {
          var diagram = renderMermaidDiagram(code);
          // null = pele 未加载（资源缺失），落到下面按普通代码块显示，
          // 至少让读者看得到源码，而不是留一块空白。
          if (diagram !== null) return diagram;
        }
        // 顶层 ~~~mermaid 在预处理里被改过名，显示语言要还原成 mermaid
        var displayLang = rawLang === QL_TILDE_SENTINEL ? 'mermaid' : rawLang;
        var lang = LANG_ALIASES[displayLang] || displayLang;
        var inner;
        var highlighted = false;
        if (lang && global.hljs && hljs.getLanguage(lang)) {
          try {
            inner = hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
            highlighted = true;
          } catch (e) { /* 落到下方转义分支 */ }
        }
        if (!highlighted) {
          inner = escapeHtml(code.replace(/\n$/, '')) + '\n'; // 与 marked 默认渲染一致
        }
        var cls = (displayLang ? 'language-' + displayLang + ' ' : '') + 'hljs';
        return '<pre><code class="' + cls + '">' + inner + '</code></pre>\n';
      };
      return marked.parse(preprocess(markdown), {
        gfm: true,
        breaks: false,
        renderer: renderer
      });
    }
  };
})(this);
