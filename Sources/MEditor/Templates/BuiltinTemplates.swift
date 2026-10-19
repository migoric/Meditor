import Foundation

/// Static content store for all built-in templates and HTML theme CSS.
/// No logic lives here — only string constants.
enum BuiltinTemplates {

    // MARK: - Markdown templates

    static var meeting: String { """
    # Meeting Notes

    **Date:** \(datePlaceholder)
    **Attendees:**

    - [ ] Name 1
    - [ ] Name 2

    ## Agenda

    1.

    ## Discussion

    ## Action Items

    | Owner | Task | Due |
    |-------|------|-----|
    |       |      |     |
    """ }

    static var techDesign: String { """
    # Technical Design

    ## Background

    ## Goals

    - [ ]

    ## Non-Goals

    -

    ## Design

    ### Architecture

    ### API

    ### Data Model

    ## Implementation Plan

    | Phase | Task | Estimate |
    |-------|------|----------|
    | 1     |      |          |

    ## Risks

    ## Open Questions
    """ }

    static var weekly: String { """
    # Weekly Report

    **Week of:** \(datePlaceholder)

    ## Done This Week

    -

    ## In Progress

    -

    ## Blockers

    -

    ## Plan for Next Week

    -

    ## Notes
    """ }

    static var journal: String { """
    # \(datePlaceholder)

    ## Today's Focus

    -

    ## Notes

    ## Learnings

    ## Tomorrow
    """ }

    static var prd: String { """
    # 产品需求文档：<需求名称>

    | 版本 | 日期 | 作者 | 状态 |
    |------|------|------|------|
    | v0.1 | \(datePlaceholder) |  | 草稿 |

    ## 一、背景与问题

    > 用户在什么场景下遇到什么问题？为什么现在做？

    ## 二、目标与衡量指标

    - 目标：
    - 衡量指标：

    ## 三、用户故事

    - 作为 ____，我希望 ____，以便 ____。

    ## 四、功能需求

    | # | 需求 | 优先级 | 备注 |
    |---|------|--------|------|
    | 1 |  | P0 |  |
    | 2 |  | P1 |  |

    ## 五、交互与界面

    ## 六、边界与异常

    - 空状态：
    - 错误处理：

    ## 七、非目标（本期不做）

    -

    ## 八、开放问题

    -
    """ }

    static var bugReport: String { """
    # Bug 报告：<一句话描述>

    | 严重级别 | 状态 | 报告日期 | 负责人 |
    |----------|------|----------|--------|
    |  | 待确认 | \(datePlaceholder) |  |

    ## 现象

    > 实际发生了什么（截图/录屏附在这里）

    ## 期望行为

    ## 复现步骤

    1.
    2.
    3.

    ## 环境

    - 版本：
    - 系统：
    - 设备：

    ## 影响范围

    ## 初步分析

    ## 修复方案与结论
    """ }

    static var readingNotes: String { """
    # 读书笔记：《书名》

    **作者：** 　**阅读日期：** \(datePlaceholder)　**评分：** ⭐⭐⭐⭐☆

    ## 一句话总结

    ## 核心观点

    1.
    2.
    3.

    ## 摘抄

    > 原文摘抄……

    —— 第 章

    ## 我的想法

    - 认同：
    - 质疑：

    ## 行动清单

    - [ ] 读完之后要做的一件事
    """ }

    static var releaseNotes: String { """
    # 发布说明 vX.Y.Z

    **发布日期：** \(datePlaceholder)

    ## ✨ 新功能

    -

    ## 🚀 改进

    -

    ## 🐛 修复

    -

    ## ⚠️ 破坏性变更

    - 无

    ## 升级指引

    ## 已知问题

    -
    """ }

    static var retrospective: String { """
    # 项目复盘：<项目名>

    **周期：** \(datePlaceholder) ～ 　**参与人：**

    ## 数据回顾

    | 指标 | 目标 | 实际 | 达成 |
    |------|------|------|------|
    |  |  |  |  |

    ## 做得好的（Keep）

    -

    ## 待改进的（Problem）

    -

    ## 根因分析

    > 连续问五个为什么，找到真因而不是表面现象。

    1. 为什么？
    2. 为什么？

    ## 行动项（Try）

    | 行动 | 负责人 | 截止时间 | 验证方式 |
    |------|--------|----------|----------|
    |  |  |  |  |
    """ }

    // MARK: - HTML 页面模板（完整页面，非纯主题）

    static var htmlLanding: String { """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>产品落地页</title>
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif; color: #1d1d1f; background: #fff; }
    .hero { text-align: center; padding: 120px 24px 96px; background: linear-gradient(180deg, #f5f7fa 0%, #fff 100%); }
    .hero .badge { display: inline-block; font-size: 13px; color: #0066cc; background: #eaf2fd; padding: 5px 14px; border-radius: 999px; margin-bottom: 24px; }
    .hero h1 { font-size: 52px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 18px; }
    .hero p { font-size: 19px; color: #6e6e73; max-width: 560px; margin: 0 auto 36px; line-height: 1.6; }
    .btn { display: inline-block; font-size: 16px; font-weight: 600; text-decoration: none; padding: 14px 32px; border-radius: 999px; }
    .btn-primary { background: #0066cc; color: #fff; }
    .btn-ghost { color: #0066cc; margin-left: 12px; }
    .features { max-width: 960px; margin: 0 auto; padding: 80px 24px; display: grid; grid-template-columns: repeat(3, 1fr); gap: 24px; }
    .card { background: #f5f5f7; border-radius: 16px; padding: 32px 28px; }
    .card .icon { font-size: 28px; margin-bottom: 14px; }
    .card h3 { font-size: 17px; margin-bottom: 8px; }
    .card p { font-size: 14px; color: #6e6e73; line-height: 1.6; }
    .cta { text-align: center; padding: 96px 24px; background: #f5f5f7; }
    .cta h2 { font-size: 34px; margin-bottom: 24px; }
    footer { text-align: center; font-size: 13px; color: #86868b; padding: 32px; }
    @media (max-width: 720px) { .hero h1 { font-size: 36px; } .features { grid-template-columns: 1fr; } }
    </style>
    </head>
    <body>
    <section class="hero">
        <span class="badge">新版本 v1.0 已发布</span>
        <h1>一句话讲清产品价值</h1>
        <p>用一两句话补充说明：为谁解决什么问题、为什么与众不同。</p>
        <a class="btn btn-primary" href="#">免费开始</a>
        <a class="btn btn-ghost" href="#">了解更多 →</a>
    </section>
    <section class="features">
        <div class="card"><div class="icon">⚡️</div><h3>核心特性一</h3><p>这个特性解决什么问题，带来什么具体收益。</p></div>
        <div class="card"><div class="icon">🎯</div><h3>核心特性二</h3><p>这个特性解决什么问题，带来什么具体收益。</p></div>
        <div class="card"><div class="icon">🔒</div><h3>核心特性三</h3><p>这个特性解决什么问题，带来什么具体收益。</p></div>
    </section>
    <section class="cta">
        <h2>准备好开始了吗？</h2>
        <a class="btn btn-primary" href="#">立即体验</a>
    </section>
    <footer>© 2026 公司或产品名</footer>
    </body>
    </html>
    """ }

    static var htmlReport: String { """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>数据报告</title>
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif; color: #1d1d1f; background: #f5f5f7; }
    .container { max-width: 880px; margin: 0 auto; padding: 48px 24px; }
    header { margin-bottom: 36px; }
    header .meta { font-size: 13px; color: #86868b; margin-bottom: 8px; }
    header h1 { font-size: 34px; letter-spacing: -0.01em; }
    .kpis { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 40px; }
    .kpi { background: #fff; border-radius: 14px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
    .kpi .label { font-size: 12px; color: #86868b; margin-bottom: 6px; }
    .kpi .value { font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .kpi .delta { font-size: 12px; margin-top: 4px; }
    .up { color: #0a7d33; } .down { color: #c0392b; }
    section { background: #fff; border-radius: 14px; padding: 28px 32px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,.06); }
    h2 { font-size: 20px; margin-bottom: 14px; }
    p, li { font-size: 15px; color: #424245; line-height: 1.7; }
    ul { padding-left: 20px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 8px; }
    th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #ececf0; }
    th { color: #86868b; font-weight: 600; font-size: 12px; }
    @media (max-width: 720px) { .kpis { grid-template-columns: repeat(2, 1fr); } }
    </style>
    </head>
    <body>
    <div class="container">
    <header>
        <div class="meta">报告周期：2026 年第 周 · 生成于 \(datePlaceholder)</div>
        <h1>业务数据周报</h1>
    </header>
    <div class="kpis">
        <div class="kpi"><div class="label">核心指标一</div><div class="value">12,480</div><div class="delta up">▲ 8.2%</div></div>
        <div class="kpi"><div class="label">核心指标二</div><div class="value">86.5%</div><div class="delta up">▲ 1.4pt</div></div>
        <div class="kpi"><div class="label">核心指标三</div><div class="value">3,217</div><div class="delta down">▼ 2.1%</div></div>
        <div class="kpi"><div class="label">核心指标四</div><div class="value">98.2%</div><div class="delta up">▲ 0.3pt</div></div>
    </div>
    <section>
        <h2>本周要点</h2>
        <ul>
            <li>要点一：发生了什么，意味着什么。</li>
            <li>要点二：发生了什么，意味着什么。</li>
        </ul>
    </section>
    <section>
        <h2>明细数据</h2>
        <table>
            <tr><th>维度</th><th>本周</th><th>上周</th><th>环比</th></tr>
            <tr><td>项目 A</td><td>—</td><td>—</td><td>—</td></tr>
            <tr><td>项目 B</td><td>—</td><td>—</td><td>—</td></tr>
        </table>
    </section>
    <section>
        <h2>结论与下周计划</h2>
        <p>结论一句话。下周聚焦三件事：</p>
        <ul><li>计划一</li><li>计划二</li><li>计划三</li></ul>
    </section>
    </div>
    </body>
    </html>
    """ }

    static var htmlResume: String { """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>个人简历</title>
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif; color: #2c2c2e; background: #ececee; }
    .page { max-width: 800px; margin: 40px auto; background: #fff; padding: 56px 64px; box-shadow: 0 2px 12px rgba(0,0,0,.08); }
    header { border-bottom: 2px solid #2c2c2e; padding-bottom: 20px; margin-bottom: 28px; }
    header h1 { font-size: 32px; letter-spacing: 0.02em; }
    header .title { font-size: 15px; color: #6e6e73; margin-top: 6px; }
    header .contact { font-size: 13px; color: #6e6e73; margin-top: 10px; }
    header .contact span { margin-right: 16px; }
    h2 { font-size: 15px; letter-spacing: 0.12em; color: #2c2c2e; border-bottom: 1px solid #d8d8dc; padding-bottom: 6px; margin: 28px 0 14px; }
    .item { margin-bottom: 16px; }
    .item-head { display: flex; justify-content: space-between; align-items: baseline; }
    .item-head strong { font-size: 15px; }
    .item-head time { font-size: 12.5px; color: #86868b; font-variant-numeric: tabular-nums; }
    .item .sub { font-size: 13.5px; color: #6e6e73; margin: 2px 0 6px; }
    ul { padding-left: 18px; }
    li { font-size: 13.5px; color: #424245; line-height: 1.65; margin-bottom: 3px; }
    .skills span { display: inline-block; font-size: 12.5px; background: #f0f0f3; border-radius: 6px; padding: 4px 10px; margin: 0 6px 6px 0; }
    @media print { body { background: #fff; } .page { margin: 0; box-shadow: none; max-width: none; } }
    </style>
    </head>
    <body>
    <div class="page">
    <header>
        <h1>姓 名</h1>
        <div class="title">职位方向 · X 年经验</div>
        <div class="contact"><span>📧 name@example.com</span><span>📱 138-0000-0000</span><span>📍 城市</span></div>
    </header>
    <h2>个人总结</h2>
    <p style="font-size:14px;color:#424245;line-height:1.7">两三句话：你的领域、最硬的一项成绩、正在找什么样的机会。</p>
    <h2>工作经历</h2>
    <div class="item">
        <div class="item-head"><strong>公司名称 · 职位</strong><time>2023.04 — 至今</time></div>
        <div class="sub">所在团队与负责方向</div>
        <ul>
            <li>用动词开头，写清做了什么 + 量化结果（提升 X%、支撑 X 量级）。</li>
            <li>第二条成绩。</li>
        </ul>
    </div>
    <div class="item">
        <div class="item-head"><strong>上一家公司 · 职位</strong><time>2020.07 — 2023.03</time></div>
        <div class="sub">所在团队与负责方向</div>
        <ul><li>成绩一。</li><li>成绩二。</li></ul>
    </div>
    <h2>项目经历</h2>
    <div class="item">
        <div class="item-head"><strong>项目名称</strong><time>2024</time></div>
        <ul><li>项目解决了什么问题，你的角色与贡献，最终效果。</li></ul>
    </div>
    <h2>技能</h2>
    <div class="skills"><span>技能一</span><span>技能二</span><span>技能三</span><span>技能四</span></div>
    <h2>教育经历</h2>
    <div class="item">
        <div class="item-head"><strong>学校 · 专业</strong><time>2016 — 2020</time></div>
    </div>
    </div>
    </body>
    </html>
    """ }

    // MARK: - Theme token defaults

    struct ThemeTokenDefaults {
        let accent: String
        let bg: String
        let text: String
        let font: String
        let width: String
        let fontMono: String
    }

    static let tufteTokenDefaults = ThemeTokenDefaults(
        accent: "#0066cc",
        bg: "#ffffff",
        text: "#1a1a1a",
        font: "Georgia, 'Times New Roman', serif",
        width: "680px",
        fontMono: "Consolas, 'Courier New', monospace"
    )

    static let craftTokenDefaults = ThemeTokenDefaults(
        accent: "#0066cc",
        bg: "#f5f5f7",
        text: "#1d1d1f",
        font: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        width: "720px",
        fontMono: "'SF Mono', Menlo, monospace"
    )

    static let darkTokenDefaults = ThemeTokenDefaults(
        accent: "#58a6ff",
        bg: "#0d1117",
        text: "#e6edf3",
        font: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        width: "760px",
        fontMono: "'SF Mono', Menlo, 'Courier New', monospace"
    )

    // MARK: - Theme helpers

    static func tokenDefaults(for templateID: String) -> ThemeTokenDefaults {
        switch templateID {
        case "html-tufte": return tufteTokenDefaults
        case "html-craft": return craftTokenDefaults
        case "html-dark":  return darkTokenDefaults
        default:           return craftTokenDefaults
        }
    }

    static func css(for templateID: String) -> String {
        switch templateID {
        case "html-tufte": return tufteCSS
        case "html-craft": return craftCSS
        case "html-dark":  return darkCSS
        default:           return craftCSS
        }
    }

    // MARK: - HTML theme CSS (CSS variable–driven)

    static let tufteCSS = """
    :root {
      --accent: #0066cc;
      --bg: #ffffff;
      --text: #1a1a1a;
      --font: Georgia, 'Times New Roman', serif;
      --width: 680px;
      --font-mono: Consolas, 'Courier New', monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: var(--font);
        font-size: 16px; line-height: 1.6; color: var(--text);
        background: var(--bg); max-width: var(--width); margin: 0 auto; padding: 48px 24px;
    }
    h1, h2, h3 { font-family: var(--font); font-variant: small-caps; font-weight: normal; letter-spacing: 0.04em; color: var(--text); }
    h1 { font-size: 1.8em; border-bottom: 1px solid #ccc; padding-bottom: 8px; margin: 32px 0 16px; }
    h2 { font-size: 1.3em; border-bottom: 1px solid #e0e0e0; padding-bottom: 4px; margin: 28px 0 12px; }
    h3 { font-size: 1.1em; margin: 20px 0 10px; }
    p  { margin: 0 0 14px; }
    a  { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    blockquote { border-left: 3px solid #666; background: #f9f9f9; margin: 16px 0; padding: 10px 16px; color: #444; font-style: italic; }
    pre { background: #f4f4f4; border: 1px solid #ddd; border-radius: 4px; padding: 14px 16px; overflow-x: auto; margin: 16px 0; }
    code { font-family: var(--font-mono); font-size: 0.88em; background: #f4f4f4; padding: 1px 4px; border-radius: 3px; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 0.92em; }
    th, td { border: 1px solid #ccc; padding: 8px 12px; text-align: left; }
    th { background: #f4f4f4; font-weight: bold; }
    hr { border: none; border-top: 1px solid #ccc; margin: 28px 0; }
    ul, ol { padding-left: 24px; margin: 0 0 14px; }
    li { margin-bottom: 4px; }
    """

    static let craftCSS = """
    :root {
      --accent: #0066cc;
      --bg: #f5f5f7;
      --text: #1d1d1f;
      --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
      --width: 720px;
      --font-mono: 'SF Mono', Menlo, monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: var(--font);
        font-size: 15px; line-height: 1.65; color: var(--text);
        background: var(--bg); max-width: var(--width); margin: 0 auto; padding: 32px 20px;
    }
    article, section { background: #fff; border-radius: 12px; padding: 28px 32px; margin-bottom: 20px; box-shadow: 0 1px 4px rgba(0,0,0,0.07), 0 4px 16px rgba(0,0,0,0.04); }
    h1 { font-size: 1.75em; font-weight: 700; letter-spacing: -0.02em; color: var(--text); margin: 0 0 18px; }
    h2 { font-size: 1.25em; font-weight: 600; color: var(--text); margin: 24px 0 10px; }
    h3 { font-size: 1.05em; font-weight: 600; color: #444; margin: 18px 0 8px; }
    p  { margin: 0 0 12px; color: #333; }
    a  { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    blockquote { border-left: 3px solid var(--accent); background: #f0f4ff; margin: 14px 0; padding: 10px 16px; border-radius: 0 8px 8px 0; color: #444; }
    pre { background: #f0f0f5; border-radius: 8px; padding: 16px; overflow-x: auto; margin: 14px 0; }
    code { font-family: var(--font-mono); font-size: 0.86em; background: #f0f0f5; color: #6e40c9; padding: 1px 5px; border-radius: 4px; }
    pre code { background: none; padding: 0; color: var(--text); }
    table { border-collapse: collapse; width: 100%; margin: 14px 0; font-size: 0.91em; }
    th, td { border: 1px solid #e5e5ea; padding: 8px 14px; text-align: left; }
    th { background: #f5f5f7; font-weight: 600; }
    hr { border: none; border-top: 1px solid #e5e5ea; margin: 24px 0; }
    ul, ol { padding-left: 22px; margin: 0 0 12px; }
    li { margin-bottom: 5px; }
    """

    static let darkCSS = """
    :root {
      --accent: #58a6ff;
      --bg: #0d1117;
      --text: #e6edf3;
      --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
      --width: 760px;
      --font-mono: 'SF Mono', Menlo, 'Courier New', monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: var(--font);
        font-size: 15px; line-height: 1.7; color: var(--text);
        background: var(--bg); max-width: var(--width); margin: 0 auto; padding: 48px 24px;
    }
    h1 { font-size: 2em; font-weight: 700; background: linear-gradient(90deg, #79c0ff, #a5a6ff); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; margin: 0 0 20px; }
    h2 { font-size: 1.4em; font-weight: 600; background: linear-gradient(90deg, #58a6ff, #bc8cff); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; margin: 32px 0 12px; padding-bottom: 8px; border-bottom: 1px solid #21262d; }
    h3 { font-size: 1.15em; font-weight: 600; color: #c9d1d9; margin: 24px 0 8px; }
    p  { margin: 0 0 14px; color: #c9d1d9; }
    a  { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    blockquote { border-left: 3px solid #39d353; background: #161b22; margin: 16px 0; padding: 12px 16px; border-radius: 0 6px 6px 0; color: #8b949e; font-style: italic; }
    pre { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 16px; overflow-x: auto; margin: 16px 0; }
    code { font-family: var(--font-mono); font-size: 0.86em; background: #161b22; color: #39d353; padding: 2px 5px; border-radius: 4px; }
    pre code { background: none; padding: 0; color: var(--text); }
    table { border-collapse: collapse; width: 100%; margin: 16px 0; font-size: 0.91em; }
    th, td { border: 1px solid #30363d; padding: 8px 14px; text-align: left; }
    th { background: #161b22; font-weight: 600; color: #c9d1d9; }
    hr { border: none; border-top: 1px solid #21262d; margin: 28px 0; }
    ul, ol { padding-left: 22px; margin: 0 0 14px; }
    li { margin-bottom: 5px; color: #c9d1d9; }
    """

    // MARK: - Full HTML theme templates

    static var htmlTufte: String { htmlShell(title: "Tufte Document", css: tufteCSS) }
    static var htmlCraft: String { htmlShell(title: "Craft Document", css: craftCSS) }
    static var htmlDark:  String { htmlShell(title: "Dark Document",  css: darkCSS)  }

    // MARK: - Private helpers

    private static var datePlaceholder: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private static func htmlShell(title: String, css: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(title)</title>
            <style>
        \(css)
            </style>
        </head>
        <body>
        <article>
        <h1>\(title)</h1>
        <p>在这里编写正文内容。</p>
        </article>
        </body>
        </html>
        """
    }
}
