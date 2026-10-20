// MEditor 分享服务：文档发布 + 应用更新分发 + 官网静态站
//   POST /api/share           发布渲染后的 HTML（Bearer 免费档 token / $PRO_TOKENS 之一=Pro）→ 返回 {url}
//   GET  /d/:id               读取已发布文档（KV；免费档 30 天过期 → 410 友好页）
//   GET  /update/appcast.xml  Sparkle 更新 feed（KV）
//   GET  /update/pkg          最新安装包 zip（KV）
//   GET  /api/pro/verify      Pro key 校验（Bearer $PRO_TOKENS 之一 → {valid:true}；只回 true/false，不回显 token 列表）
//   POST /api/update/*        发布更新（需 Bearer $UPDATE_TOKEN，CI 打 tag 时调用）
//   其余路径                  → 官网静态资源（[assets] = ./website）
//
// 免费档规则（商业化验证，未接支付）：
//   - 每个发布 token 每月最多 FREE_MONTHLY_QUOTA 篇（KV 计数，key=quota:<token哈希>:<YYYY-MM>，次月 1 日 UTC 重置）
//   - per-user token：env.SHARE_TOKENS（逗号分隔）为每个用户各发一个 token，配额/限流按 token 独立，
//     单个用户用满不影响他人，撤销只需从 secret 移除该 token；env.SHARE_TOKEN 为旧版单一 token，仍兼容
//   - 免费文档 30 天过期；超限返回 429 {error, limit, resetsAt}
//   - 免费档阅读页底部注入 "Published with MEditor" 品牌页脚
// Pro token（env.PRO_TOKENS，逗号分隔的 wrangler secret）：不限量、不过期、无页脚
//
// 安全加固：
//   - 所有 token 比对走 timingSafeEqual（消除 `===` 的短路时序侧信道）
//   - POST 请求体不信任 Content-Length：有界流读取，超限即 413（见 readBoundedBody）
//   - 每 IP 每分钟 RATE_LIMIT_PER_MINUTE 次 POST（KV 计数，best-effort、非原子）

const MAX_HTML_BYTES = 4 * 1024 * 1024; // 4MB
const MAX_SHARE_BODY_BYTES = MAX_HTML_BYTES * 2; // JSON 包装后的 body 上限
const MAX_APPCAST_BYTES = 1024 * 1024; // appcast XML 远小于此，1MB 足够
const ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const ID_LENGTH = 10;

export const FREE_MONTHLY_QUOTA = 20;
export const FREE_DOC_TTL_DAYS = 30;
export const RATE_LIMIT_PER_MINUTE = 30;
export const RATE_LIMIT_WINDOW_SECONDS = 60;

function makeID() {
  const bytes = new Uint8Array(ID_LENGTH);
  crypto.getRandomValues(bytes);
  let id = "";
  for (const b of bytes) id += ID_ALPHABET[b % ID_ALPHABET.length];
  return id;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

// ── 常量时间比较 ──

// 逐字节 XOR 累积差异，长度差也混进结果——不因前缀匹配提前返回，
// 也不因长度不同提前退出。返回 true 表示两侧完全相等。
//
// 说明：crypto.subtle.digest 是异步的，用它会把 isProToken 变成 async 并波及调用方与
// 既有测试；这里按约定采用同步的「长度无关 XOR over UTF-8 bytes」实现，导出签名保持不变。
// JS 无法提供密码学意义上的严格常量时间，但足以消除 `===` 的短路时序泄漏。
export function timingSafeEqual(a, b) {
  const ab = new TextEncoder().encode(String(a ?? ""));
  const bb = new TextEncoder().encode(String(b ?? ""));
  let diff = ab.length ^ bb.length;
  const max = Math.max(ab.length, bb.length);
  for (let i = 0; i < max; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

// ── 有界请求体读取 ──

// 从请求流里最多读 maxBytes 字节。不信任 Content-Length：边读边计数，一旦超限立即
// 取消流并返回 ok:false（调用方回 413），绝不把无界请求体materialize 到内存。
// 返回 { ok, bytes, total }；request.body 为空时 ok:true、bytes 为空。
export async function readBoundedBody(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return { ok: true, bytes: new Uint8Array(0), total: 0 };
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        try {
          await reader.cancel();
        } catch {
          // 流已关闭/取消，忽略
        }
        return { ok: false, bytes: null, total };
      }
      chunks.push(value);
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // 取消后 releaseLock 可能抛错，忽略
    }
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { ok: true, bytes, total };
}

// ── 免费档 / Pro 判定（纯函数，node --test 直接覆盖） ──

// token 是否在 PRO_TOKENS（逗号分隔）里。只比对、不回显，不泄漏有效 token 列表。
// 用常量时间比较，逐条都完整比完（不用 some 短路），避免命中位置泄漏。
export function isProToken(token, proTokensEnv) {
  if (!token || !proTokensEnv) return false;
  let match = false;
  for (const raw of proTokensEnv.split(",")) {
    const candidate = raw.trim();
    if (candidate === "") continue;
    match = timingSafeEqual(candidate, token) || match;
  }
  return match;
}

// 免费档 token 判定：兼容旧的单一 SHARE_TOKEN 与新的 per-user SHARE_TOKENS（逗号分隔）。
// per-user 的意义：每个 token 的月度配额按自身哈希独立计量（见 quotaKey），
// 因此一个用户用满额度不会影响其他人，撤销某用户只需从 SHARE_TOKENS 移除该 token。
export function isFreeToken(token, shareToken, shareTokensEnv) {
  if (!token) return false;
  if (shareToken && timingSafeEqual(token, shareToken)) return true;
  if (!shareTokensEnv) return false;
  let match = false;
  for (const raw of shareTokensEnv.split(",")) {
    const candidate = raw.trim();
    if (candidate === "") continue;
    match = timingSafeEqual(candidate, token) || match;
  }
  return match;
}

// 免费档分享是否已启用。任一免费 token 配置存在即启用；全空则一律 503（宁可全关）。
// 保持与旧版一致：只有 PRO_TOKENS 而无免费 token 时，分享接口仍视为未启用。
export function shareEnabled(env) {
  return Boolean(env.SHARE_TOKEN || env.SHARE_TOKENS);
}

// 当月 key（UTC），如 "2026-08"。
export function monthKey(now) {
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

// 次月 1 日 00:00 UTC 的 ISO 串——免费档额度的重置时间点。
export function nextMonthStartISO(now) {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString();
}

// 免费档文档是否已过 30 天保留期（Pro 文档 metadata.tier === "pro"，永不过期）。
// 上线前发布的存量文档没有 tier 字段，视为 Pro——避免部署后旧链接立即 410。
export function isDocExpired(metadata, now) {
  if (!metadata || metadata.tier !== "free" || !metadata.createdAt) return false;
  const created = Date.parse(metadata.createdAt);
  if (Number.isNaN(created)) return false;
  return now.getTime() - created > FREE_DOC_TTL_DAYS * 24 * 60 * 60 * 1000;
}

// ── 品牌页脚 ──

export const FALLBACK_ORIGIN = "https://meditorapp.pages.dev";

// 从请求 URL 派生 origin，并校验只含 scheme://host[:port] 允许的字符；
// 不合法就回退到固定站点，避免把请求 URL 里的任意内容注入 HTML 属性。
export function safeOrigin(requestUrl) {
  try {
    const origin = new URL(requestUrl).origin;
    return /^https?:\/\/[A-Za-z0-9.\-:]+$/.test(origin) ? origin : FALLBACK_ORIGIN;
  } catch {
    return FALLBACK_ORIGIN;
  }
}

// 免费档阅读页底部注入一行小字品牌页脚（幂等：已注入过就不再重复加）。
export function injectFooter(html, origin) {
  if (html.includes("meditor-brand-footer")) return html;
  // 双保险：即使调用方传入未校验的 origin，这里也只接受受限字符集。
  const href = /^https?:\/\/[A-Za-z0-9.\-:]+$/.test(String(origin)) ? origin : FALLBACK_ORIGIN;
  const footer = `<div class="meditor-brand-footer" style="margin-top:48px;padding-top:16px;border-top:1px solid rgba(128,128,128,.25);font:12px -apple-system,system-ui,sans-serif;text-align:center;opacity:.55">Published with <a href="${href}" style="color:inherit">MEditor</a> · Free plan</div>`;
  const i = html.toLowerCase().lastIndexOf("</body>");
  return i === -1 ? html + footer : html.slice(0, i) + footer + html.slice(i);
}

// 计量 KV key——token 只存哈希，不落在明文的 KV key 里。
async function quotaKey(token, now) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `quota:${hex.slice(0, 24)}:${monthKey(now)}`;
}

// ── 每 IP 频率限制（best-effort）──
// KV 读-改-写非原子，并发下可能略微超发；目的是挡住明显的脚本刷接口，而非精确计费。

export function clientIP(request) {
  // CF-Connecting-IP 由 Cloudflare 边缘注入；客户端自带同名头会被覆盖，无法伪造。
  return request.headers.get("CF-Connecting-IP") || "";
}

export function rateLimitKey(ip, now) {
  return `rate:${ip}:${Math.floor(now.getTime() / (RATE_LIMIT_WINDOW_SECONDS * 1000))}`;
}

export function isRateLimited(count) {
  return Number(count) >= RATE_LIMIT_PER_MINUTE;
}

export function retryAfterSeconds(now) {
  const elapsed = Math.floor(now.getTime() / 1000) % RATE_LIMIT_WINDOW_SECONDS;
  return RATE_LIMIT_WINDOW_SECONDS - elapsed;
}

// 返回 429 Response 表示应拒绝；返回 null 表示放行。
// IP 缺失时（单测 / 本地直连）不做限制——生产环境 Cloudflare 一定带 CF-Connecting-IP。
export async function enforceRateLimit(request, env, now = new Date()) {
  const ip = clientIP(request);
  if (!ip || !env.SHARES) return null;
  const key = rateLimitKey(ip, now);
  const used = Number((await env.SHARES.get(key)) || 0);
  if (isRateLimited(used)) {
    return new Response(
      JSON.stringify({ error: "rate limit exceeded", limit: RATE_LIMIT_PER_MINUTE }),
      {
        status: 429,
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Retry-After": String(retryAfterSeconds(now)),
        },
      }
    );
  }
  // expirationTtl 让窗口 key 自动过期，无需清理
  await env.SHARES.put(key, String(used + 1), {
    expirationTtl: RATE_LIMIT_WINDOW_SECONDS * 2,
  });
  return null;
}

// ── Pro key 校验 ──
// 客户端（macOS ProEntitlementService）用此端点验证用户填入的 Pro key。
// 响应恒为 {valid: bool}——无论 token 对错都不回显 PRO_TOKENS 的任何内容，
// 也不区分「未配置 PRO_TOKENS」与「token 不在列表」（两者都回 valid:false，
// 避免通过差异探测服务端配置）。配合每 IP 限流挡暴力枚举。
function handleProVerify(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  return json({ valid: isProToken(token, env.PRO_TOKENS) });
}

function notFound() {
  const page = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>404 · MEditor</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#F4F5F2;color:#1B2434}
a{color:#C0392B;text-decoration:none}</style></head>
<body><div><h1>链接不存在或已删除</h1><p><a href="/">返回 MEditor 首页</a></p></div></body></html>`;
  return new Response(page, {
    status: 404,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

// 免费档文档过期的友好落地页（410 Gone——语义上比 404 准确，也便于客户端区分）
function expired() {
  const page = `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>410 · MEditor</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#F4F5F2;color:#1B2434}
a{color:#C0392B;text-decoration:none}.muted{color:#5D6673}</style></head>
<body><div><h1>链接已过期</h1><p class="muted">免费档发布的文档保留 ${FREE_DOC_TTL_DAYS} 天。<br>This link has expired — free-plan documents are kept for ${FREE_DOC_TTL_DAYS} days.</p>
<p><a href="/">返回 MEditor 首页</a></p></div></body></html>`;
  return new Response(page, {
    status: 410,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

async function handleShare(request, env) {
  // 未配置任何分享 token 时一律拒绝（宁可全关，不留裸奔接口）
  if (!shareEnabled(env)) return json({ error: "share not enabled" }, 503);
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  const pro = isProToken(token, env.PRO_TOKENS);
  // 免费档：旧单一 SHARE_TOKEN 或 per-user SHARE_TOKENS 之一。
  if (!pro && !isFreeToken(token, env.SHARE_TOKEN, env.SHARE_TOKENS)) {
    return json({ error: "unauthorized" }, 401);
  }

  // Content-Length 只用于快速拒绝，不作为唯一依据（见下方有界读取）
  const declared = Number(request.headers.get("Content-Length") || 0);
  if (declared > MAX_SHARE_BODY_BYTES) return json({ error: "too large" }, 413);

  const body = await readBoundedBody(request, MAX_SHARE_BODY_BYTES);
  if (!body.ok) return json({ error: "too large" }, 413);

  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(body.bytes));
  } catch {
    return json({ error: "invalid json" }, 400);
  }
  const title = String(payload?.title || "未命名").slice(0, 200);
  let html = String(payload?.html || "");
  if (!html) return json({ error: "empty html" }, 400);
  if (new TextEncoder().encode(html).length > MAX_HTML_BYTES) {
    return json({ error: "too large" }, 413);
  }

  const origin = safeOrigin(request.url);
  const now = new Date();

  // 免费档：按月配额（读-改-写，非原子；商业化验证阶段可接受的轻微超发）
  if (!pro) {
    const key = await quotaKey(token, now);
    const used = Number((await env.SHARES.get(key)) || 0);
    if (used >= FREE_MONTHLY_QUOTA) {
      return json(
        { error: "monthly quota exceeded", limit: FREE_MONTHLY_QUOTA, resetsAt: nextMonthStartISO(now) },
        429
      );
    }
    await env.SHARES.put(key, String(used + 1));
    html = injectFooter(html, origin);
  }

  const id = makeID();
  await env.SHARES.put(id, html, {
    metadata: { title, createdAt: now.toISOString(), tier: pro ? "pro" : "free" },
  });
  return json({ id, url: `${origin}/d/${id}` });
}

async function handleDoc(env, id) {
  if (!/^[A-Za-z0-9]{10}$/.test(id)) return notFound();
  const { value: html, metadata } = await env.SHARES.getWithMetadata(id);
  if (html === null) return notFound();
  if (isDocExpired(metadata, new Date())) return expired();
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300",
      "X-Content-Type-Options": "nosniff",
      // 发布内容是渲染后的静态 HTML：禁脚本/插件，图片只允许 data: 与 https:
      "Content-Security-Policy":
        "default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; font-src data:; script-src 'none'",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
    },
  });
}

// ── 应用更新（Sparkle appcast + 安装包，KV 存储，单槽只留最新版） ──
//   GET  /update/appcast.xml   Sparkle feed（CI 发版时覆写）
//   GET  /update/pkg           最新安装包 zip（appcast 里的 enclosure 指向这里）
//   POST /api/update/appcast   发布 appcast（Bearer UPDATE_TOKEN，body=XML 文本）
//   POST /api/update/pkg       发布安装包（Bearer UPDATE_TOKEN，body=zip 二进制）
// KV 单值上限 25MiB——当前 zip ~9MB，超了要换 R2。

const MAX_PKG_BYTES = 24 * 1024 * 1024;

function checkUpdateAuth(request, env) {
  const expected = env.UPDATE_TOKEN;
  if (!expected) return json({ error: "update not enabled" }, 503);
  const auth = request.headers.get("Authorization") || "";
  if (!timingSafeEqual(auth, `Bearer ${expected}`)) return json({ error: "unauthorized" }, 401);
  return null;
}

async function handleUpdatePublish(request, env, kind) {
  const denied = checkUpdateAuth(request, env);
  if (denied) return denied;

  const maxBytes = kind === "appcast" ? MAX_APPCAST_BYTES : MAX_PKG_BYTES;
  // Content-Length 只用于快速拒绝；硬上限靠有界流读取
  const declared = Number(request.headers.get("Content-Length") || 0);
  if (declared > maxBytes) return json({ error: "too large" }, 413);

  const body = await readBoundedBody(request, maxBytes);
  if (!body.ok) return json({ error: "too large" }, 413);

  if (kind === "appcast") {
    const xml = new TextDecoder().decode(body.bytes);
    if (!xml.includes("<rss") || !xml.includes("sparkle:version")) {
      return json({ error: "invalid appcast" }, 400);
    }
    await env.UPDATES.put("appcast.xml", xml);
    return json({ ok: true, bytes: body.total });
  }

  // pkg：有界缓冲（≤ MAX_PKG_BYTES）后写入 KV——正确性与硬上限优先于零拷贝
  if (body.total === 0) return json({ error: "empty body" }, 400);
  await env.UPDATES.put("pkg/latest.zip", body.bytes, {
    metadata: { publishedAt: new Date().toISOString() },
  });
  return json({ ok: true, bytes: body.total });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/share") {
      if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
      const limited = await enforceRateLimit(request, env);
      if (limited) return limited;
      return handleShare(request, env);
    }

    if (url.pathname === "/api/pro/verify") {
      if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
      const limited = await enforceRateLimit(request, env);
      if (limited) return limited;
      return handleProVerify(request, env);
    }

    if (url.pathname === "/api/update/appcast" || url.pathname === "/api/update/pkg") {
      if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
      const limited = await enforceRateLimit(request, env);
      if (limited) return limited;
      return handleUpdatePublish(request, env, url.pathname.endsWith("appcast") ? "appcast" : "pkg");
    }

    if (url.pathname === "/update/appcast.xml") {
      if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
      const xml = await env.UPDATES.get("appcast.xml");
      if (xml === null) return notFound();
      return new Response(xml, {
        headers: {
          "Content-Type": "application/xml; charset=utf-8",
          // Sparkle 每次检查都拉这个文件——别缓存，否则发版后客户端要延迟才能看到
          "Cache-Control": "no-cache",
        },
      });
    }

    if (url.pathname === "/update/pkg") {
      if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
      const pkg = await env.UPDATES.get("pkg/latest.zip", "stream");
      if (pkg === null) return notFound();
      return new Response(pkg, {
        headers: {
          "Content-Type": "application/zip",
          // 官网下载按钮也指向这里——给个像样的文件名（Sparkle 会忽略这个头）
          "Content-Disposition": 'attachment; filename="MEditor.zip"',
          "Cache-Control": "public, max-age=300",
        },
      });
    }

    if (url.pathname.startsWith("/d/")) {
      if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
      const id = url.pathname.slice(3);
      return handleDoc(env, id);
    }

    // 官网静态资源
    return env.ASSETS.fetch(request);
  },
};
