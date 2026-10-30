// MEditor preview — aligned incremental DOM patching and full-tree fallback.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;
  var renderStats = core.stats;
  var normalizedMathHTML = core.math.normalizedHTML;

  /**
   * 上一帧块对齐 patch 留下的「组 → #content 顶层子节点范围」记录：
   * `{ target, groups: [{ key, start, count }] }`。count 以**包裹后**的 DOM
   * 为准（table 先包 .table-wrapper 再计数），start 冗余存一份便于排查。
   *
   * 凡是绕过 renderInto 直接改写 #content 的入口（bridge 的缓存命中恢复）
   * 都必须调 notifyExternalDOMReset 作废它——按过期范围替换会错位。
   */
  var lastGroupPatch = null;

  function clearGroupPatch() {
    lastGroupPatch = null;
  }

  function notifyExternalDOMReset(targetEl) {
    if (lastGroupPatch && (!targetEl || lastGroupPatch.target === targetEl)) {
      lastGroupPatch = null;
    }
  }

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

  core.dom = {
    patchGroups: patchDOMGroups,
    patch: patchDOM,
    recordRanges: recordGroupRanges,
    wrapTables: wrapTablesIn,
    clearGroupPatch: clearGroupPatch,
    notifyExternalReset: notifyExternalDOMReset
  };
})(window);
