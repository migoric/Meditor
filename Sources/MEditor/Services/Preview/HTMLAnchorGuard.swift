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
enum HTMLAnchorGuard {

    /// 只接管能落回本文档的锚点；`#` 单字符 = 回到顶部。
    static let source = """
    (function () {
      if (window.__meditorAnchorGuard) { return; }
      window.__meditorAnchorGuard = true;

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

    static func userScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
