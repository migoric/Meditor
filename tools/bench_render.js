#!/usr/bin/env node
/**
 * 预览渲染管线的纯 JS 基准（node 直跑，不起 WKWebView）：
 *   node tools/bench_render.js
 *
 * 能量什么 / 不能量什么：
 * - render.js 的解析侧（marked.parse / padStructureLines / 切块 / 块缓存）
 *   全在这里，node 与 WKWebView 同为 JSC/V8 级 JIT，量级可信（JSC 通常略慢，
 *   相对比较仍然成立）。
 * - DOMPurify 需要 DOM，node 里 sanitizeHTML 退化为恒等（render.js 自己的
 *   兜底分支）——sanitize 与 DOM 插入的成本由 WKWebView 侧的 bench 补
 *   （Tests/MEditorTests/PreviewRenderBenchTests.swift，MEDITOR_PREVIEW_BENCH=1）。
 *
 * 输出每篇语料：整篇解析 / 分块冷渲染 / 模拟打字（改中段一块再渲染）的耗时，
 * 单位 ms，取多轮中位数。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const PREVIEW = path.join(ROOT, 'Sources/MEditor/Resources/Preview');

// render.js 的 IIFE 以 window 为 global；node 里把 globalThis 顶上。
globalThis.window = globalThis;
vm.runInThisContext(fs.readFileSync(path.join(PREVIEW, 'marked.min.js'), 'utf8'),
                    { filename: 'marked.min.js' });
vm.runInThisContext(fs.readFileSync(path.join(PREVIEW, 'scripts/render.js'), 'utf8'),
                    { filename: 'render.js' });
const R = globalThis.MEditorRender;
if (!R || typeof R.renderMarkdown !== 'function') {
  console.error('MEditorRender 未导出 renderMarkdown —— render.js 的封装变了？');
  process.exit(1);
}

// ── 语料 ─────────────────────────────────────────────────────────────────

/** 真实语料：仓内文档（写得怎么样就怎么样，代表性最高）。 */
function realDocs() {
  const dirs = ['docs', ''];
  const out = [];
  for (const d of dirs) {
    const dir = path.join(ROOT, d);
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.md')) continue;
      const text = fs.readFileSync(path.join(dir, f), 'utf8');
      out.push({ name: 'real:' + (d ? d + '/' : '') + f, text });
    }
  }
  return out;
}

/** 合成病态语料：专门压已知贵路径。 */
function synthDocs() {
  const para = '这是一段普通的正文，包含**加粗**、`行内代码` 与 [链接](https://example.com)。'.repeat(3);
  const code = '```swift\n' + 'let x = compute(array.map { $0 * 2 }) // 注释\n'.repeat(12) + '```';
  const list = [];
  for (let i = 0; i < 2000; i++) list.push(`- 第 ${i} 项：**加粗** 与 \`code\``);
  const table = ['| ' + '列甲乙丙丁戊己庚辛'.split('').join(' | ') + ' |',
                 '|' + ' --- |'.repeat(8)];
  for (let i = 0; i < 300; i++) table.push('|' + ` 单元格 ${i} `.repeat(8) + '|');
  const quotes = [];
  for (let i = 0; i < 800; i++) quotes.push('> '.repeat(1 + (i % 5)) + `嵌套引用 ${i}`);
  return [
    { name: 'synth:段落×3000', text: Array(3000).fill(para).join('\n\n') },
    { name: 'synth:围栏×400', text: Array(400).fill(code).join('\n\n') },
    { name: 'synth:松散列表×2000', text: list.join('\n\n') },
    { name: 'synth:大表格300行', text: table.join('\n') + '\n\n' + para },
    { name: 'synth:深嵌套引用×800', text: quotes.join('\n') },
    { name: 'synth:混合大餐', text: Array(150).fill([para, code, '| a | b |\n| - | - |\n| 1 | 2 |', '> 引用'].flat().join('\n\n')).join('\n\n') },
  ];
}

// ── 计时 ─────────────────────────────────────────────────────────────────

/** 改中段一个块，模拟打字后的重渲染输入。 */
function mutateMiddle(text) {
  const i = text.indexOf('\n\n', Math.floor(text.length / 2));
  if (i === -1) return text + '改';
  return text.slice(0, i) + '\n\n**改动的一段。**' + text.slice(i);
}

function median(samples) {
  const s = samples.slice().sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

/** 跑 fn 若干轮取中位数；首轮前先热身一次（JIT）。 */
function timeIt(fn, rounds = 7) {
  fn();
  const samples = [];
  for (let i = 0; i < rounds; i++) {
    const t0 = performance.now();
    fn();
    samples.push(performance.now() - t0);
  }
  return median(samples);
}

// ── 主流程 ───────────────────────────────────────────────────────────────

const corpus = [...realDocs(), ...synthDocs()];
console.log('语料：%d 篇（real %d / synth %d）\n', corpus.length, realDocs().length, synthDocs().length);
console.log('注：node 侧 sanitize 为恒等（无 DOM），sanitize/DOM 成本见 WKWebView bench。\n');

const header = ['语料'.padEnd(28), 'KB'.padStart(7), '整篇'.padStart(8),
                '分块冷'.padStart(8), '打字热'.padStart(8), 'marked裸'.padStart(8)];
console.log(header.join(''));
console.log('-'.repeat(70));

const totals = { full: 0, cold: 0, warm: 0, raw: 0, kb: 0 };
for (const { name, text } of corpus) {
  const kb = Buffer.byteLength(text) / 1024;
  const raw = timeIt(() => globalThis.marked.parse(text, { gfm: true, breaks: false }));
  const full = timeIt(() => R.renderMarkdown(text));
  // 分块冷渲染：块缓存是模块级的，用独一份前后缀保证不命中上一轮/上一篇。
  const cold = timeIt(() => R.renderMarkdownCached(text + '\n\n<!-- c' + Math.random() + ' -->'));
  const mutated = mutateMiddle(text);
  R.renderMarkdownCached(text);           // 建立缓存
  const warm = timeIt(() => R.renderMarkdownCached(mutated));
  totals.full += full; totals.cold += cold; totals.warm += warm; totals.raw += raw; totals.kb += kb;
  console.log(name.padEnd(28)
    + kb.toFixed(1).padStart(8) + full.toFixed(2).padStart(9)
    + cold.toFixed(2).padStart(9) + warm.toFixed(2).padStart(9) + raw.toFixed(2).padStart(9));
}
console.log('-'.repeat(70));
console.log('合计（%d KB）'.replace('%d', totals.kb.toFixed(0)).padEnd(28)
  + ''.padStart(8) + totals.full.toFixed(2).padStart(9) + totals.cold.toFixed(2).padStart(9)
  + totals.warm.toFixed(2).padStart(9) + totals.raw.toFixed(2).padStart(9));
