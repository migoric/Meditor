// MEditor preview — safe block splitting, list grouping, and cached parsing.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;
  var renderStats = core.stats;
  var renderMarkdown = core.markdown.render;
  var sanitizeHTML = core.markdown.sanitize;
  var fixTableSeparators = core.markdown.fixTableSeparators;
  var fenceOpenInfo = core.markdown.fenceOpenInfo;
  var FENCE_CLOSE = core.markdown.fenceClose;
  var cacheGet = core.cacheGet;
  var cachePut = core.cachePut;

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
  function listItemKind(block) {
    var lines = block.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] === '') continue;
      if (/^ {0,3}\d{1,9}[.)](?:[ \t]|$)/.test(lines[i])) return 'ol';
      if (/^ {0,3}[-*+](?:[ \t]|$)/.test(lines[i])) return 'ul';
      return null;
    }
    return null;
  }

  function shouldJoinGroup(g, right) {
    if (/^[ \t]/.test(right)) return true;                        // 缩进续行
    if (startsWithListItem(right) && g.hasList) {
      var kind = listItemKind(right);
      // 同类列表可以按稳定项边界切块；混合类型仍按原逻辑整体合并。
      if (g.listKind !== null && kind === g.listKind) {
        if (g.listItemCount >= 50 || g.charCount + right.length > 16384) return false;
      }
      return true;
    }
    if (g.span !== null && !g.span.closed) return true;            // 跨空行 HTML（类型 1–5）
    if (g.elem !== null && g.elem.opens > g.elem.closes) return true;  // 未闭合的块级标签
    return false;
  }

  /** 把右块并入左组：只更新摘要，不拼接字符串。 */
  function absorbIntoGroup(g, right) {
    if (!g.hasList) g.hasList = hasListItemLine(right);
    if (startsWithListItem(right)) {
      if (listItemKind(right) !== g.listKind) g.listKind = null;
      g.listItemCount++;
    }
    g.charCount += right.length;
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
          listKind: listItemKind(right),
          listItemCount: startsWithListItem(right) ? 1 : 0,
          charCount: right.length,
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

    groups = joinListGroups(groups);
    return { html: null, groups: groups, totalLen: totalLen };
  }

  /**
   * 相邻同类列表在组层面并回一个容器。DOM patch 与整篇 HTML 必须消费同一组结构，
   * 否则首帧合并、编辑时又按独立列表插回，编号和增量范围都会失真。
   */
  function joinListGroups(groups) {
    var wrapper = /^\s*<(ol|ul)([^>]*)>([\s\S]*?)<\/\1>\s*$/;
    var joined = [];
    for (var i = 0; i < groups.length; i++) {
      var group = groups[i];
      var match = wrapper.exec(group.html);
      if (match && joined.length > 0) {
        var previousGroup = joined[joined.length - 1];
        if (previousGroup.listKind === match[1]) {
          previousGroup.key += '\n\n' + group.key;
          previousGroup.listBodies.push(match[3]);
          continue;
        }
      }
      joined.push({
        key: group.key,
        html: group.html,
        listKind: match ? match[1] : null,
        listAttributes: match ? match[2] : '',
        listBodies: match ? [match[3]] : null
      });
    }
    for (var j = 0; j < joined.length; j++) {
      var item = joined[j];
      if (item.listKind !== null && item.listBodies.length > 1) {
        item.html = '<' + item.listKind + item.listAttributes + '>'
          + item.listBodies.join('') + '</' + item.listKind + '>';
      }
    }
    return joined;
  }

  /** 组 HTML 拼回整篇（与旧的 htmlParts.join('\n') 同口径）。 */
  function joinGroupHTML(groups) {
    return groups.map(function (group) { return group.html; }).join('\n');
  }

  function renderMarkdownCached(content) {
    var rendered = renderMarkdownBlocks(content);
    return rendered.groups ? joinGroupHTML(rendered.groups) : rendered.html;
  }

  core.blocks = {
    render: renderMarkdownBlocks,
    renderCached: renderMarkdownCached,
    joinHTML: joinGroupHTML
  };
})(window);
