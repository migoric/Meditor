// worker/index.js 的单测：node --test（Node ≥ 20，全局 Request/Response/crypto 可用）。
// env 用内存版 KV mock，覆盖：免费档配额、30 天过期、品牌页脚、Pro 豁免、鉴权。

import test from "node:test";
import assert from "node:assert/strict";
import worker, {
  FREE_MONTHLY_QUOTA,
  RATE_LIMIT_PER_MINUTE,
  FALLBACK_ORIGIN,
  isProToken,
  isFreeToken,
  shareEnabled,
  isDocExpired,
  injectFooter,
  monthKey,
  nextMonthStartISO,
  timingSafeEqual,
  readBoundedBody,
  safeOrigin,
  rateLimitKey,
  isRateLimited,
  retryAfterSeconds,
  enforceRateLimit,
} from "./index.js";

const SHARE_TOKEN = "free-token";
const PRO_TOKENS = "pro-alpha, pro-beta";

// ── 内存 KV mock（只实现 worker 用到的 get/put/getWithMetadata） ──
class MockKV {
  constructor() {
    this.map = new Map(); // key -> {value, metadata}
  }
  async get(key) {
    return this.map.get(key)?.value ?? null;
  }
  async put(key, value, opts = {}) {
    this.map.set(key, { value, metadata: opts.metadata ?? null });
  }
  async getWithMetadata(key) {
    const entry = this.map.get(key);
    return entry
      ? { value: entry.value, metadata: entry.metadata }
      : { value: null, metadata: null };
  }
}

function makeEnv() {
  return {
    SHARES: new MockKV(),
    UPDATES: new MockKV(),
    ASSETS: { fetch: async () => new Response("site") },
    SHARE_TOKEN,
    PRO_TOKENS,
  };
}

function publishRequest(token, html = "<!DOCTYPE html><html><body><h1>hi</h1></body></html>") {
  return new Request("https://share.example.com/api/share", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ title: "t", html }),
  });
}

// ── 纯函数 ──

test("isProToken: 命中/未命中/空值", () => {
  assert.equal(isProToken("pro-alpha", PRO_TOKENS), true);
  assert.equal(isProToken("pro-beta", PRO_TOKENS), true); // 逗号后空格 trim
  assert.equal(isProToken("free-token", PRO_TOKENS), false);
  assert.equal(isProToken("", PRO_TOKENS), false);
  assert.equal(isProToken("pro-alpha", undefined), false);
  assert.equal(isProToken("pro-alpha", ""), false);
  assert.equal(isProToken("pro-alpha", ",,,"), false); // 空条目不算命中
});

test("timingSafeEqual: 相等/不等/长度不同/空值与归一化", () => {
  assert.equal(timingSafeEqual("abc", "abc"), true);
  assert.equal(timingSafeEqual("abc", "abd"), false);
  assert.equal(timingSafeEqual("abc", "abcd"), false); // 长度不同不相等
  assert.equal(timingSafeEqual("abcd", "abc"), false);
  assert.equal(timingSafeEqual("", ""), true);
  assert.equal(timingSafeEqual("", "x"), false);
  assert.equal(timingSafeEqual("secret", ""), false);
  assert.equal(timingSafeEqual(undefined, undefined), true); // String() 归一化
});

test("safeOrigin: 合法 origin 透传，非法/坏 URL 回退固定站点", () => {
  assert.equal(safeOrigin("https://share.example.com/api/share"), "https://share.example.com");
  assert.equal(safeOrigin("http://localhost:8787/api/share"), "http://localhost:8787");
  assert.equal(safeOrigin("not a url"), FALLBACK_ORIGIN);
  assert.equal(safeOrigin("ftp://example.com/x"), FALLBACK_ORIGIN);
});

test("readBoundedBody: 上限内完整读取、超限即中止（不信任 Content-Length）", async () => {
  const ok = await readBoundedBody(
    new Request("https://x/", { method: "POST", body: "0123456789" }),
    100
  );
  assert.equal(ok.ok, true);
  assert.equal(ok.total, 10);
  assert.equal(new TextDecoder().decode(ok.bytes), "0123456789");

  const over = await readBoundedBody(
    new Request("https://x/", { method: "POST", body: "0123456789" }),
    5
  );
  assert.equal(over.ok, false);
  assert.equal(over.bytes, null);

  const empty = await readBoundedBody(new Request("https://x/", { method: "POST" }), 5);
  assert.equal(empty.ok, true);
  assert.equal(empty.total, 0);
});

test("rateLimitKey/isRateLimited/retryAfterSeconds: 同窗口稳定、跨窗口/跨 IP 不同、阈值正确", () => {
  const t0 = new Date("2026-08-24T00:00:10Z");
  const t1 = new Date("2026-08-24T00:00:50Z");
  const t2 = new Date("2026-08-24T00:01:05Z");
  assert.equal(rateLimitKey("1.2.3.4", t0), rateLimitKey("1.2.3.4", t1)); // 同一分钟窗口
  assert.notEqual(rateLimitKey("1.2.3.4", t0), rateLimitKey("1.2.3.4", t2)); // 跨窗口
  assert.notEqual(rateLimitKey("1.2.3.4", t0), rateLimitKey("5.6.7.8", t0)); // 不同 IP
  assert.equal(isRateLimited(0), false);
  assert.equal(isRateLimited(RATE_LIMIT_PER_MINUTE - 1), false);
  assert.equal(isRateLimited(RATE_LIMIT_PER_MINUTE), true);
  assert.equal(isRateLimited(RATE_LIMIT_PER_MINUTE + 5), true);
  const wait = retryAfterSeconds(t0);
  assert.ok(wait >= 1 && wait <= 60);
});

test("enforceRateLimit: 前 30 次放行、第 31 次 429+Retry-After；无 IP 时跳过", async () => {
  const env = makeEnv();
  const now = new Date("2026-08-24T00:00:00Z");
  const req = new Request("https://share.example.com/api/share", {
    method: "POST",
    headers: { Authorization: `Bearer ${SHARE_TOKEN}`, "CF-Connecting-IP": "203.0.113.7" },
  });
  for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i++) {
    assert.equal(await enforceRateLimit(req, env, now), null, `第 ${i + 1} 次应放行`);
  }
  const limited = await enforceRateLimit(req, env, now);
  assert.equal(limited.status, 429);
  assert.ok(limited.headers.get("Retry-After"));
  assert.equal((await limited.json()).limit, RATE_LIMIT_PER_MINUTE);

  // IP 缺失（本地/单测）时不做限制，避免误伤
  const noIP = new Request("https://share.example.com/api/share", { method: "POST" });
  assert.equal(await enforceRateLimit(noIP, env, now), null);
});

test("monthKey / nextMonthStartISO: 月份格式与跨年重置", () => {
  assert.equal(monthKey(new Date("2026-08-15T10:00:00Z")), "2026-08");
  assert.equal(nextMonthStartISO(new Date("2026-08-15T10:00:00Z")), "2026-09-01T00:00:00.000Z");
  assert.equal(nextMonthStartISO(new Date("2026-12-31T23:00:00Z")), "2027-01-01T00:00:00.000Z");
});

test("isDocExpired: 免费 30 天过期，Pro/存量无 tier/坏数据不过期", () => {
  const now = new Date("2026-08-24T00:00:00Z");
  const old = { createdAt: "2026-07-20T00:00:00Z", tier: "free" }; // 35 天前
  const fresh = { createdAt: "2026-08-20T00:00:00Z", tier: "free" };
  assert.equal(isDocExpired(old, now), true);
  assert.equal(isDocExpired(fresh, now), false);
  assert.equal(isDocExpired({ ...old, tier: "pro" }, now), false);
  // 上线前的存量文档没有 tier 字段，视为 Pro——部署后旧链接不应立即 410
  assert.equal(isDocExpired({ createdAt: "2026-01-01T00:00:00Z" }, now), false);
  assert.equal(isDocExpired(null, now), false);
  assert.equal(isDocExpired({}, now), false);
  assert.equal(isDocExpired({ createdAt: "not-a-date" }, now), false);
});

test("injectFooter: 插入 </body> 前、幂等、无 body 时追加", () => {
  const html = "<html><body><p>x</p></body></html>";
  const out = injectFooter(html, "https://share.example.com");
  assert.ok(out.includes("meditor-brand-footer"));
  assert.ok(out.indexOf("meditor-brand-footer") < out.indexOf("</body>"));
  assert.equal(injectFooter(out, "https://share.example.com"), out); // 幂等
  assert.ok(injectFooter("<p>no body</p>", "o").endsWith("</div>"));
});

// ── 发布流程 ──

test("免费档发布成功：返回 url、注入品牌页脚、metadata 标记 free", async () => {
  const env = makeEnv();
  const res = await worker.fetch(publishRequest(SHARE_TOKEN), env);
  assert.equal(res.status, 200);
  const { id, url } = await res.json();
  assert.equal(url, `https://share.example.com/d/${id}`);
  const { value, metadata } = await env.SHARES.getWithMetadata(id);
  assert.ok(value.includes("meditor-brand-footer"));
  assert.equal(metadata.tier, "free");
});

test("Pro token 发布：不计量、无页脚、metadata 标记 pro", async () => {
  const env = makeEnv();
  const res = await worker.fetch(publishRequest("pro-alpha"), env);
  assert.equal(res.status, 200);
  const { id } = await res.json();
  const { value, metadata } = await env.SHARES.getWithMetadata(id);
  assert.ok(!value.includes("meditor-brand-footer"));
  assert.equal(metadata.tier, "pro");
});

test("免费档配额：前 20 篇成功，第 21 篇 429 + {error, limit, resetsAt}", async () => {
  const env = makeEnv();
  for (let i = 0; i < FREE_MONTHLY_QUOTA; i++) {
    const res = await worker.fetch(publishRequest(SHARE_TOKEN), env);
    assert.equal(res.status, 200, `第 ${i + 1} 篇应成功`);
  }
  const res = await worker.fetch(publishRequest(SHARE_TOKEN), env);
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.limit, FREE_MONTHLY_QUOTA);
  assert.ok(body.error);
  assert.ok(/^\d{4}-\d{2}-01T00:00:00\.000Z$/.test(body.resetsAt));
});

test("Pro token 不受配额限制", async () => {
  const env = makeEnv();
  for (let i = 0; i < FREE_MONTHLY_QUOTA + 5; i++) {
    const res = await worker.fetch(publishRequest("pro-beta"), env);
    assert.equal(res.status, 200, `Pro 第 ${i + 1} 篇应成功`);
  }
});

test("计量不泄漏 token：quota key 是哈希，不含明文 token", async () => {
  const env = makeEnv();
  await worker.fetch(publishRequest(SHARE_TOKEN), env);
  const keys = [...env.SHARES.map.keys()];
  const quotaKeys = keys.filter((k) => k.startsWith("quota:"));
  assert.equal(quotaKeys.length, 1);
  assert.ok(!quotaKeys[0].includes(SHARE_TOKEN));
});

test("鉴权：错误 token 401；未配置 SHARE_TOKEN 时 503", async () => {
  const env = makeEnv();
  assert.equal((await worker.fetch(publishRequest("wrong"), env)).status, 401);
  const env2 = makeEnv();
  delete env2.SHARE_TOKEN;
  delete env2.SHARE_TOKENS;
  assert.equal((await worker.fetch(publishRequest("pro-alpha"), env2)).status, 503);
});

// ── per-user token ──

test("isFreeToken / shareEnabled：兼容单一 SHARE_TOKEN 与 per-user SHARE_TOKENS", () => {
  assert.equal(isFreeToken("free-token", "free-token", undefined), true);
  assert.equal(isFreeToken("u1", undefined, "u1,u2"), true);
  assert.equal(isFreeToken("u3", undefined, "u1,u2"), false);
  assert.equal(isFreeToken("", undefined, "u1"), false);
  assert.equal(isFreeToken("u1", "free-token", undefined), false);

  assert.equal(shareEnabled({ SHARE_TOKEN: "x" }), true);
  assert.equal(shareEnabled({ SHARE_TOKENS: "a,b" }), true);
  assert.equal(shareEnabled({ PRO_TOKENS: "p" }), false);
  assert.equal(shareEnabled({}), false);
});

test("per-user token：各自独立配额，一个用满不影响另一个", async () => {
  const env = makeEnv();
  env.SHARE_TOKENS = "user-1,user-2";

  for (let i = 0; i < FREE_MONTHLY_QUOTA; i++) {
    const res = await worker.fetch(publishRequest("user-1"), env);
    assert.equal(res.status, 200, `user-1 第 ${i + 1} 篇应成功`);
  }
  const limited = await worker.fetch(publishRequest("user-1"), env);
  assert.equal(limited.status, 429, "user-1 超出个人配额应 429");

  const other = await worker.fetch(publishRequest("user-2"), env);
  assert.equal(other.status, 200, "user-2 有自己的配额，不应被 user-1 影响");
});

// ── 阅读页 ──

test("免费文档 30 天后访问 → 410 友好页；未过期正常返回", async () => {
  const env = makeEnv();
  const res = await worker.fetch(publishRequest(SHARE_TOKEN), env);
  const { id } = await res.json();

  const okRes = await worker.fetch(new Request(`https://share.example.com/d/${id}`), env);
  assert.equal(okRes.status, 200);

  // 把 createdAt 改成 31 天前，模拟过期
  const entry = env.SHARES.map.get(id);
  entry.metadata = {
    ...entry.metadata,
    createdAt: new Date(Date.now() - 31 * 24 * 3600 * 1000).toISOString(),
  };
  const goneRes = await worker.fetch(new Request(`https://share.example.com/d/${id}`), env);
  assert.equal(goneRes.status, 410);
  assert.ok((await goneRes.text()).includes("链接已过期"));
});

test("Pro 文档 31 天后仍可访问（不过期）", async () => {
  const env = makeEnv();
  const res = await worker.fetch(publishRequest("pro-alpha"), env);
  const { id } = await res.json();
  const entry = env.SHARES.map.get(id);
  entry.metadata = {
    ...entry.metadata,
    createdAt: new Date(Date.now() - 31 * 24 * 3600 * 1000).toISOString(),
  };
  const docRes = await worker.fetch(new Request(`https://share.example.com/d/${id}`), env);
  assert.equal(docRes.status, 200);
});

test("GET /d/:id 带防御性响应头：CSP / nosniff / X-Frame-Options / Referrer-Policy", async () => {
  const env = makeEnv();
  const res = await worker.fetch(publishRequest(SHARE_TOKEN), env);
  const { id } = await res.json();
  const docRes = await worker.fetch(new Request(`https://share.example.com/d/${id}`), env);
  assert.equal(docRes.status, 200);
  const csp = docRes.headers.get("Content-Security-Policy") || "";
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /script-src 'none'/);
  assert.equal(docRes.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(docRes.headers.get("X-Frame-Options"), "DENY");
  assert.equal(docRes.headers.get("Referrer-Policy"), "no-referrer");
});

test("worker.fetch: 同一 IP 超过 30 次/分钟 → 429 + Retry-After", async () => {
  const env = makeEnv();
  const publish = () =>
    new Request("https://share.example.com/api/share", {
      method: "POST",
      headers: {
        Authorization: "Bearer pro-alpha",
        "Content-Type": "application/json",
        "CF-Connecting-IP": "198.51.100.9",
      },
      body: JSON.stringify({ title: "t", html: "<html><body>x</body></html>" }),
    });
  for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i++) {
    assert.equal((await worker.fetch(publish(), env)).status, 200, `第 ${i + 1} 次应成功`);
  }
  const res = await worker.fetch(publish(), env);
  assert.equal(res.status, 429);
  assert.ok(res.headers.get("Retry-After"));
});

// ── Pro key 校验端点 ──

test("GET /api/pro/verify: Pro token → valid:true，免费/错误 token → valid:false", async () => {
  const env = makeEnv();
  const verify = (token) =>
    worker.fetch(
      new Request("https://share.example.com/api/pro/verify", {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      }),
      env
    );

  assert.deepEqual(await (await verify("pro-alpha")).json(), { valid: true });
  assert.deepEqual(await (await verify("pro-beta")).json(), { valid: true });
  assert.deepEqual(await (await verify("free-token")).json(), { valid: false });
  assert.deepEqual(await (await verify("wrong")).json(), { valid: false });
  assert.deepEqual(await (await verify(null)).json(), { valid: false });
});

test("GET /api/pro/verify: 未配置 PRO_TOKENS 也回 200 {valid:false}（不暴露配置差异）", async () => {
  const env = makeEnv();
  delete env.PRO_TOKENS;
  const res = await worker.fetch(
    new Request("https://share.example.com/api/pro/verify", {
      headers: { Authorization: "Bearer pro-alpha" },
    }),
    env
  );
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { valid: false });
});

test("GET /api/pro/verify: 响应不回显任何 PRO_TOKENS 内容；POST 一律 405", async () => {
  const env = makeEnv();
  const res = await worker.fetch(
    new Request("https://share.example.com/api/pro/verify", {
      headers: { Authorization: "Bearer pro-alpha" },
    }),
    env
  );
  const text = await res.text();
  assert.ok(!text.includes("pro-alpha"));
  assert.ok(!text.includes("pro-beta"));

  const post = await worker.fetch(
    new Request("https://share.example.com/api/pro/verify", { method: "POST" }),
    env
  );
  assert.equal(post.status, 405);
});

test("GET /api/pro/verify: 走每 IP 限流，挡暴力枚举 token", async () => {
  const env = makeEnv();
  const verify = () =>
    worker.fetch(
      new Request("https://share.example.com/api/pro/verify", {
        headers: { "CF-Connecting-IP": "192.0.2.55" },
      }),
      env
    );
  for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i++) {
    assert.equal((await verify()).status, 200, `第 ${i + 1} 次应放行`);
  }
  assert.equal((await verify()).status, 429);
});
