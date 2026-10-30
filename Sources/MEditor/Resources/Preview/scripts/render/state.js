// MEditor preview — shared render state and block cache.

(function (global) {
  'use strict';

  var core = global.MEditorRenderCore = global.MEditorRenderCore || {};

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

  var lastRendered = { html: null, groupKeys: null };

  /** 外部改写了 DOM 之后作废短路状态。 */
  function invalidateLastRender() {
    lastRendered.html = null;
    lastRendered.groupKeys = null;
  }

  function sameGroupKeys(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
    return true;
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

  function cacheStats() {
    var bytes = 0;
    var keys = paragraphCache.keys();
    for (var it = keys.next(); !it.done; it = keys.next()) bytes += it.value.length;
    return { entries: paragraphCache.size, bytes: bytes };
  }

  function resetStats() {
    renderStats.fullParse = 0;
    renderStats.blockParse = 0;
    renderStats.blockHit = 0;
    renderStats.sanitize = 0;
    renderStats.noopSkip = 0;
    renderStats.patchGroupsCompared = 0;
    renderStats.patchGroupsReplaced = 0;
    renderStats.patchBail = 0;
  }

  core.stats = renderStats;
  core.lastRendered = lastRendered;
  core.invalidateLastRender = invalidateLastRender;
  core.sameGroupKeys = sameGroupKeys;
  core.cacheGet = cacheGet;
  core.cachePut = cachePut;
  core.cacheStats = cacheStats;
  core.resetStats = resetStats;
})(window);
