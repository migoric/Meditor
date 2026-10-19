import XCTest
@testable import MEditor

// MARK: - ClaudeCLIStreamParserTests
//
// ClaudeCLI agent 路径流式（Phase 1）：`claude -p --output-format stream-json
// --verbose --include-partial-messages` 输出 JSONL 事件，解析器把
// text_delta 增量 / assistant 快照 / result 终态统一成「文本增量」供 UI 渲染。
// 这里用构造的 stream-json 行验证增量回调与去重逻辑（事件格式本机 claude 2.1.233 实测）。

final class ClaudeCLIStreamParserTests: XCTestCase {

    // MARK: - text_delta 真增量（--include-partial-messages）

    func test_textDelta_yieldsIncrements() {
        var p = ClaudeStreamJSONParser()
        let l1 = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#
        let l2 = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}}"#
        XCTAssertEqual(p.ingest(line: l1), "Hello")
        XCTAssertEqual(p.ingest(line: l2), " world")
        XCTAssertEqual(p.yielded, "Hello world")
    }

    // MARK: - assistant 快照差分（无 partial 时的兜底路径）

    func test_assistantSnapshot_yieldsSuffixDiff() {
        var p = ClaudeStreamJSONParser()
        let s1 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"你好"}]}}"#;
        let s2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"你好，世界"}]}}"#;
        XCTAssertEqual(p.ingest(line: s1), "你好")
        XCTAssertEqual(p.ingest(line: s2), "，世界")
    }

    // MARK: - partial 增量与 assistant 快照同时到达：不重复上抛

    func test_partialThenSnapshot_deduplicates() {
        var p = ClaudeStreamJSONParser()
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#
        let snapshot = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello!"}]}}"#;
        XCTAssertEqual(p.ingest(line: delta), "Hello")
        // 快照全量 "Hello!"，已 yield "Hello" → 只补 "!"
        XCTAssertEqual(p.ingest(line: snapshot), "!")
        // 同一快照再来一次（重复事件）→ 无新增
        XCTAssertNil(p.ingest(line: snapshot))
    }

    // MARK: - result 终态：成功收尾差分

    func test_resultSuccess_emitsFinalSuffix() {
        var p = ClaudeStreamJSONParser()
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Hello world"}"#
        _ = p.ingest(line: delta)
        XCTAssertEqual(p.ingest(line: result), " world")
        XCTAssertEqual(p.yielded, "Hello world")
        XCTAssertNil(p.resultError)
    }

    // MARK: - result 终态：失败记入 resultError，不上抛文本

    func test_resultError_capturedNotYielded() {
        var p = ClaudeStreamJSONParser()
        let result = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key"}"#
        XCTAssertNil(p.ingest(line: result))
        XCTAssertEqual(p.resultError, "Invalid API key")
        XCTAssertEqual(p.yielded, "")
    }

    // MARK: - 无关事件与坏行：静默忽略

    func test_unrelatedAndMalformedLines_ignored() {
        var p = ClaudeStreamJSONParser()
        XCTAssertNil(p.ingest(line: #"{"type":"system","subtype":"init","session_id":"x"}"#))
        XCTAssertNil(p.ingest(line: #"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#))
        XCTAssertNil(p.ingest(line: #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"…"}}}"#))
        XCTAssertNil(p.ingest(line: "not json at all"))
        XCTAssertNil(p.ingest(line: ""))
        XCTAssertEqual(p.yielded, "")
        XCTAssertNil(p.resultError)
    }

    // MARK: - CLI 侧工具结果（user 事件）：失败要留痕，不能静默吞掉
    //
    // 背景：`claude -p` 默认带着自己的 Write / Edit / Bash 工具。它一旦被调用，MEditor
    // 只会收到 tool_use 块 + 一条 is_error 的 tool_result（"requested permissions … but
    // you haven't granted it yet"），此前整条事件被丢弃 ⇒ 用户只看到模型说"等待你授权"，
    // 界面上没有任何按钮也没有任何错误。现在 CLI 工具已用 `--tools ""` 关掉，
    // 这里兜底保证同类事件至少能被透出。

    func test_userEvent_toolResultError_captured() {
        var p = ClaudeStreamJSONParser()
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"Claude requested permissions to write to /tmp/a.md, but you haven't granted it yet."}]}}"#
        XCTAssertNil(p.ingest(line: line), "工具结果不上抛为文本增量")
        XCTAssertEqual(p.toolErrorNotice,
                       "Claude requested permissions to write to /tmp/a.md, but you haven't granted it yet.")
    }

    /// content 为 [{type:text,text:…}] 数组形态时同样能取到文本。
    func test_userEvent_toolResultError_arrayContent() {
        var p = ClaudeStreamJSONParser()
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"Bash tool was denied"}]}]}}"#
        XCTAssertNil(p.ingest(line: line))
        XCTAssertEqual(p.toolErrorNotice, "Bash tool was denied")
    }

    /// 成功的工具结果不该被当成错误透出。
    func test_userEvent_successToolResult_ignored() {
        var p = ClaudeStreamJSONParser()
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}"#
        XCTAssertNil(p.ingest(line: line))
        XCTAssertNil(p.toolErrorNotice)
    }
}

// MARK: - ToolCallStreamFilterTests
//
// 流式上抛给 UI 前过滤 <tool_call>…</tool_call> 协议块（含跨 chunk 切断的标签）。

final class ToolCallStreamFilterTests: XCTestCase {

    func test_plainText_passesThrough() {
        var f = ToolCallStreamFilter()
        XCTAssertEqual(f.process("你好") + f.process("，世界"), "你好，世界")
        XCTAssertEqual(f.flush(), "")
    }

    func test_toolCallBlock_stripped() {
        var f = ToolCallStreamFilter()
        var out = ""
        out += f.process("好的，我来读一下文件。")
        out += f.process("<tool_call>\n<name>read_document</name>\n<arguments>{}</arguments>\n</tool_call>")
        out += f.process("后续文本")
        out += f.flush()
        XCTAssertEqual(out, "好的，我来读一下文件。后续文本")
    }

    func test_tagSplitAcrossChunks_stripped() {
        var f = ToolCallStreamFilter()
        var out = ""
        // 标签被切成 "<tool" + "_call>…" 两段
        out += f.process("前文<tool")
        out += f.process("_call><name>x</name><arguments>{}</arguments></tool_call>后文")
        out += f.flush()
        XCTAssertEqual(out, "前文后文")
    }

    func test_closeTagSplitAcrossChunks_stripped() {
        var f = ToolCallStreamFilter()
        var out = ""
        out += f.process("A<tool_call><name>x</name><arguments>{}</arguments></tool")
        out += f.process("_call>B")
        out += f.flush()
        XCTAssertEqual(out, "AB")
    }

    func test_pendingPrefixAtStreamEnd_flushedAsText() {
        var f = ToolCallStreamFilter()
        // 流在疑似标签前缀处结束：尾部的 "<" 是 openTag 前缀，暂存；
        // flush 时发现不是标签，作为普通文本原样放出
        XCTAssertEqual(f.process("结尾是<"), "结尾是")
        XCTAssertEqual(f.flush(), "<")
    }

    func test_partialOpenPrefixAtChunkBoundary_heldBack() {
        var f = ToolCallStreamFilter()
        // "前文<tool_call" 结尾的 "<tool_call" 是 openTag 真前缀，应暂存
        XCTAssertEqual(f.process("前文<tool_call"), "前文")
        // 下一 chunk 没补上 ">"（实际不是标签）→ 暂存内容作为普通文本放出
        XCTAssertEqual(f.process(" 这个字"), "<tool_call 这个字")
        XCTAssertEqual(f.flush(), "")
    }
}
