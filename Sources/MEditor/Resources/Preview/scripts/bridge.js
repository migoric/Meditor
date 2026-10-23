// MEditor preview — JS↔Swift bridge.
// Exposes window.MEditor with the public API consumed by Swift's evaluateJavaScript.

(function (global) {
  'use strict';

  var contentEl = null;
  var ignoreScrollEvent = false;
  var lastReportedScrollPercent = -1;
  // Monotonic revision provided by Swift. This is the correctness-preserving
  // O(1) signal for "did content change?".
  var lastContentRevision = -1;

  // LRU cache: content hash → fully-rendered innerHTML.
  // Keep it intentionally small: large cached HTML strings cause noticeable
  // WebContent memory growth and long JavaScriptCore GC sweeps on idle.
  var RENDER_CACHE_LIMIT = 3;
  var RENDER_CACHE_ENTRY_BYTE_LIMIT = 512 * 1024;
  var RENDER_CACHE_TOTAL_BYTE_LIMIT = 1024 * 1024;
  var RENDER_CACHE_SOURCE_LIMIT = 120 * 1024;
  var renderCache = new Map();
  var renderCacheBytes = 0;
  var pendingCacheKey = null;
  var sourceAnchors = [];
  var sourceAnchorLines = [];
  var sourceAnchorOffsets = [];
  var sourceMetricsDirty = true;
  var tocItems = [];
  var scrollFrameRequested = false;
  var lastSentTOCSignature = null;
  var codeHighlightObserver = null;

  function reportPerf(stage) {
    try {
      if (window.webkit && window.webkit.messageHandlers &&
          window.webkit.messageHandlers.perfHandler) {
        window.webkit.messageHandlers.perfHandler.postMessage({ stage: stage });
      }
    } catch (e) { /* handler not registered */ }
  }

  function emptyDocumentMetadata() {
    return {
      sourceAnchors: [],
      sourceAnchorLines: [],
      tocItems: []
    };
  }

  function cloneMetadata(metadata) {
    var next = metadata || emptyDocumentMetadata();
    return {
      sourceAnchors: [],
      sourceAnchorLines: (next.sourceAnchorLines || []).slice(),
      tocItems: (next.tocItems || []).map(function (item) {
        return {
          level: item.level,
          title: item.title,
          line: item.line
        };
      })
    };
  }

  function rehydrateCachedMetadata(metadata) {
    var hydrated = cloneMetadata(metadata);
    if (!contentEl) return hydrated;

    var anchors = Array.prototype.slice.call(
      contentEl.querySelectorAll('[data-source-line]')
    );
    hydrated.sourceAnchors = [];
    hydrated.sourceAnchorLines = [];
    anchors.forEach(function (anchor) {
      var line = parseInt(anchor.getAttribute('data-source-line') || '-1', 10);
      if (isNaN(line) || line < 0) return;
      hydrated.sourceAnchors.push(anchor);
      hydrated.sourceAnchorLines.push(line);
    });

    if (hydrated.tocItems.length === 0 && hydrated.sourceAnchors.length > 0) {
      hydrated.tocItems = hydrated.sourceAnchors.map(function (anchor, index) {
        return {
          level: parseInt(anchor.tagName.charAt(1), 10),
          title: anchor.textContent || '',
          line: hydrated.sourceAnchorLines[index]
        };
      });
    }

    return hydrated;
  }

  function disconnectCodeHighlightObserver() {
    if (!codeHighlightObserver) return;
    codeHighlightObserver.disconnect();
    codeHighlightObserver = null;
  }

  function applyDocumentMetadata(metadata) {
    var next = metadata || emptyDocumentMetadata();
    sourceAnchors = next.sourceAnchors || [];
    sourceAnchorLines = next.sourceAnchorLines || [];
    tocItems = next.tocItems || [];
    invalidateLayoutMetrics();
    reportPerf('PreviewJSDocumentCachesRefreshed');
  }

  function tocSignature(items) {
    if (!items || items.length === 0) return '';
    return items.map(function (item) {
      return [item.level, item.line, item.title].join('\t');
    }).join('\n');
  }

  function estimateCacheBytes(value) {
    return value ? value.length * 2 : 0;
  }

  function deleteCacheEntry(key) {
    if (!renderCache.has(key)) return;
    var entry = renderCache.get(key);
    renderCache.delete(key);
    renderCacheBytes = Math.max(0, renderCacheBytes - ((entry && entry.bytes) || 0));
  }

  /** LRU touch: re-insert to mark as most-recently used. */
  function lruTouch(key, value, metadata) {
    var bytes = estimateCacheBytes(value);
    if (bytes === 0 || bytes > RENDER_CACHE_ENTRY_BYTE_LIMIT) {
      deleteCacheEntry(key);
      return false;
    }

    var previous = renderCache.get(key);
    if (renderCache.has(key)) deleteCacheEntry(key);
    renderCache.set(key, {
      html: value,
      bytes: bytes,
      metadata: metadata ? cloneMetadata(metadata) : cloneMetadata(previous && previous.metadata)
    });
    renderCacheBytes += bytes;

    while (renderCache.size > RENDER_CACHE_LIMIT || renderCacheBytes > RENDER_CACHE_TOTAL_BYTE_LIMIT) {
      var firstKey = renderCache.keys().next().value;
      deleteCacheEntry(firstKey);
    }
    return true;
  }

  function shouldCacheContent(content) {
    return !!content && content.length <= RENDER_CACHE_SOURCE_LIMIT;
  }

  function cacheKeyForContent(content) {
    return shouldCacheContent(content) ? content : null;
  }

  /** Initial mount called by Swift after the page loads. */
  function boot(initialContent) {
    contentEl = document.getElementById('content');
    if (!contentEl) {
      console.error('MEditor: #content element not found');
      return;
    }
    var initial = initialContent || '';
    if (window.MEditorRender) {
      window.MEditorRender.configureMermaidFromTheme();
      window.MEditorRender.renderInto(contentEl, initial);
    }
    refreshDocumentCaches();
    contentEl.addEventListener('load', invalidateLayoutMetrics, true);
    window.addEventListener('resize', invalidateLayoutMetrics);
    attachScrollListener();
    sendTOC();
  }

  /** Re-render with new markdown content (no full page reload). */
  function update(newContent, revision) {
    if (!contentEl) return;
    if (typeof revision === 'number' && revision === lastContentRevision) return;
    if (typeof revision === 'number') {
      lastContentRevision = revision;
    }
    disconnectCodeHighlightObserver();
    reportPerf('PreviewJSUpdateReceived');
    var content = newContent || '';
    var key = cacheKeyForContent(content);

    // Cache hit: paint instantly.
    if (key && renderCache.has(key)) {
      var entry = renderCache.get(key);
      contentEl.innerHTML = entry.html;
      lruTouch(key, entry.html, entry.metadata);
      pendingCacheKey = null;
      applyDocumentMetadata(rehydrateCachedMetadata(entry.metadata));
      reportPerf('PreviewJSCacheHitPaint');
      sendTOC();
      // 快照是 idle 落盘的，可能在代码块高亮的 idle 批跑完前存下未高亮的
      // HTML（idle starvation）——恢复页会永久缺高亮。幂等补一遍：已带
      // hljs 的块在 highlightCodeBlocks 里被跳过，快照完整时近零成本。
      if (window.MEditorRender && window.MEditorRender.highlightCodeBlocks) {
        window.MEditorRender.highlightCodeBlocks(contentEl);
      }
      return;
    }

    // Cache miss: synchronous render.
    pendingCacheKey = key;
    reportPerf('PreviewJSRenderStart');
    if (window.MEditorRender) {
      window.MEditorRender.renderInto(contentEl, content);
    }
    refreshDocumentCaches();
    if (pendingCacheKey) scheduleCacheSnapshot(key, { sourceAnchors: sourceAnchors, sourceAnchorLines: sourceAnchorLines, tocItems: tocItems });
    sendTOC();
  }

  function scheduleCacheSnapshot(key, metadata) {
    var snap = function () {
      // Only snapshot if this is still the current content
      // (user may have switched away while highlighting was running).
      if (pendingCacheKey !== key) return;
      pendingCacheKey = null;
      lruTouch(key, contentEl.innerHTML, metadata);
    };
    if (typeof window.requestIdleCallback === 'function') {
      window.requestIdleCallback(snap, { timeout: 1500 });
    } else {
      setTimeout(snap, 500);
    }
  }

  /** Switch theme by toggling a class on <html>.
   *  All theme stylesheets are inlined in css/themes.css, so this is a
   *  pure class change with zero network or stylesheet-swap cost. */
  function setTheme(themeName) {
    var safe = String(themeName || '').toLowerCase().replace(/[^a-z0-9_-]/g, '');
    if (!safe) return;
    var root = document.documentElement;
    // Strip any previous theme-* class, set the new one.
    root.className = root.className.replace(/\btheme-[a-z0-9_-]+\b/g, '').trim();
    root.classList.add('theme-' + safe);
    // Cached HTML doesn't depend on theme anymore (hljs colors come from CSS),
    // so we don't clear renderCache. Mermaid SVGs do bake in colors though,
    // so re-render only diagrams to refresh their theming.
    if (window.MEditorRender) {
      window.MEditorRender.refreshMermaidForTheme();
    }
  }

  /** Programmatic scroll from Swift side (e.g. editor scroll → preview sync). */
  function scrollToPercent(percent) {
    var docHeight = document.documentElement.scrollHeight - window.innerHeight;
    var y = docHeight > 0 ? docHeight * percent : 0;
    ignoreScrollEvent = true;
    window.scrollTo(0, y);
    // Allow the scroll event to fire and be skipped, then resume reporting.
    setTimeout(function () { ignoreScrollEvent = false; }, 50);
  }

  /** Scroll to the rendered element whose source line is closest to (but not
   *  greater than) the given line. Used by Swift for editor→preview sync. */
  function scrollToLine(line) {
    if (!contentEl) return;
    if (sourceAnchors.length === 0) return;
    var targetIndex = 0;
    var lo = 0;
    var hi = sourceAnchorLines.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (sourceAnchorLines[mid] <= line) {
        targetIndex = mid;
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var target = sourceAnchors[targetIndex];
    ignoreScrollEvent = true;
    var rect = target.getBoundingClientRect();
    var distance = Math.abs(rect.top);
    // Smooth for small jumps (<800px), instant for large jumps to avoid sluggish feel.
    var behavior = distance < 800 ? 'smooth' : 'auto';
    window.scrollTo({ top: window.scrollY + rect.top - 16, behavior: behavior });
    setTimeout(function () { ignoreScrollEvent = false; }, behavior === 'smooth' ? 150 : 50);
  }

  /** Return rendered HTML for export. Includes inlined CSS for portability. */
  function getRenderedHTML(documentTitle) {
    if (!contentEl) return '';
    var title = String(documentTitle || 'Document');
    // Inline all stylesheets so the exported HTML is self-contained.
    var styles = '';
    var sheets = document.querySelectorAll('link[rel="stylesheet"]');
    for (var i = 0; i < sheets.length; i++) {
      try {
        var rules = sheets[i].sheet && sheets[i].sheet.cssRules;
        if (rules) {
          for (var j = 0; j < rules.length; j++) {
            styles += rules[j].cssText + '\n';
          }
        }
      } catch (e) { /* CORS or other issue, skip */ }
    }
    var styleTags = document.querySelectorAll('style');
    for (var k = 0; k < styleTags.length; k++) {
      styles += styleTags[k].innerHTML + '\n';
    }
    // 带上 <html> 的 theme-X class——themes.css 的变量都挂在主题选择器下，
    // 不带 class 导出会丢全部主题色。
    var htmlClass = document.documentElement.className;
    return [
      '<!DOCTYPE html>',
      '<html lang="zh-CN" class="' + escapeHtml(htmlClass) + '"><head><meta charset="UTF-8">',
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
      '<title>' + escapeHtml(title) + '</title>',
      '<style>' + styles + '</style>',
      '</head><body><div id="content">',
      contentEl.innerHTML,
      '</div></body></html>'
    ].join('\n');
  }

  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function attachScrollListener() {
    window.addEventListener('scroll', function () {
      if (ignoreScrollEvent) return;
      if (scrollFrameRequested) return;
      scrollFrameRequested = true;
      window.requestAnimationFrame(reportScrollState);
    }, { passive: true });
  }

  function reportScrollState() {
    scrollFrameRequested = false;
    if (ignoreScrollEvent) return;
      var docHeight = document.documentElement.scrollHeight - window.innerHeight;
      var percent = docHeight > 0 ? window.scrollY / docHeight : 0;
      if (Math.abs(percent - lastReportedScrollPercent) < 0.005) return;
      lastReportedScrollPercent = percent;

      // Find the topmost visible source-line anchor for preview→editor sync.
      var line = currentVisibleLine();

      try {
        window.webkit.messageHandlers.scrollHandler.postMessage({
          percent: percent,
          line: line
        });
      } catch (e) { /* Swift handler not registered */ }
  }

  /// Return the data-source-line of the topmost anchor currently visible in
  /// the viewport, or -1 if none exists / nothing in view.
  function currentVisibleLine() {
    if (!contentEl || sourceAnchors.length === 0) return -1;
    rebuildSourceMetrics();
    var targetY = window.scrollY + 20;
    var lo = 0;
    var hi = sourceAnchorOffsets.length;
    var index = 0;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (sourceAnchorOffsets[mid] <= targetY) {
        index = mid;
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return sourceAnchorLines[index];
  }

  /** Set the document base URL so relative image/link/asset paths in
   *  markdown resolve against the source file's parent directory. */
  function setBaseURL(url) {
    var safe = String(url || '');
    var existing = document.querySelector('base');
    if (existing) {
      existing.href = safe;
    } else if (safe) {
      var base = document.createElement('base');
      base.href = safe;
      document.head.insertBefore(base, document.head.firstChild);
    }
  }

  /** Extract headings from rendered content and send to Swift as TOC. */
  function sendTOC() {
    if (!contentEl) return;
    var signature = tocSignature(tocItems);
    if (signature === lastSentTOCSignature) return;
    lastSentTOCSignature = signature;
    try {
      window.webkit.messageHandlers.tocHandler.postMessage({ items: tocItems });
      reportPerf('PreviewJSTOCSent');
    } catch (e) { /* handler not registered */ }
  }

  function refreshDocumentCaches() {
    if (!contentEl) return;
    var headings = contentEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
    sourceAnchors = [];
    sourceAnchorLines = [];
    tocItems = [];
    Array.prototype.forEach.call(headings, function (el) {
      // 跳过美化模板卡片/网格组件内的装饰性标题（统计数字、卡片标题等），不计入大纲
      if (el.closest('.feat, .features, .card, .stp, .flow, .tbl')) return;
      var line = parseInt(el.getAttribute('data-source-line') || '-1', 10);
      tocItems.push({
        level: parseInt(el.tagName.charAt(1), 10),
        title: el.textContent || '',
        line: line
      });
      if (!isNaN(line) && line >= 0) {
        sourceAnchors.push(el);
        sourceAnchorLines.push(line);
      }
    });
    invalidateLayoutMetrics();
    reportPerf('PreviewJSDocumentCachesRefreshed');
  }

  function rebuildSourceMetrics() {
    if (!sourceMetricsDirty) return;
    sourceAnchorOffsets = sourceAnchors.map(function (anchor) {
      return window.scrollY + anchor.getBoundingClientRect().top;
    });
    sourceMetricsDirty = false;
  }

  function invalidateLayoutMetrics() {
    sourceMetricsDirty = true;
  }

  global.MEditor = {
    boot: boot,
    update: update,
    setTheme: setTheme,
    setBaseURL: setBaseURL,
    scrollToPercent: scrollToPercent,
    scrollToLine: scrollToLine,
    getRenderedHTML: getRenderedHTML,
    // 发布/导出前调用：把所有懒渲染的 mermaid 占位先渲染完（返回 Promise）
    renderAllDiagrams: function () {
      return (global.MEditorRender && global.MEditorRender.renderAllDiagrams)
        ? global.MEditorRender.renderAllDiagrams()
        : Promise.resolve(true);
    },
    invalidateLayoutMetrics: invalidateLayoutMetrics,
    reportPerf: reportPerf,
    setCodeHighlightObserver: function (observer) {
      disconnectCodeHighlightObserver();
      codeHighlightObserver = observer;
    },
    disconnectCodeHighlightObserver: disconnectCodeHighlightObserver
  };

  // ESC 退出专注模式：WKWebView 把键盘事件转发给独立的 WebContent 进程处理，
  // AppKit 侧的 keyDown 覆写/本地事件监视器都拦不到——只能在页面自身注册
  // 监听器，再通过 message handler 桥接回 Swift 层。
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' || e.keyCode === 27) {
      if (global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers.escapeHandler) {
        global.webkit.messageHandlers.escapeHandler.postMessage({});
      }
    }
  });
})(window);
