import Foundation
import WebKit

/// HTML 预览里页内锚点（`<a href="#小节">`）的点击守卫。
///
/// ## 为什么需要它
///
/// HTML 预览用 `loadHTMLString(_:baseURL: https://localhost/)` 渲染，本地相对
/// 资源靠注入的 `<base href="meditor-asset://local/<文档目录>/">` 解析
/// （见 `HTMLAssetBaseInjector`）。`<base>` 是文档级设置，管的不只是图片：
/// **纯 fragment 链接也一起被它接管**——
///
/// ```
/// <base href="meditor-asset://local/Users/me/docs/">
/// <a href="#target">   ⇒   meditor-asset://local/Users/me/docs/#target
/// ```
///
/// 而那个 scheme 上并不存在这份文档，WebKit 收到导航后既不加载也不滚动，
/// **连 `decidePolicyFor` 都不回调**（实测：`navURL=nil`，`scrollY` 保持 0），
/// 于是用户看到的就是「点目录没反应」。去掉 `<base>` 后同一份 HTML 点一下
/// 就正常滚到 1721px —— 差别只有 base。
///
/// ## 做法
///
/// 在捕获阶段接管**目标确实在本文档内**的锚点点击，改成对 `location.hash` 赋值：
/// hash 按**文档 URL**（`https://localhost/`）解析，是当前文档内的同页跳转，
/// 浏览器自己滚动，并顺带保住 `:target` 样式与前进/后退语义。
///
/// 接管范围两种写法：
///  - `href="#小节"`：纯 fragment，本来就是页内跳转；
///  - `href="report.html#小节"`：被 `<base>` 改写成 `meditor-asset://…/report.html#小节`，
///    只在 `#小节` 能在本文档里找到对应元素时才接管 —— 否则它是跨文件链接，
///    交回 `PreviewLinkNavigator` 处理。
///
/// ⚠️ 不能用 `history.replaceState(null, '', '#' + frag)`——它的相对 URL 也按
/// `<base>` 解析，会被 security check 拒绝（实测 `SecurityError: … change session
/// history URL from https://localhost/ to meditor-asset://…`）。同一个 base 陷阱，
/// 两处表现不同。
///
/// 不拦其它链接：外部链接照旧交给系统浏览器。
///
/// 监听挂在 `document` 上而不是逐个 `<a>`，所以页面后续动态插入的目录条目
/// 也一并生效，不需要 MutationObserver。
///
/// ## 两套预览都用它
///
/// markdown 预览有同一个 `<base>` 陷阱（`bridge.js` 的 `setBaseURL` 设成
/// `meditor-asset://local/<文档目录>/`），此前**没装守卫**：`#小节` 点了既不滚
/// 也不报错。现在由 `PreviewAssetMirror.prepareHTML` 把 `script(interceptsFileNameLinks:)`
/// 写成缓存目录里的 `scripts/anchor-guard.js`，模板用 `<script src>` 引它
/// ——**不能内联**，模板的 CSP 是 `script-src 'self' file:`。
///
/// markdown 那边传 `false`（只接管纯 fragment）：它的标题 id 由 `render.js`
/// 现算，跨文档链接 `other.md#小节` 的 fragment 很容易和当前文档的标题撞名，
/// 宽松口径会把「打开那份文档」误判成「在本页滚一下」。
enum HTMLAnchorGuard {

    /// 两套预览共用的源。默认口径（HTML 预览）：连「带文件名的自引用」
    /// （`report.html#小节`）也接管，只要目标元素在本页里存在。
    static var source: String { script(interceptsFileNameLinks: true) }

    /// - Parameter interceptsFileNameLinks: `false` 时只接管纯 `#fragment` 链接。
    ///
    ///   markdown 预览必须传 `false`：它的 `#小节` 由 render.js 现算 id（GitHub slug），
    ///   跨文档链接 `other.md#小节` 里的 fragment 很容易撞上当前文档的同名标题，
    ///   宽松口径会把「该打开那份文档」误判成「在本页里滚一下」。跨文档链接交给
    ///   `PreviewLinkNavigator` 处理（见 `isRewrittenAnchor` 分支）。
    static func script(interceptsFileNameLinks: Bool) -> String {
        """
    (function () {
      if (window.__meditorAnchorGuard) { return; }
      window.__meditorAnchorGuard = true;
      var interceptsFileNameLinks = \(interceptsFileNameLinks ? "true" : "false");

      function decode(value) {
        try { return decodeURIComponent(value); } catch (err) { return value; }
      }

      function targetFor(fragment) {
        if (!fragment) { return null; }
        return document.getElementById(fragment) || document.getElementsByName(fragment)[0] || null;
      }

      document.addEventListener('click', function (event) {
        if (event.defaultPrevented) { return; }
        var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!anchor) { return; }

        var raw = (anchor.getAttribute('href') || '').trim();
        var fragment;
        if (raw.charAt(0) === '#') {
          fragment = decode(raw.slice(1));
        } else {
          if (!interceptsFileNameLinks) { return; }
          var resolved = anchor.href || '';
          var hashAt = resolved.indexOf('#');
          if (resolved.indexOf('meditor-asset://') !== 0 || hashAt < 0) { return; }
          fragment = decode(resolved.slice(hashAt + 1));
          if (!targetFor(fragment)) { return; }
        }

        event.preventDefault();
        if (!fragment) { window.scrollTo(0, 0); return; }
        try { window.location.hash = fragment; } catch (err) {}
      }, true);
    })();
    """
    }

    static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
