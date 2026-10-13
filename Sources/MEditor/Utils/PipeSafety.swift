import Foundation

/// 管道写端的 SIGPIPE 防护。
///
/// 背景：往「读端已关闭」的管道写数据，内核默认处置是向写进程投递 **SIGPIPE**，
/// 而 SIGPIPE 的默认动作是**终止整个进程**，且不打印任何诊断。对 GUI app 来说，
/// 这意味着一个 MCP server / CLI 子进程的意外退出就可能把 app 静默打死，
/// 而不是让 `write` 抛错、走既有的 catch 分支。
///
/// 实证（2026-10-14）：`MCPClientTransportTests.test_stdio_processExit_failsPendingAndFutureRequests`
/// 用 `/usr/bin/true` 构造「子进程立即退出」的传输并立刻写请求——读循环还没处理 EOF 时
/// 那次 write 就命中死管道，CI 上表现为测试进程静默死亡、退出码 1、无任何断言输出。
/// 用同样代码路径写的最小探针 20/20 复现，退出码 **141 = 128 + 13(SIGPIPE)**；
/// 打上本修复后 20/20 存活，且 write 转为抛出（`EPIPE`），证明因果成立。
///
/// 做法：Darwin 的 `fcntl(F_SETNOSIGPIPE)` 只作用于**这一个 fd**，之后 write 返回
/// `EPIPE`（Foundation 包成 `NSError` 抛出），不动进程全局信号处置——比
/// `signal(SIGPIPE, SIG_IGN)` 收敛，不会顺带改变 app 其他写路径的行为。
///
/// 用法：子进程 `run()` 之后、第一次写之前调用一次即可。
enum PipeSafety {
    /// 让 `handle` 指向的写端在对端消失时返回错误，而不是触发 SIGPIPE。
    /// 对非法/已关闭的 fd 调用是安全的（`fcntl` 失败即忽略，不影响后续写入）。
    static func disableSIGPIPE(on handle: FileHandle) {
        var enable: Int32 = 1
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, &enable)
    }
}
