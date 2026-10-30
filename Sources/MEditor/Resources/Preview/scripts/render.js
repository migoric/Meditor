// MEditor preview — rendering pipeline and public window.MEditorRender API.
// All rendering happens synchronously on the main thread.
// highlight.js is loaded lazily and applied in idle-time batches.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore;
  var renderStats = core.stats;
  var lastRendered = core.lastRendered;
  var extractMermaid = core.mermaid.extract;
  var extractMath = core.math.extract;
  var renderMarkdownBlocks = core.blocks.render;
  var joinGroupHTML = core.blocks.joinHTML;
  var patchDOMGroups = core.dom.patchGroups;
  var patchDOM = core.dom.patch;
  var recordGroupRanges = core.dom.recordRanges;
  var wrapTablesIn = core.dom.wrapTables;
  var clearGroupPatch = core.dom.clearGroupPatch;
  var stampHeadings = core.enhancements.stampHeadings;
  var highlightCodeBlocks = core.enhancements.highlightCodeBlocks;
  var rewriteAbsoluteAssetPaths = core.enhancements.rewriteAbsoluteAssetPaths;
  var renderMermaidDiagrams = core.mermaid.render;
  var renderMath = core.math.render;

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
        ? (html === lastRendered.html)
        : (groupKeys !== null && lastRendered.groupKeys !== null
           && core.sameGroupKeys(groupKeys, lastRendered.groupKeys));
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
          if (!groups) clearGroupPatch();
        }
        if (updated) {
          lastRendered.html = html;
          lastRendered.groupKeys = groupKeys;
          stampHeadings(targetEl, content || '');
          highlightCodeBlocks(targetEl, content || '');
          renderMermaidDiagrams(extracted.diagrams);
          renderMath(math.items);
          rewriteAbsoluteAssetPaths(targetEl, content || '');
          return;
        }
        clearGroupPatch();   // 落到全量替换：范围记录作废
      }

      // Fallback: full replace (first render or very large docs)
      if (groups && html === null) html = joinGroupHTML(groups);
      targetEl.innerHTML = html;
      if (html.indexOf('<table') !== -1) wrapTablesIn(targetEl);
      stampHeadings(targetEl, content || '');
      highlightCodeBlocks(targetEl, content || '');
      renderMermaidDiagrams(extracted.diagrams);
      renderMath(math.items);
      rewriteAbsoluteAssetPaths(targetEl, content || '');
      lastRendered.html = html;
      lastRendered.groupKeys = groupKeys;
      // 首帧就建立组范围记录（自校验，对不上就放弃），让第一次更新就能走块对齐
      if (groups) recordGroupRanges(targetEl, groups);
      else clearGroupPatch();
    } catch (e) {
      targetEl.innerHTML = '<div class="error-block">Render error: ' + String(e && e.message || e) + '</div>';
      clearGroupPatch();
    }
  }

  global.MEditorRender = {
    renderInto: renderInto,
    // bridge 的缓存命中恢复会绕过 renderInto 直接写 contentEl.innerHTML；
    // 写完必须调这个，否则 no-op 短路会拿上一个文档的产物做比较（见该函数注释）。
    invalidateLastRender: core.invalidateLastRender,
    // 纯函数出口：测试要做「分块 vs 整篇」的出口等价性比对，只能拿到这两个
    // 中间层（renderInto 会顺带 patchDOM，差异被 DOM 归一化吃掉）。
    renderMarkdown: core.markdown.render,
    renderMarkdownCached: core.blocks.renderCached,
    // 渲染计数（见 renderStats 注释）：测试用它把「缓存真的生效」钉住，
    // 因为产物正确性测试对「整篇重解析」同样是绿的。
    getRenderStats: function () {
      var cache = core.cacheStats();
      return {
        fullParse: renderStats.fullParse,
        blockParse: renderStats.blockParse,
        blockHit: renderStats.blockHit,
        sanitize: renderStats.sanitize,
        noopSkip: renderStats.noopSkip,
        cacheEntries: cache.entries,
        cacheBytes: cache.bytes,
        // 块对齐 patch：对齐时看了多少组 / 实际替换了多少组 / 回退全树 diff 几次。
        // 「无变化更新 ⇒ patchGroupsReplaced === 0 且 patchBail === 0」可被测试断言。
        patchGroupsCompared: renderStats.patchGroupsCompared,
        patchGroupsReplaced: renderStats.patchGroupsReplaced,
        patchBail: renderStats.patchBail
      };
    },
    resetRenderStats: core.resetStats,
    // 绕过 renderInto 直接改写 #content 的入口（bridge 的缓存命中恢复）
    // 必须调它作废组范围记录——按过期范围做块对齐替换会错位。
    notifyExternalDOMReset: core.dom.notifyExternalReset,
    configureMermaidFromTheme: core.mermaid.configureFromTheme,
    refreshMermaidForTheme: core.mermaid.refreshForTheme,
    renderAllDiagrams: core.mermaid.renderAll,
    // bridge 的缓存命中恢复路径用：快照可能在 idle 高亮批跑完前落盘，
    // 恢复页需幂等补高亮（已带 hljs 的块跳过）。
    highlightCodeBlocks: highlightCodeBlocks,
    // 同上，补的是 mermaid 的懒渲染观察器（不补 = 没滚到的图永久空白）。
    restoreMermaid: core.mermaid.restore,
    // 测试出口：DOM 里的占位元素会被异步换成 SVG 或错误块（mermaid 库缺失时
    // 直接变成 error-block），从页面结构上数不清「到底摘了几个、边界在哪」。
    // 这里直接给出最近一次 renderInto 的提取结果，让围栏配对的断言能精确到代码内容。
    getMermaidDiagrams: core.mermaid.getDiagrams
  };
})(window);
