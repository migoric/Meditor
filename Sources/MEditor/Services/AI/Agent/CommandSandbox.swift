import Foundation

// MARK: - CommandRisk

/// 命令风险等级。
/// - `.safe`    — 可直接执行（或走普通确认流程）
/// - `.warn`    — 高风险，每次都必须弹确认，不复用缓存
/// - `.blocked` — 直接拒绝，不弹确认框
public enum CommandRisk: Equatable, Sendable {
    case safe
    case warn(reason: String)
    case blocked(reason: String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// 供 UI 显示的风险说明文字；.safe 返回 nil。
    public var message: String? {
        switch self {
        case .safe:              return nil
        case .warn(let r):       return r
        case .blocked(let r):    return r
        }
    }
}

// MARK: - CwdValidation

/// 工作目录合规性校验结果。
public enum CwdValidation: Equatable, Sendable {
    case allowed(resolved: String)
    case outsideWorkspace(path: String, workspaceRoot: String)
    case traversalDetected(path: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// 失败时给用户/工具层的错误描述。
    public var errorMessage: String? {
        switch self {
        case .allowed:
            return nil
        case .outsideWorkspace(let path, let root):
            return "安全限制：工作目录 \(path) 不在工作区内（\(root)），已拒绝。"
        case .traversalDetected(let path):
            return "安全限制：检测到路径穿越（\(path)），已拒绝。"
        }
    }
}

// MARK: - CommandSandbox

/// 纯静态的命令安全分析器，无副作用，完全可单测。
///
/// 职责：
///   1. 风险等级评估（blocked → warn → safe）
///   2. 工作目录合规性校验（必须在 workspace root 内）
///   3. 审批 key 生成（用于去重确认，避免相同命令反复弹窗）
///
/// 所有方法都是 `static`，不持有任何状态。
public enum CommandSandbox {

    // MARK: - Risk Rules

    /// 一条风险匹配规则。
    public struct RiskRule: Sendable {
        /// 命中判定用的模式文本（含义取决于 `kind`）。
        public let pattern: String
        /// 匹配方式：`.substring` 用于含特殊符号的固定短语（如 "rm -rf /"），
        /// `.commandToken` 用于裸命令名（如 "nc"、"ssh"），按词边界 + 命令起始位置匹配，
        /// 避免 "npm run sync" 命中 "nc"、"git commit -m 'sync data'" 命中 "nc" 这类误杀。
        public let kind: MatchKind
        /// 风险类型（blocked / warn），risk.message 由 assess 生成，rule 只提供 label。
        public let label: String
        /// 规则描述（用于生成 message）。
        public let description: String

        public enum MatchKind: Sendable { case substring, commandToken }

        public init(pattern: String, kind: MatchKind = .substring, label: String, description: String) {
            self.pattern = pattern
            self.kind = kind
            self.label = label
            self.description = description
        }
    }

    /// 直接拒绝，不弹确认框。匹配第一条即止。
    public static let blockedRules: [RiskRule] = [
        .init(pattern: "rm -rf /",           label: "blocked", description: "删除根目录"),
        .init(pattern: "rm -rf ~",            label: "blocked", description: "删除 home 目录"),
        .init(pattern: "rm -rf $home",        label: "blocked", description: "删除 home 目录"),
        .init(pattern: ":(){ :|:& };",        label: "blocked", description: "Fork 炸弹"),
        .init(pattern: "mkfs",                kind: .commandToken, label: "blocked", description: "磁盘格式化"),
        // ">/dev/" 设备写入改由 writesToBlockedDevice 精确判定：无条件拦 ">/dev/"
        // 会误杀 `2>/dev/null` 这类日常命令（见 assess 中的调用）。
        .init(pattern: "dd if=",              label: "blocked", description: "磁盘低级写入"),
        .init(pattern: "sudo",                kind: .commandToken, label: "blocked", description: "sudo 提权"),
        .init(pattern: "doas",                kind: .commandToken, label: "blocked", description: "doas 提权"),
        // osascript 的 AppleScript 提权写法（do shell script ... with administrator privileges）
        // 会弹系统密码框拿到 root，与 sudo 同级拦截
        .init(pattern: "administrator privileges", label: "blocked", description: "AppleScript 提权"),
        .init(pattern: "su -",                label: "blocked", description: "切换 root"),
        .init(pattern: "chmod 777 /",         label: "blocked", description: "系统目录权限篡改"),
        .init(pattern: "chown -r /",          label: "blocked", description: "系统目录 owner 篡改"),
        .init(pattern: "defaults delete com.apple", label: "blocked", description: "删除系统级 defaults"),
        .init(pattern: "curl",                kind: .commandToken, label: "blocked", description: "外部网络请求（含 pipe shell 风险）"),
        .init(pattern: "wget",                kind: .commandToken, label: "blocked", description: "外部网络下载"),
        .init(pattern: "killall",             kind: .commandToken, label: "blocked", description: "批量终止进程"),
        .init(pattern: "launchctl unload",    label: "blocked", description: "卸载系统服务"),
        .init(pattern: "launchctl remove",    label: "blocked", description: "移除系统服务"),
        .init(pattern: "/etc/passwd",         label: "blocked", description: "访问系统账户文件"),
        .init(pattern: "/etc/sudoers",        label: "blocked", description: "访问 sudoers"),
        // 网络工具（curl/wget 绕过路径）——命令名 token 匹配，避免 "npm run sync"/"vsync"/"concat" 误杀
        .init(pattern: "nc",                  kind: .commandToken, label: "blocked", description: "netcat 网络工具"),
        .init(pattern: "ncat",                kind: .commandToken, label: "blocked", description: "ncat 网络工具"),
        .init(pattern: "nmap",                kind: .commandToken, label: "blocked", description: "网络扫描"),
        .init(pattern: "ssh",                 kind: .commandToken, label: "blocked", description: "SSH 远程连接"),
        .init(pattern: "scp",                 kind: .commandToken, label: "blocked", description: "SCP 文件传输"),
        .init(pattern: "rsync",               kind: .commandToken, label: "blocked", description: "rsync 远程同步"),
        .init(pattern: "ftp",                 kind: .commandToken, label: "blocked", description: "FTP 连接"),
        .init(pattern: "sftp",                kind: .commandToken, label: "blocked", description: "SFTP 连接"),
    ]

    /// 高风险：每次都必须弹确认，不复用已缓存的审批 key。
    public static let warnRules: [RiskRule] = [
        .init(pattern: "rm",                kind: .commandToken, label: "warn", description: "删除文件"),
        .init(pattern: "mv",                kind: .commandToken, label: "warn", description: "移动 / 重命名（可能覆盖）"),
        .init(pattern: "npm publish",       label: "warn", description: "发布到 npm 公共仓库"),
        .init(pattern: "yarn publish",      label: "warn", description: "发布到 npm 公共仓库"),
        .init(pattern: "pnpm publish",      label: "warn", description: "发布到 npm 公共仓库"),
        .init(pattern: "git push",          label: "warn", description: "推送到远端"),
        .init(pattern: "git reset --hard",  label: "warn", description: "丢弃工作区未提交改动"),
        .init(pattern: "git clean -fd",     label: "warn", description: "清理未跟踪文件"),
        .init(pattern: "git force-push",    label: "warn", description: "强制推送"),
        .init(pattern: "drop table",        label: "warn", description: "SQL 删表"),
        .init(pattern: "drop database",     label: "warn", description: "SQL 删库"),
        .init(pattern: "truncate table",    label: "warn", description: "SQL 清空表"),
        // 内联脚本执行（可绕过 curl/wget 直接拦截）—— 命令名 token 匹配，避免子串误杀
        .init(pattern: "python -c",         label: "warn", description: "Python 内联执行"),
        .init(pattern: "python3 -c",        label: "warn", description: "Python3 内联执行"),
        .init(pattern: "node -e",           label: "warn", description: "Node.js 内联执行"),
        .init(pattern: "perl -e",           label: "warn", description: "Perl 内联执行"),
        .init(pattern: "ruby -e",           label: "warn", description: "Ruby 内联执行"),
        .init(pattern: "bash -c",           label: "warn", description: "Bash 内联执行（可绕过命令过滤）"),
        .init(pattern: "sh -c",             label: "warn", description: "Shell 内联执行（可绕过命令过滤）"),
        .init(pattern: "zsh -c",            label: "warn", description: "Zsh 内联执行（可绕过命令过滤）"),
        .init(pattern: "eval",              kind: .commandToken, label: "warn", description: "eval 动态执行"),
        .init(pattern: "| bash",            label: "warn", description: "管道 bash（常见恶意安装模式）"),
        .init(pattern: "| sh",              label: "warn", description: "管道 shell（常见恶意安装模式）"),
    ]

    // MARK: - Assess

    /// 评估命令风险等级。纯函数，无副作用。
    ///
    /// 匹配优先级：blocked > warn > safe。
    /// 返回的 `.warn`/`.blocked` 中已包含用户可读的 reason 文字。
    public static func assess(_ command: String) -> CommandRisk {
        let trimmed = command.lowercased().trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .safe }
        // 空白规范化（连续空格/tab 压缩成单个空格）：`.substring` 规则里带空格的
        // 固定短语（如 "rm -rf /"、"git reset --hard"）本来假定用户/模型只用单个
        // 空格分隔参数，但 shell 允许任意数量空白（`rm  -rf  /`、用 tab 代替空格），
        // 之前逐字匹配会被这类写法绕过——这里统一规范化后再匹配，一次性覆盖。
        let lower = normalizeCommand(trimmed)

        for rule in blockedRules where matches(rule, in: lower) {
            return .blocked(reason: "🚫 安全限制：\(rule.description)，该命令已被自动拒绝。\n命令：\(truncated(command))")
        }

        // 设备文件写入：精确到目标，放行 /dev/null、/dev/stdout、/dev/stderr、/dev/fd/*，
        // 其余（/dev/disk0 等）仍直接拒绝。此前的 ">/dev/" 子串规则会误杀 `2>/dev/null`。
        if writesToBlockedDevice(lower) {
            return .blocked(reason: "🚫 安全限制：写入设备文件，该命令已被自动拒绝。\n命令：\(truncated(command))")
        }

        for rule in warnRules where matches(rule, in: lower) {
            return .warn(reason: "⚠️ 高风险操作：\(rule.description)，请确认后继续。")
        }

        return .safe
    }

    /// 把命令中的连续空白（空格/tab/换行）压缩成单个空格，供风险规则匹配前统一处理。
    private static func normalizeWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t\\n]+", with: " ", options: .regularExpression)
    }

    /// 规则匹配前的命令规范化：在空白压缩之上再处理两种已知绕过写法。
    /// 保持保守——宁可多拦（多拦只会多弹确认/多拒一条命令），不放过等价变体。
    /// 注意：字符串匹配只是纵深防御的一层（可被 shell 语法进一步绕过），
    /// 这里不做、也不试图做成完备的 shell 解析。
    private static func normalizeCommand(_ s: String) -> String {
        var out = normalizeWhitespace(s)
        // 1) 去除反斜杠引用：shell 里 `\c` 等价于 `c`，`\curl` / `c\url` 这类
        //    引用变体能让命令名绕过词边界匹配。直接删掉反斜杠再匹配——
        //    只会让真实 token 更可见（保守方向），路径里的合法反斜杠（如 `\ `）
        //    删除后不会凭空拼出新的命令 token。
        out = out.replacingOccurrences(of: "\\", with: "")
        // 2) 去除单双引号：shell 会把 `c''url` / `c"u"rl` 拼成同一个命令名。
        //    与反斜杠处理同理，宁可让参数中的高风险文本也进入匹配，不让命令名绕过。
        out = out.replacingOccurrences(of: "'", with: "")
        out = out.replacingOccurrences(of: "\"", with: "")
        // 3) 管道符后紧跟字母/数字时补空格：`echo x |bash` 与 `| bash` 等价，
        //    无空格写法本来匹配不到规则表里的 "| bash"/"| sh"。只在 `|` 后是
        //    字母/数字时插入，避免破坏 ":(){ :|:& };:" 这类含 `|:` 的 blocked 模式。
        out = out.replacingOccurrences(of: #"\|(?=[a-z0-9])"#, with: "| ",
                                       options: .regularExpression)
        return out
    }

    /// 按规则的匹配方式判定是否命中。
    private static func matches(_ rule: RiskRule, in lowerCommand: String) -> Bool {
        switch rule.kind {
        case .substring:
            return lowerCommand.contains(rule.pattern)
        case .commandToken:
            return containsCommandToken(rule.pattern, in: lowerCommand)
        }
    }

    /// 判断 `token` 是否作为「命令名」出现在 `command` 中：
    /// 前面是字符串起始、shell 命令分隔符（空白/`;`/`|`/`&`/`(`/引号）或路径分隔符 `/`，
    /// 后面是字符串结束或非字母数字字符（空白/`;`/`|`/`&`/参数 `-`/路径 `/`/引号 等）。
    /// 用于避免 "npm run sync" 命中 "nc"、"git commit -m 'sync data'" 命中 "nc"、
    /// "concat files" 命中 "nc" 这类把命令名当子串到处匹配的误杀；
    /// 同时覆盖 `"curl"`、`'ssh'` 这类引号包裹的命令名。
    /// 起始边界必须包含 `/`：否则 `/usr/bin/curl ...`、`/opt/homebrew/bin/wget ...`
    /// 这类用绝对/相对路径调用二进制的写法会完全绕过 blocked 规则——之前的边界集
    /// 只在结束侧含 `/`（覆盖 "curl/wget" 这种子串误判防护），起始侧遗漏了对称的
    /// "路径分隔符后紧跟命令名" 场景，被视为真实存在的绕过路径而不是误判。
    /// 结束边界不含 `.`：否则 `cat curl.min.js`、`less ./ssh_config.bak` 这类
    /// 「文件名恰好以命令名开头」的无辜参数会被误拦。带 `.` 后缀的真实命令名变体
    /// （mkfs.ext4/mkfs.vfat 是真实存在的二进制）由下面的 command-position 规则单独覆盖：
    /// 只在严格命令位置（行首或 `;` `|` `&` `(` 之后，允许空白）才接受 `.` 后缀，
    /// 参数位置一律不认，从而不再误伤 curl.min.js。
    /// 已知缺口：`/usr/bin/mkfs.ext4` 这类「绝对路径 + 带后缀变体」不再命中
    /// （路径前缀与参数文件名无法静态区分），属可接受的收窄。
    /// 注意：字符串匹配只是纵深防御的一层（可被 shell 语法进一步绕过），
    /// 真正的安全边界是 warn/blocked 之外命令的用户确认流程。
    private static func containsCommandToken(_ token: String, in command: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let range = NSRange(command.startIndex..., in: command)
        guard let general = try? NSRegularExpression(
            pattern: "(?:^|[\\s;|&(\"'/])" + escaped + "(?:$|[\\s;|&)/\"'])"
        ) else { return command.contains(token) }
        if general.firstMatch(in: command, range: range) != nil { return true }
        // 带后缀命令名变体（mkfs.ext4）：仅限严格命令位置，见上方 doc comment
        guard let extended = try? NSRegularExpression(
            pattern: "(?:^|[;|&(])\\s*" + escaped + "\\."
        ) else { return false }
        return extended.firstMatch(in: command, range: range) != nil
    }

    /// 重定向目标是否为设备文件（放行 /dev/null、/dev/stdout、/dev/stderr、/dev/fd/*）。
    /// 输入应已是规范化（小写、去反斜杠）后的命令文本。
    static func writesToBlockedDevice(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #">>?\s*/dev/([A-Za-z0-9_./-]+)"#) else {
            return false
        }
        let range = NSRange(command.startIndex..., in: command)
        for match in regex.matches(in: command, range: range) {
            guard let targetRange = Range(match.range(at: 1), in: command) else { continue }
            let target = String(command[targetRange]).lowercased()
            let safe = target == "null"
                || target.hasPrefix("stdout")
                || target.hasPrefix("stderr")
                || target.hasPrefix("fd/")
            if !safe { return true }
        }
        return false
    }

    /// 命令是否包含「可能写出工作区」的重定向/写入语法。
    ///
    /// 用于给 `run_command` 兜底升级风险等级（无 UI 时黑名单不是安全边界）。
    /// 先剔除无害的 `/dev/null`、`2>&1` 等，再看是否仍有 `>` / `>>` / `tee` / `dd of=`。
    /// 字符串判断是启发式（可被 shell 语法绕过），这里只用于「多弹一次确认」的保守方向。
    public static func containsWriteRedirection(_ command: String) -> Bool {
        var s = command
        for safe in [">/dev/null", "2>/dev/null", "&>/dev/null", ">/dev/stdout", ">/dev/stderr", "2>&1"] {
            s = s.replacingOccurrences(of: safe, with: " ")
        }
        if s.contains(">>") || s.contains(">") { return true }
        if containsCommandToken("tee", in: s.lowercased()) { return true }
        if s.contains("dd ") && s.contains("of=") { return true }
        return false
    }

    // MARK: - Cwd Validation
    /// 解析路径中的符号链接，兼容目标尚不存在的场景。
    /// `URL.resolvingSymlinksInPath()` 对不存在的路径会整体放弃解析（实测 macOS 14
    /// 只对完整存在的路径解析中间 symlink），这里改为先向上找到最深的已存在祖先、
    /// 解析它，再把剩余组件拼回去。校验 cwd / 写目标时 root 与 target 两侧都必须
    /// 走这个口径，否则工作区内一个指向 ~/ 的 symlink 就能把路径引到工作区外。
    public static func resolveSymlinks(_ url: URL) -> URL {
        var base = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: base.path), base.path != "/" {
            suffix.insert(base.lastPathComponent, at: 0)
            base.deleteLastPathComponent()
        }
        var resolved = base.resolvingSymlinksInPath()
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved
    }

    /// 校验 cwd 是否在 workspaceRoot 内。
    ///
    /// - Parameters:
    ///   - cwd: 工具层传入的工作目录（绝对路径或相对路径）。
    ///   - workspaceRoot: 当前 workspace 根目录。nil 表示未打开 workspace，此时不限制。
    public static func validateCwd(_ cwd: String, workspaceRoot: String?) -> CwdValidation {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)

        // 未打开 workspace → 不作限制
        guard let root = workspaceRoot, !root.isEmpty else {
            return .allowed(resolved: trimmed.isEmpty ? "" : trimmed)
        }

        // 两侧都先解析符号链接再比较：standardizedFileURL 只规范化路径、不解析
        // symlink，工作区内一个指向 ~/ 的 symlink 就能把 cwd 引到工作区外。
        // （macOS 上 /tmp 本身是 /private/tmp 的 symlink，root 侧也必须解析。）
        let canonical     = resolveSymlinks(URL(fileURLWithPath: trimmed)).path
        let rootCanonical = resolveSymlinks(URL(fileURLWithPath: root)).path

        // 路径穿越检测（规范化后仍在 root 内则允许）
        if trimmed.contains("../") || trimmed.hasSuffix("/..") || trimmed == ".." {
            if !canonical.hasPrefix(rootCanonical) {
                return .traversalDetected(path: cwd)
            }
        }

        if canonical == rootCanonical || canonical.hasPrefix(rootCanonical + "/") {
            return .allowed(resolved: canonical)
        }

        return .outsideWorkspace(path: canonical, workspaceRoot: rootCanonical)
    }

    // MARK: - Approval Key

    /// 生成命令审批 key，用于 per-command 去重确认缓存。
    ///
    /// 设计原则：相同 command + cwd 组合复用已有的确认；
    /// 不同命令或不同目录视为独立操作，各自需要用户确认。
    ///
    /// 注意：warn 级别命令不应被缓存——调用方负责在检测到 warn 时
    /// 跳过 key 检查，直接弹确认框。
    public static func approvalKey(command: String, cwd: String?) -> String {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let dir = cwd?.trimmingCharacters(in: .whitespaces) ?? ""
        // 用竖线分隔，两部分均可能含空格，不影响唯一性
        return "\(cmd)|\(dir)"
    }

    // MARK: - Allowed Commands Check

    /// 检查命令是否符合 allowedCommandPatterns（skill SKILL.md 中声明的白名单）。
    ///
    /// 实现要点（防止 `hasPrefix` 被链式命令绕过）：
    ///   1. 含命令替换/参数展开/反引号（`$(`, `${`, `` ` ``）直接拒绝——这些能在
    ///      一段合法前缀里夹带任意命令；
    ///   2. 按 shell 分隔符（`;` `&&` `||` `|` 换行）切段，**逐段**校验：
    ///      `git log; rm -rf x` 不能因为整串以 "git log" 开头就被放行；
    ///   3. 前缀匹配要求 token 边界（`seg == p` 或 `seg` 以 `p + 空格` 开头），
    ///      避免 `git logs` 命中 `git log`。
    ///
    /// - Parameters:
    ///   - command:  要执行的命令字符串。
    ///   - patterns: 允许的命令前缀列表。nil 表示不限制（允许所有）。
    /// - Returns: `true` 表示命令在白名单内或白名单为空；`false` 表示被白名单拒绝。
    public static func matchesAllowedPatterns(_ command: String, patterns: [String]?) -> Bool {
        guard let patterns, !patterns.isEmpty else { return true }
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return false }

        if cmd.contains("$(") || cmd.contains("${") || cmd.contains("`") { return false }

        let segments = cmd
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .replacingOccurrences(of: "|",  with: ";")
            .replacingOccurrences(of: "\n", with: ";")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return false }

        return segments.allSatisfy { segment in
            patterns.contains { pattern in
                segment == pattern || segment.hasPrefix(pattern + " ")
            }
        }
    }

    // MARK: - Private Helpers

    private static func truncated(_ s: String, maxLength: Int = 80) -> String {
        s.count <= maxLength ? s : String(s.prefix(maxLength)) + "…"
    }
}
