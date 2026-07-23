#!/usr/bin/env node
// ZTransfer 激活服务器 —— 零依赖单文件(Node >= 22.13,需要 node:sqlite)。
// 用法: node license-server.js [config.json 路径]
// 接口与表结构见 docs/激活与付费设计.md。
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

// ---------------------------------------------------------------- 配置

const CONFIG_PATH = process.argv[2] || path.join(__dirname, 'config.json');
const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
for (const k of ['port', 'dbPath', 'tlsCertPath', 'tlsKeyPath', 'signingKeyPath', 'adminToken']) {
    if (!cfg[k]) { console.error(`config.json 缺少字段: ${k}`); process.exit(1); }
}

// 虎皮椒(自动售码)。四项都填才启用;不填服务器照常跑,下单接口返回 PAY_DISABLED。
// xhAppId/xhAppSecret 来自虎皮椒后台;priceFen 为售价(单位:分,接口侧转元);
// payNotifyUrl 为本服务器对外的回调地址,如 https://<公网IP>:8443/pay/notify。
const PAY_ENABLED = Boolean(cfg.xhAppId && cfg.xhAppSecret && cfg.priceFen && cfg.payNotifyUrl);
if (!PAY_ENABLED && (cfg.xhAppId || cfg.xhAppSecret || cfg.priceFen || cfg.payNotifyUrl)) {
    console.error('虎皮椒配置不完整:xhAppId / xhAppSecret / priceFen / payNotifyUrl 需同时提供');
    process.exit(1);
}
if (PAY_ENABLED) {
    cfg.priceFen = Number(cfg.priceFen);
    if (!Number.isInteger(cfg.priceFen) || cfg.priceFen <= 0) {
        console.error('priceFen 必须为正整数(单位:分)');
        process.exit(1);
    }
}
if (String(cfg.adminToken).length < 32) {
    console.error('adminToken 太短(需 >= 32 字符),用 setup-keys.js 生成');
    process.exit(1);
}

const signingKey = crypto.createPrivateKey(fs.readFileSync(cfg.signingKeyPath, 'utf8'));

// ---------------------------------------------------------------- 定价
// 价格单独放 pricing.json(与 config.json 同目录),不塞进 config.json:
// 改价就不必碰那个装着密钥的文件,也不用重启服务——每次现读,和 app-latest.json 同一套路。
// 文件不存在则年费回落到 config.json 的 priceFen(不划线)，永久版使用用户确认的新品默认价。
// ★ 展示价可以过时(App 缓存的),但下单一律现读这里,收的钱永远以服务端为准。
const PRICING_PATH = path.join(path.dirname(CONFIG_PATH), 'pricing.json');
const SUB_PERIOD_DAYS = 365;
const PRODUCT_ANNUAL = 'annual';
const PRODUCT_LIFETIME = 'lifetime';
const PRODUCTS = new Set([PRODUCT_ANNUAL, PRODUCT_LIFETIME]);
// 用户确认的新品默认价；年费仍完全沿用现有 config/pricing，不在代码中改价。
// 一旦 pricing v2 明确配置 lifetime，始终以文件中的价格为准。
const DEFAULT_LIFETIME_PRICE_FEN = 5990;
const DEFAULT_LIFETIME_ORIGINAL_FEN = 9990;
// 防止超大 JSON 整数在转元、上游签名或 SQLite 中失真；上限 ¥100,000，远高于会员商品合理区间。
const MAX_PRICE_FEN = 10_000_000;

// 解析成功过的最后一份价。文件被改坏/写了一半时兜住它——没有这层就会静默回落到
// config.json 里那个可能早就不用了的老价,按另一个价真收钱,还不留任何痕迹。
let lastGoodPricing = null;
let pricingBroken = false;   // 只在状态翻转时吼一次日志,别每个请求刷一屏

function validPrice(value) {
    return Number.isSafeInteger(value) && value > 0 && value <= MAX_PRICE_FEN;
}

function validOriginal(value, priceFen) {
    return Number.isSafeInteger(value) && value >= 0 && value <= MAX_PRICE_FEN
        && (value === 0 || value > priceFen);
}

function normalizeProductPrice(value, required, label) {
    if (value === undefined || value === null) {
        if (required) throw new Error(`${label} 未配置`);
        return { available: false, priceFen: 0, originalFen: 0 };
    }
    if (typeof value !== 'object' || Array.isArray(value) || !validPrice(value.priceFen)) {
        throw new Error(`${label}.priceFen 不是正整数`);
    }
    const originalFen = value.originalFen === undefined ? 0 : value.originalFen;
    if (!validOriginal(originalFen, value.priceFen)) {
        throw new Error(`${label}.originalFen 必须为 0 或高于实收价的整数`);
    }
    return { available: true, priceFen: value.priceFen, originalFen };
}

function fallbackPricing() {
    return {
        annual: { available: true, priceFen: cfg.priceFen, originalFen: 0 },
        lifetime: {
            available: true,
            priceFen: DEFAULT_LIFETIME_PRICE_FEN,
            originalFen: DEFAULT_LIFETIME_ORIGINAL_FEN,
        },
    };
}

function normalizePricingFile(j) {
    if (!j || typeof j !== 'object' || Array.isArray(j)) throw new Error('定价文件不是对象');
    // 老 pricing.json 只配置年费，继续无缝读取；永久版补入已确认的新品默认价。
    if (Object.prototype.hasOwnProperty.call(j, 'priceFen')) {
        if (!validPrice(j.priceFen)) throw new Error('priceFen 不是有效正整数');
        // 保留旧读取语义：legacy 文件的划线价填错只是不展示，不能让真实售价回退到 config。
        const originalFen = Number.isSafeInteger(j.originalFen) && j.originalFen > j.priceFen
            && j.originalFen <= MAX_PRICE_FEN ? j.originalFen : 0;
        return {
            annual: { available: true, priceFen: j.priceFen, originalFen },
            lifetime: {
                available: true,
                priceFen: DEFAULT_LIFETIME_PRICE_FEN,
                originalFen: DEFAULT_LIFETIME_ORIGINAL_FEN,
            },
        };
    }
    if (j.version !== 2) throw new Error('未知定价格式版本');
    return {
        annual: normalizeProductPrice(j.annual, true, PRODUCT_ANNUAL),
        lifetime: normalizeProductPrice(j.lifetime ?? {
            priceFen: DEFAULT_LIFETIME_PRICE_FEN,
            originalFen: DEFAULT_LIFETIME_ORIGINAL_FEN,
        }, true, PRODUCT_LIFETIME),
    };
}

/** 当前定价:{ annual, lifetime }；永久版有已确认的默认价，v2 可显式覆盖。 */
function pricing() {
    let raw;
    try {
        raw = fs.readFileSync(PRICING_PATH, 'utf8');
    } catch {
        // 没有 pricing.json 是正常状态(还没设过价):用内存里上次成功的,否则 config.json 的价
        return lastGoodPricing || fallbackPricing();
    }
    try {
        lastGoodPricing = normalizePricingFile(JSON.parse(raw));
        pricingBroken = false;
        return lastGoodPricing;
    } catch (e) {
        if (!pricingBroken) {
            pricingBroken = true;
            log(`PRICING_BAD ${PRICING_PATH}: ${e.message} —— 回落到`
                + (lastGoodPricing ? `上次成功的年费价 ¥${lastGoodPricing.annual.priceFen / 100}` : `config.json 的 ¥${cfg.priceFen / 100}`));
        }
        return lastGoodPricing || fallbackPricing();
    }
}

function apiPricing() {
    const p = pricing();
    const productJson = (item, periodDays) => item.available
        ? {
            available: true,
            price_fen: item.priceFen,
            original_fen: item.originalFen,
            ...(periodDays === undefined ? {} : { period_days: periodDays }),
        }
        : { available: false };
    return {
        ok: true,
        // 顶层字段是老 App 的兼容契约，始终表示年费商品。
        price_fen: p.annual.priceFen,
        original_fen: p.annual.originalFen,
        period_days: SUB_PERIOD_DAYS,
        products: {
            annual: productJson(p.annual, SUB_PERIOD_DAYS),
            lifetime: productJson(p.lifetime),
        },
    };
}

function adminSetPricing(body) {
    const hasProduct = Object.prototype.hasOwnProperty.call(body, 'product');
    const product = hasProduct ? body.product : PRODUCT_ANNUAL;
    if (!PRODUCTS.has(product)) return { ok: false, err: 'BAD_PRODUCT' };
    const priceFen = body.price_fen;
    if (!validPrice(priceFen)) return { ok: false, err: 'BAD_PRICE' };
    const originalFen = body.original_fen === undefined ? 0 : body.original_fen;
    // 划线价低于实收价就成了"原价更便宜"的反向促销,一定是填反了
    if (!Number.isSafeInteger(originalFen) || originalFen < 0 || originalFen > MAX_PRICE_FEN) {
        return { ok: false, err: 'BAD_ORIGINAL' };
    }
    if (originalFen !== 0 && originalFen <= priceFen) return { ok: false, err: 'ORIGINAL_TOO_LOW' };
    const current = pricing();
    const next = {
        version: 2,
        annual: {
            priceFen: current.annual.priceFen,
            originalFen: current.annual.originalFen,
        },
        ...(current.lifetime.available ? {
            lifetime: {
                priceFen: current.lifetime.priceFen,
                originalFen: current.lifetime.originalFen,
            },
        } : {}),
    };
    next[product] = { priceFen, originalFen };
    // 先写临时文件再 rename:rename 在同一文件系统上是原子的,写盘中途断电/被杀
    // 也不会留下半截 JSON 让 pricing() 读到坏值。
    const tmp = PRICING_PATH + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(next, null, 2));
    fs.renameSync(tmp, PRICING_PATH);
    lastGoodPricing = normalizePricingFile(next);
    pricingBroken = false;
    log(`SET_PRICING product=${product} ¥${priceFen / 100}${originalFen ? ` 原价 ¥${originalFen / 100}` : ''}`);
    return apiPricing();
}

// ---------------------------------------------------------------- 数据库

const db = new DatabaseSync(cfg.dbPath);
db.exec(`
CREATE TABLE IF NOT EXISTS codes (
  code          TEXT PRIMARY KEY,
  status        TEXT NOT NULL DEFAULT 'active',
  note          TEXT,
  created_at    TEXT NOT NULL,
  expires_at    TEXT,                             -- NULL = 永久授权;否则订阅到期时刻
  revoked_at    TEXT,
  revoke_reason TEXT
);
CREATE TABLE IF NOT EXISTS bindings (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  code          TEXT NOT NULL REFERENCES codes(code),
  device_fp     TEXT NOT NULL,
  device_model  TEXT,
  app_ver       TEXT,
  activated_at  TEXT NOT NULL,
  last_renew_at TEXT,
  UNIQUE (code, device_fp)
);
CREATE INDEX IF NOT EXISTS idx_bindings_code ON bindings(code);
CREATE TABLE IF NOT EXISTS activations (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  code         TEXT NOT NULL,
  device_fp    TEXT NOT NULL,
  device_model TEXT,
  app_ver      TEXT,
  at           TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_act_code_at ON activations(code, at);
CREATE TABLE IF NOT EXISTS orders (
  out_trade_no TEXT PRIMARY KEY,
  device_fp    TEXT NOT NULL,
  amount_fen   INTEGER NOT NULL,
  product      TEXT NOT NULL DEFAULT 'annual',
  grant_days   INTEGER NOT NULL DEFAULT 365,
  status       TEXT NOT NULL DEFAULT 'pending',  -- pending / paid
  code         TEXT,
  renew_code   TEXT,                             -- NULL = 新购单;否则本单是给该码续费
  charge_id    TEXT,
  pay_url      TEXT,
  pay_qr       TEXT,
  created_at   TEXT NOT NULL,
  paid_at      TEXT
);
CREATE INDEX IF NOT EXISTS idx_orders_fp ON orders(device_fp);
CREATE TABLE IF NOT EXISTS update_stats (
  source_version_code   INTEGER NOT NULL,
  source_version_name   TEXT NOT NULL DEFAULT '',
  target_version_code   INTEGER NOT NULL,
  target_version_name   TEXT NOT NULL DEFAULT '',
  check_count           INTEGER NOT NULL DEFAULT 0,
  install_trigger_count INTEGER NOT NULL DEFAULT 0,
  last_check_at         TEXT,
  last_install_at       TEXT,
  PRIMARY KEY (source_version_code, target_version_code)
);
`);
// 迁移:老库缺列时补上(已存在则抛错,忽略即可)
try { db.exec('ALTER TABLE orders ADD COLUMN pay_qr TEXT'); } catch { /* 列已存在 */ }
try { db.exec('ALTER TABLE activations ADD COLUMN device_model TEXT'); } catch { /* 列已存在 */ }
try { db.exec('ALTER TABLE activations ADD COLUMN app_ver TEXT'); } catch { /* 列已存在 */ }
// 迁移:去掉 max_devices —— 授权模型早已改成"单设备浮动"(见 apiActivate 的顶替逻辑),
// 这列从来没有任何代码读过,却让台账显示"设备 1/2",看着像一码能两机。删掉免得再误导。
try { db.exec('ALTER TABLE codes DROP COLUMN max_devices'); } catch { /* 已删除 */ }
// 迁移:买断制 → 年费订阅
try { db.exec('ALTER TABLE codes ADD COLUMN expires_at TEXT'); } catch { /* 列已存在 */ }
try { db.exec('ALTER TABLE orders ADD COLUMN renew_code TEXT'); } catch { /* 列已存在 */ }
// 迁移:老订单一律是年费 365 天；新订单把商品与权益一并快照，改价/改周期不追溯历史订单。
try { db.exec("ALTER TABLE orders ADD COLUMN product TEXT NOT NULL DEFAULT 'annual'"); } catch { /* 列已存在 */ }
try { db.exec('ALTER TABLE orders ADD COLUMN grant_days INTEGER NOT NULL DEFAULT 365'); } catch { /* 列已存在 */ }

// ---------------------------------------------------------------- 工具

const now = () => new Date().toISOString();
const log = (...a) => console.log(now(), ...a);

// 激活码:6 位纯大写字母,去掉易混淆的 I O(手抄/口述不易错)。
// 空间 24^6 ≈ 1.9 亿,配合 /v1/activate 的 IP 限速足够挡枚举(手动发码的小众场景)。
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
function newCode() {
    return Array.from({ length: 6 },
        () => CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)]).join('');
}

// 通行证离线硬有效期:签发后 N 天内本地有效,到期必须联网续签,否则 App 降级。
// 与 App 端"每天续签"配合:有网设备每天滚动刷新有效期,离线最多用 N 天;
// 被顶替/吊销的设备下次续签即降级。反滥用的快速主力是查重(见下 CHURN_*),exp 只是离线兜底。
// ★ 改天数只动这一个常量。
const HARD_GRACE_SEC = 7 * 24 * 3600;   // 7 天

// 码是否仍可用:未吊销,且(永久 或 未到期)。expires_at 为 NULL 表示永久授权(手动发的码)。
// ISO 8601 UTC 的字典序即时序,直接字符串比较即可。
const codeLive = (row) => Boolean(row) && row.status === 'active' && (!row.expires_at || row.expires_at > now());

// 通行证:base64url(payload JSON) + "." + base64url(ECDSA P-256 DER 签名)
// expiresAt 为空即永久授权:payload 不带 sub,App 据此显示"永久"。
function issueToken(code, fp, expiresAt) {
    const iat = Math.floor(Date.now() / 1000);
    const sub = expiresAt ? Math.floor(Date.parse(expiresAt) / 1000) : 0;
    // 离线硬有效期不得越过订阅到期,否则订阅结束后还能离线白用最多 HARD_GRACE_SEC。
    const exp = sub ? Math.min(iat + HARD_GRACE_SEC, sub) : iat + HARD_GRACE_SEC;
    const payload = Buffer.from(JSON.stringify({
        v: 1, code, fp, plan: 'pro', iat, exp, ...(sub ? { sub } : {}),
    }));
    const sig = crypto.sign('sha256', payload, signingKey); // EC 密钥默认输出 DER,Android SHA256withECDSA 可直接验
    return `${payload.toString('base64url')}.${sig.toString('base64url')}`;
}

const FP_RE = /^[0-9a-f]{32}$/;
const CODE_RE = /^[A-HJ-NP-Z]{6}$/;   // 6 位大写字母,排除 I O
const normCode = (s) => String(s || '').trim().toUpperCase();
// 展示码 ZT-XXXX-XXXX 是指纹前 8 个 hex 的人读形式;解绑时两种都接受
const normFpPrefix = (s) => String(s || '').trim().toLowerCase().replace(/^zt-/, '').replace(/-/g, '');

function constantTimeEq(a, b) {
    const ba = Buffer.from(String(a)), bb = Buffer.from(String(b));
    return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

// ---------------------------------------------------------------- 限速
// 每 IP 固定窗口计数,【每条路由都要过】,按代价给不同额度。
//
// 用计数器而不是时间戳数组:数组版每次请求都得 filter 一遍整个数组,请求越猛数组越长、
// 每次越慢——攻击者反倒能用洪水把 CPU 拖死,等于自己给自己造了个放大器。计数是 O(1)。
//
// 说清楚这拦得住什么:它拦的是"一个人往死里打某个接口"(爆破码、刷发码、把 DB/CPU 打满)。
// 真正的 DDoS(带宽/TLS 握手洪水)在进程里挡不住,那是阿里云基础防护和安全组的事。
const RATE_WINDOW_MS = 60_000;

// 每分钟额度,按【类别】分别计数。数字是按"这条路有多贵 × 真实用量有多大"定的:
//
//   write 发码/绑定/收钱,最贵也最该防爆破;正常人一次购买流程也就点几下
//   renew 每次要签一张通行证(有 CPU 成本);正常一天才跑一次,30 已经极松
//   poll  付款页每 2 秒查一次单 = 30/分钟。给到 4 倍余量:多个用户挤在同一个
//         运营商 NAT 后面是常态,额度卡太死会把正在付款的人自己拦住
//   read  检查更新/定价的小响应;检查更新会多做一次聚合 UPSERT
//   download 用户确认更新时解析一次临时直链;独立分桶,避免检查更新耗尽解析额度
//   stats 安装器触发上报,只做一次聚合 UPSERT
//   admin 你在菜单里手点,一分钟 60 次绰绰有余
//
// ★ 必须按类别分桶。若所有类别共用一个计数器,那么同一个 IP 打了 60 次 read 之后,
//   计数是 60,再调 activate 时拿 60 去比 10 就被拒了——便宜接口的流量会把贵接口锁死。
const LIMITS = { write: 10, renew: 30, poll: 120, read: 60, download: 30, stats: 120, admin: 60 };

// 桶数上限。到顶说明正被大范围打,新桶一律拒——宁可错杀也别让 Map 把内存撑爆。
const RATE_MAX_BUCKETS = 20_000;

const rateBuckets = new Map();   // "ip|类别" -> { n, resetAt }

function sweepRateBuckets() {
    const t = Date.now();
    for (const [k, b] of rateBuckets) if (t >= b.resetAt) rateBuckets.delete(k);
}
// 定期清过期桶。从前是"满了就整个 clear",那意味着谁弄来一万个 IP 就能把所有人的
// 计数一起抹掉,限速直接失效。只删过期的,别动还在计数的。
setInterval(sweepRateBuckets, RATE_WINDOW_MS).unref();

/** [cls] 见 LIMITS。超额返回 true。 */
function rateLimited(ip, cls) {
    const t = Date.now();
    const key = `${ip}|${cls}`;
    let b = rateBuckets.get(key);
    if (!b || t >= b.resetAt) {
        if (!b && rateBuckets.size >= RATE_MAX_BUCKETS) {
            sweepRateBuckets();
            if (rateBuckets.size >= RATE_MAX_BUCKETS) {
                log(`RATE_TABLE_FULL ip=${ip} cls=${cls} —— 拒绝新桶`);
                return true;
            }
        }
        b = { n: 0, resetAt: t + RATE_WINDOW_MS };
        rateBuckets.set(key, b);
    }
    b.n++;
    return b.n > LIMITS[cls];
}

// ---------------------------------------------------------------- 业务

// 单设备浮动授权:一个码同时只有一台在用,新设备激活即"顶替"旧设备。
// 反滥用:一个码在滚动 30 天窗口内累计激活 ≥ CHURN_MAX 次 → 判定共享/倒卖,永久吊销整码;
// 各持有设备下次联网续签即被踢成免费(离线也会在硬过期后降级)。
// 计"激活次数"(含被顶替后又回来激活的设备,即 A↔B 来回共享的每一下);
// 不含:当前在用设备原地重装(幂等)与 /v1/restore(合法单机找回,且被踢设备无法 restore)。
// 代价:在自有两台设备间频繁来回切换的正版用户可能被误判(与两人共享机器上无法区分)。
const CHURN_WINDOW_MS = 30 * 24 * 3600_000;
const CHURN_MAX = 6;

function apiActivate(body) {
    const code = normCode(body.code), fp = String(body.fp || '').toLowerCase();
    if (!CODE_RE.test(code) || !FP_RE.test(fp)) return { ok: false, err: 'CODE_NOT_FOUND' };

    const row = db.prepare('SELECT status, expires_at FROM codes WHERE code = ?').get(code);
    if (!row) return { ok: false, err: 'CODE_NOT_FOUND' };
    if (row.status !== 'active') return { ok: false, err: 'CODE_REVOKED' };
    if (!codeLive(row)) return { ok: false, err: 'CODE_EXPIRED' };

    const bound = db.prepare('SELECT id FROM bindings WHERE code = ? AND device_fp = ?').get(code, fp);
    if (bound) {
        // 幂等:同一设备重复激活(卸载重装/再次点激活)直接重发通行证,不算换机、不计查重
        db.prepare('UPDATE bindings SET last_renew_at = ?, app_ver = ? WHERE id = ?')
            .run(now(), String(body.app_ver || ''), bound.id);
        return { ok: true, token: issueToken(code, fp, row.expires_at) };
    }

    // 新设备:记一次激活事件(含机型/版本,永久保留作历史与取证;查重只看近 30 天窗口)
    db.prepare('INSERT INTO activations (code, device_fp, device_model, app_ver, at) VALUES (?, ?, ?, ?, ?)')
        .run(code, fp, String(body.model || ''), String(body.app_ver || ''), now());
    const uses = db.prepare(
        'SELECT COUNT(*) AS n FROM activations WHERE code = ? AND at > ?'
    ).get(code, new Date(Date.now() - CHURN_WINDOW_MS).toISOString()).n;
    if (uses >= CHURN_MAX) {
        db.prepare(`UPDATE codes SET status = 'revoked', revoked_at = ?, revoke_reason = ?
                    WHERE code = ? AND status = 'active'`).run(now(), 'abuse:churn', code);
        log(`ABUSE_REVOKE ${code} uses=${uses}/30d`);
        return { ok: false, err: 'CODE_REVOKED' };
    }

    // 顶替:删掉该码其它设备的绑定,只保留本机(换机自助生效;被顶替设备下次续签得 NOT_BOUND 降级)
    const kicked = db.prepare('DELETE FROM bindings WHERE code = ?').run(code).changes;
    db.prepare(`INSERT INTO bindings (code, device_fp, device_model, app_ver, activated_at, last_renew_at)
                VALUES (?, ?, ?, ?, ?, ?)`)
        .run(code, fp, String(body.model || ''), String(body.app_ver || ''), now(), now());
    log(`ACTIVATE ${code} fp=${fp.slice(0, 8)} model=${body.model || '-'} kicked=${kicked}`);
    return { ok: true, token: issueToken(code, fp, row.expires_at) };
}

// 按设备指纹恢复(重装后无本地码时用户主动触发):仅当本机仍是该码当前绑定设备才成功。
// 被顶替过的旧设备查不到绑定 → NOT_BOUND(符合单设备语义)。返回码供本地保存与"查看激活码"。
// 订阅到期的码也当作没有:恢复出来也是个不能用的码,不如让 App 走购买/续费。
function apiRestore(body) {
    const fp = String(body.fp || '').toLowerCase();
    if (!FP_RE.test(fp)) return { ok: false, err: 'NOT_BOUND' };
    const b = db.prepare(`SELECT b.code AS code, c.expires_at AS expires_at
                          FROM bindings b JOIN codes c ON c.code = b.code
                          WHERE b.device_fp = ? AND c.status = 'active'
                            AND (c.expires_at IS NULL OR c.expires_at > ?)
                          ORDER BY b.activated_at DESC`).get(fp, now());
    if (!b) return { ok: false, err: 'NOT_BOUND' };
    db.prepare('UPDATE bindings SET last_renew_at = ? WHERE code = ? AND device_fp = ?')
        .run(now(), b.code, fp);
    log(`RESTORE ${b.code} fp=${fp.slice(0, 8)}`);
    return { ok: true, token: issueToken(b.code, fp, b.expires_at), code: b.code };
}

function apiRenew(body) {
    const code = normCode(body.code), fp = String(body.fp || '').toLowerCase();
    if (!CODE_RE.test(code) || !FP_RE.test(fp)) return { ok: false, err: 'NOT_BOUND' };

    const row = db.prepare('SELECT status, expires_at FROM codes WHERE code = ?').get(code);
    if (!row) return { ok: false, err: 'NOT_BOUND' };
    if (row.status !== 'active') return { ok: false, err: 'CODE_REVOKED' };
    if (!codeLive(row)) return { ok: false, err: 'CODE_EXPIRED' };

    const bound = db.prepare('SELECT id FROM bindings WHERE code = ? AND device_fp = ?').get(code, fp);
    if (!bound) return { ok: false, err: 'NOT_BOUND' };

    db.prepare('UPDATE bindings SET last_renew_at = ?, app_ver = ? WHERE id = ?')
        .run(now(), String(body.app_ver || ''), bound.id);
    return { ok: true, token: issueToken(code, fp, row.expires_at) };
}

function adminNewCodes(body) {
    const count = Math.min(Math.max(parseInt(body.count, 10) || 1, 1), 100);
    const note = String(body.note || '');
    // days 省略即永久码:自测、补偿、送人用的码不该跟着订阅到期。
    // 封顶 MAX_DAYS:年份超过 9999 时 toISOString 会输出 "+029405-..." 这种扩展格式,
    // '+' 的字典序小于 '2',而 codeLive 靠字典序比时间——那样的码一生下来就"已过期"。
    const days = Math.min(Math.max(parseInt(body.days, 10) || 0, 0), MAX_DAYS);
    const expiresAt = days ? new Date(Date.now() + days * 24 * 3600_000).toISOString() : null;
    const ins = db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)');
    const codes = [];
    while (codes.length < count) {
        const c = newCode();
        try { ins.run(c, note, now(), expiresAt); codes.push(c); }
        catch (e) { if (!String(e.message).includes('UNIQUE')) throw e; } // 撞码重试(概率 ~0)
    }
    log(`NEW_CODES x${count} days=${days || '永久'} note="${note}"`);
    return { ok: true, codes };
}

function adminListCodes() {
    const codes = db.prepare('SELECT * FROM codes ORDER BY created_at DESC').all();
    const bs = db.prepare('SELECT * FROM bindings ORDER BY activated_at').all();
    const byCode = new Map();
    for (const b of bs) {
        if (!byCode.has(b.code)) byCode.set(b.code, []);
        byCode.get(b.code).push({
            fp: b.device_fp, model: b.device_model, app_ver: b.app_ver,
            activated_at: b.activated_at, last_renew_at: b.last_renew_at,
        });
    }
    // 激活历史(含被顶替过的旧设备,永久保留):机型/版本/时间,供取证与统计
    const acts = db.prepare('SELECT code, device_fp, device_model, app_ver, at FROM activations ORDER BY at').all();
    const actByCode = new Map();
    for (const a of acts) {
        if (!actByCode.has(a.code)) actByCode.set(a.code, []);
        actByCode.get(a.code).push({ fp: a.device_fp, model: a.device_model, app_ver: a.app_ver, at: a.at });
    }
    return {
        ok: true,
        codes: codes.map((c) => ({
            code: c.code, status: c.status, note: c.note, expires_at: c.expires_at,
            created_at: c.created_at, revoked_at: c.revoked_at, revoke_reason: c.revoke_reason,
            bindings: byCode.get(c.code) || [],
            activations: actByCode.get(c.code) || [],
        })),
    };
}

function adminUnbind(body) {
    const code = normCode(body.code), prefix = normFpPrefix(body.fp);
    if (!prefix) return { ok: false, err: 'FP_REQUIRED' };
    const rows = db.prepare('SELECT id, device_fp FROM bindings WHERE code = ?').all(code)
        .filter((b) => b.device_fp.startsWith(prefix));
    if (rows.length === 0) return { ok: false, err: 'NOT_FOUND' };
    if (rows.length > 1) return { ok: false, err: 'AMBIGUOUS' };
    db.prepare('DELETE FROM bindings WHERE id = ?').run(rows[0].id);
    log(`UNBIND ${code} fp=${rows[0].device_fp.slice(0, 8)}`);
    return { ok: true };
}

function adminRevoke(body) {
    const code = normCode(body.code);
    const r = db.prepare(`UPDATE codes SET status = 'revoked', revoked_at = ?, revoke_reason = ?
                          WHERE code = ? AND status = 'active'`)
        .run(now(), String(body.reason || ''), code);
    if (r.changes === 0) return { ok: false, err: 'NOT_FOUND' };
    log(`REVOKE ${code} reason="${body.reason || ''}"`);
    return { ok: true };
}

// 手动指定有效期的上限(约 100 年)。见 adminNewCodes 里为什么不能让它无限大。
const MAX_DAYS = 36500;

/**
 * 改一个码的有效期(送永久 / 补偿延期)。
 * 送永久用不着发新码——直接把他手上那个码设成永久:用户零操作,重开 App 即生效,
 * 手里的码不变,台账也不会多出一个和订单对不上的码。
 * days = 0 → 永久;days > 0 → 在现有到期日基础上延长(不吃掉剩余时间)。
 */
function adminSetExpiry(body) {
    const code = normCode(body.code);
    const days = parseInt(body.days, 10);
    if (!Number.isInteger(days) || days < 0 || days > MAX_DAYS) return { ok: false, err: 'BAD_DAYS' };

    const row = db.prepare('SELECT status, expires_at FROM codes WHERE code = ?').get(code);
    if (!row) return { ok: false, err: 'NOT_FOUND' };
    // 吊销的码改有效期没意义——他现在是免费版,改完还是免费版。先解除吊销。
    if (row.status !== 'active') return { ok: false, err: 'CODE_REVOKED' };

    if (days === 0) {
        db.prepare('UPDATE codes SET expires_at = NULL WHERE code = ?').run(code);
        log(`SET_EXPIRY ${code} -> 永久`);
        return { ok: true, expires_at: null };
    }
    // 永久码没有到期日可延,给它加天数只会把"永久"缩成 N 天,一定不是本意。
    if (!row.expires_at) return { ok: false, err: 'ALREADY_PERMANENT' };
    // 从 max(现在, 原到期) 起算,与续费同一套算法:没到期的不吃掉剩余时间,
    // 过期很久的也不白送中间那段。
    const base = Math.max(Date.now(), Date.parse(row.expires_at));
    const next = new Date(base + days * 24 * 3600_000).toISOString();
    db.prepare('UPDATE codes SET expires_at = ? WHERE code = ?').run(next, code);
    log(`SET_EXPIRY ${code} +${days}d -> ${next}`);
    return { ok: true, expires_at: next };
}

// 解除吊销:查重(CHURN_MAX)是自动且永久的,误伤正版用户时必须有一条不用登服务器
// 改库的路。顺带清空该码近 30 天的激活历史——不清的话次数还在窗口里,他一激活就又被吊。
// 历史清了就查不到证据,所以只在确认误伤时用。
function adminUnrevoke(body) {
    const code = normCode(body.code);
    const r = db.prepare(`UPDATE codes SET status = 'active', revoked_at = NULL, revoke_reason = NULL
                          WHERE code = ? AND status = 'revoked'`).run(code);
    if (r.changes === 0) return { ok: false, err: 'NOT_FOUND' };
    const cleared = db.prepare('DELETE FROM activations WHERE code = ? AND at > ?')
        .run(code, new Date(Date.now() - CHURN_WINDOW_MS).toISOString()).changes;
    log(`UNREVOKE ${code} cleared_activations=${cleared}`);
    return { ok: true, cleared_activations: cleared };
}

// ---------------------------------------------------------------- 虎皮椒(自动售码)
// 接口文档 https://www.xunhupay.com/doc :MD5 签名(非空参数字典序拼 k=v& 后直接缀 appSecret);
// 资金由微信/支付宝官方直清到自有账户,平台不碰货款。notify 带签名可验,
// 但发码仍统一走 confirmPaid 的主动查单——单一发码路径,回调只当加速信号。

function xhHash(params) {
    const str = Object.keys(params)
        .filter((k) => k !== 'hash' && params[k] !== undefined && params[k] !== null && params[k] !== '')
        .sort()
        .map((k) => `${k}=${params[k]}`)
        .join('&') + cfg.xhAppSecret;
    return crypto.createHash('md5').update(str, 'utf8').digest('hex');
}

function xhPost(apiPath, params) {
    params.appid = cfg.xhAppId;
    params.time = Math.floor(Date.now() / 1000);
    params.nonce_str = crypto.randomBytes(8).toString('hex');
    params.hash = xhHash(params);
    const body = new URLSearchParams(params).toString(); // 官方示例为表单编码,响应为 JSON
    return new Promise((resolve, reject) => {
        const req = https.request({
            hostname: 'api.xunhupay.com', path: apiPath, method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Content-Length': Buffer.byteLength(body),
            },
            timeout: 10_000,
        }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
                catch { reject(new Error('xh bad json')); }
            });
        });
        req.on('timeout', () => req.destroy(new Error('xh timeout')));
        req.on('error', reject);
        req.end(body);
    });
}

// 同设备未支付订单的复用窗口:短于虎皮椒二维码 5 分钟有效期,
// 保证复用到的码仍可扫;超过则新建(配合 App 端 5 分钟"过期刷新")。
const PENDING_REUSE_MS = 4 * 60_000;
// 跨商品/跨续费目标的冲突窗口必须覆盖上游二维码完整有效期。不能用上面的 4 分钟复用窗口：
// 第 4~5 分钟旧二维码仍可能付款，此时若允许切商品建第二单会造成两种商品同时扣款。
// 多留 1 分钟覆盖客户端/服务端时钟与上游失效传播误差。
const PENDING_CONFLICT_MS = 6 * 60_000;

// 下单前回查多少张该设备的未支付旧单(见 apiOrderCreate 闸三)。每张一次上游请求,
// 所以要封顶;取最近的几张就够——用户不会去付一张几天前的码。
const STALE_PROBE_MAX = 5;

function newOrderId() {
    // ZT + 毫秒时间戳36进制 + 4位随机,全大写字母数字,唯一性由 PRIMARY KEY 兜底
    return 'ZT' + Date.now().toString(36).toUpperCase()
        + crypto.randomInt(36 ** 4).toString(36).toUpperCase().padStart(4, '0');
}

async function apiOrderCreate(body) {
    if (!PAY_ENABLED) return { ok: false, err: 'PAY_DISABLED' };
    const fp = String(body.fp || '').toLowerCase();
    if (!FP_RE.test(fp)) return { ok: false, err: 'BAD_REQUEST' };
    // 老 App 不传 product，必须继续购买年费；一旦显式传入则只接受两个稳定商品 ID。
    const product = Object.prototype.hasOwnProperty.call(body, 'product')
        ? body.product : PRODUCT_ANNUAL;
    if (!PRODUCTS.has(product)) return { ok: false, err: 'BAD_PRODUCT' };
    // renew:用户在 App 里主动点的"续费"。他就是要付钱,前两道闸得让路(否则提前续费无门)。
    const renewWanted = Boolean(body.renew);

    // ---- 防重复收费(三道)----------------------------------------------------
    // 任一命中都不建单、不收钱,直接把这台机已有的码还给 App(App 侧走 already_pro 免费恢复)。
    // 三道都只认 status='active' 的码:被吊销的(退款/查重)不还给他,否则他会永远拿着一个
    // 死码又没法重新购买。前两道还要求"仍在有效期内":订阅到期的码必须放行去建单,
    // 否则到期用户点购买只会被告知"你已经买过了",永远付不了续费的钱。

    // 一、本机已是某个有效码的绑定设备(重装后没走"恢复"就又点了购买)。
    const permanent = db.prepare(`
        SELECT code FROM (
          SELECT b.code AS code, b.activated_at AS at
            FROM bindings b JOIN codes c ON c.code = b.code
           WHERE b.device_fp = ? AND c.status = 'active' AND c.expires_at IS NULL
          UNION ALL
          SELECT o.code AS code, o.paid_at AS at
            FROM orders o JOIN codes c ON c.code = o.code
           WHERE o.device_fp = ? AND o.status = 'paid'
             AND c.status = 'active' AND c.expires_at IS NULL
        ) ORDER BY at DESC LIMIT 1`).get(fp, fp);
    if (permanent) {
        log(`ORDER_SKIP_PERMANENT fp=${fp.slice(0, 8)} code=${permanent.code} requested=${product}`);
        return { ok: true, already_pro: true, code: permanent.code, product };
    }

    const owned = db.prepare(`SELECT b.code AS code, c.expires_at AS expires_at
                              FROM bindings b JOIN codes c ON c.code = b.code
                              WHERE b.device_fp = ? AND c.status = 'active'
                              ORDER BY b.activated_at DESC`).get(fp);
    const paid = db.prepare(`SELECT o.code AS code, c.expires_at AS expires_at
                             FROM orders o JOIN codes c ON c.code = o.code
                             WHERE o.device_fp = ? AND o.status = 'paid' AND c.status = 'active'
                             ORDER BY o.paid_at DESC`).get(fp);
    const t = now();
    // 有多张历史码时必须在 SQL 内先筛“有效”再取最新，不能取到一张过期码后漏掉更早的有效码。
    const ownedLive = db.prepare(`SELECT b.code AS code
                                  FROM bindings b JOIN codes c ON c.code = b.code
                                  WHERE b.device_fp = ? AND c.status = 'active' AND c.expires_at > ?
                                  ORDER BY b.activated_at DESC`).get(fp, t);
    const paidLive = db.prepare(`SELECT o.code AS code
                                 FROM orders o JOIN codes c ON c.code = o.code
                                 WHERE o.device_fp = ? AND o.status = 'paid'
                                   AND c.status = 'active' AND c.expires_at > ?
                                 ORDER BY o.paid_at DESC`).get(fp, t);
    if (product === PRODUCT_ANNUAL && !renewWanted && ownedLive) {
        log(`ORDER_SKIP_OWNED fp=${fp.slice(0, 8)} code=${ownedLive.code} product=${product}`);
        return { ok: true, already_pro: true, code: ownedLive.code, product };
    }

    // 二、本机付过款、码也发了,但从未激活成功(付完就卸载重装/清数据 → App 丢了 pending_order)。
    //     此时既没有 binding,那张 paid 单也过不了下面复用查询的 status='pending' 过滤——
    //     没有这道就会再收一次钱,而服务器早就为这台机发过码了。
    if (product === PRODUCT_ANNUAL && paidLive && !renewWanted) {
        log(`ORDER_SKIP_PAID fp=${fp.slice(0, 8)} code=${paidLive.code} product=${product}`);
        return { ok: true, already_pro: true, code: paidLive.code, product };
    }

    // 订单 intent 快照：年费到期购买/主动续费沿用绑定码；永久版购买可把有效或过期年费码原地升级。
    const target = product === PRODUCT_LIFETIME ? (owned || paid) : owned;
    const renewCode = target ? target.code : null;
    // lifetime + renew=true 表示把现有年费码原地升级为永久，而不是给永久权益“续费”。
    if (product === PRODUCT_LIFETIME && renewWanted && !renewCode) {
        return { ok: false, err: 'BAD_RENEW_TARGET', product };
    }

    // 三、本机的未支付旧单 → 建新单前逐一向虎皮椒确认。
    //     "钱付了但 notify 没送到、App 又丢了单号"时,这是唯一能发现钱其实已到账的地方;
    //     不查就会二次收费。
    //     ★ 必须查【多张】而不只是最新那张:购买页每 5 分钟过期刷新一次,同一设备会攒下
    //       好几张 pending 单。用户手里打开的可能是上一张码(upstream 5 分钟内仍可付),
    //       只查最新的就永远发现不了那笔钱。取最近 STALE_PROBE_MAX 张——再往前的
    //       upstream 早就失效、不可能被付,查了也是白打上游。
    const stale = db.prepare(`SELECT out_trade_no FROM orders WHERE device_fp = ? AND status = 'pending'
                              ORDER BY created_at DESC LIMIT ?`).all(fp, STALE_PROBE_MAX);
    for (const s of stale) {
        const r = await confirmPaid(s.out_trade_no);
        if (r && r.code) {
            log(`ORDER_SKIP_LATE_PAID fp=${fp.slice(0, 8)} order=${s.out_trade_no} code=${r.code} product=${r.product}`);
            // 若刚确认的是另一个商品，先把其结果交还 App，绝不在同一次点击里紧接着再收第二笔钱。
            if (r.product !== product) {
                return { ok: true, already_pro: true, code: r.code, product: r.product };
            }
            return { ok: true, already_pro: true, code: r.code, product: r.product };
        }
    }
    // --------------------------------------------------------------------------

    // 【不清理旧订单 —— 这是有意的】
    // 这里曾经有一句"删掉 7 天前仍未支付的死单"。它有两个错:
    //   1. 本地 status='pending' ≠ 用户没付钱。notify 会丢(闸三存在的唯一理由就是这个),
    //      一张真金白银付过的单可能一直挂着 pending。删掉 = 订单号都不存在了,
    //      查单返回 NOT_FOUND、闸三无从查起,用户只能被再收一次钱。
    //   2. 它不限设备,是【全局】删。于是甲的钱,被素不相识的乙点一下购买就删没了。
    // orders 是对账台账(code ↔ charge_id ↔ 微信流水),本来就该留着。一行几百字节,
    // 攒到几万单也就几 MB,SQLite 毫无压力。

    // 同设备复用窗口(PENDING_REUSE_MS)内的未支付订单直接复用,反复点购买不会刷出一堆新单
    const pendingRows = db.prepare(`SELECT out_trade_no, pay_url, pay_qr, renew_code, amount_fen,
                                           product, created_at
                                    FROM orders
                                    WHERE device_fp = ? AND status = 'pending' AND created_at > ?
                                    ORDER BY created_at DESC`)
        .all(fp, new Date(Date.now() - PENDING_CONFLICT_MS).toISOString());
    const reuseAfter = new Date(Date.now() - PENDING_REUSE_MS).toISOString();
    const sameIntent = pendingRows.find((row) =>
        row.created_at > reuseAfter
        && row.product === product
        && (row.renew_code || null) === renewCode);
    const otherIntent = pendingRows.find((row) =>
        row.product !== product || (row.renew_code || null) !== renewCode);
    if (otherIntent) {
        log(`ORDER_PENDING_CONFLICT fp=${fp.slice(0, 8)} requested=${product}`
            + ` target=${renewCode || '-'} pending=${otherIntent.product} pending_target=${otherIntent.renew_code || '-'}`);
        return {
            ok: false,
            err: 'PENDING_OTHER_PRODUCT',
            product,
            pending_product: otherIntent.product,
        };
    }
    if (sameIntent) {
        // 复用旧单就得报旧价:二维码是按下单当时的 amount_fen 生成的,中途改价也不能变。
        return {
            ok: true, order: sameIntent.out_trade_no, pay_url: sameIntent.pay_url, pay_qr: sameIntent.pay_qr,
            renew: Boolean(sameIntent.renew_code),
            price_fen: sameIntent.amount_fen, product,
        };
    }

    const order = newOrderId();
    // 现读定价:App 缓存的展示价可能过时(它常连着相机热点没外网,拉不到新价),
    // 但这里现读的才是真正要收的钱,并随响应回给 App —— 付款页显示的一定是这个数。
    const currentPricing = pricing();
    const selectedPricing = currentPricing[product];
    if (!selectedPricing.available) return { ok: false, err: 'PRODUCT_UNAVAILABLE', product };
    const priceFen = selectedPricing.priceFen;
    const grantDays = product === PRODUCT_ANNUAL ? SUB_PERIOD_DAYS : 0;
    let resp;
    try {
        resp = await xhPost('/payment/do.html', {
            version: '1.1',
            trade_order_id: order,
            total_fee: (priceFen / 100).toFixed(2),   // 虎皮椒金额单位为元
            title: product === PRODUCT_LIFETIME ? 'ZTransfer Pro 永久版' : 'ZTransfer Pro 年费版',
            notify_url: cfg.payNotifyUrl,
        });
    } catch (e) {
        log(`ORDER_UPSTREAM_FAIL product=${product} ${e.message}`);
        return { ok: false, err: 'PAY_UPSTREAM' };
    }
    // url_qrcode:现成的二维码图片地址(微信个人支付主用扫码);url:手机端支付链接。
    // 至少要有其一才算下单成功。
    if (Number(resp.errcode) !== 0 || (!resp.url && !resp.url_qrcode)) {
        log(`ORDER_CREATE_REJECTED product=${product} ${resp.errmsg || JSON.stringify(resp).slice(0, 200)}`);
        return { ok: false, err: 'PAY_UPSTREAM' };
    }
    db.prepare(`INSERT INTO orders
                (out_trade_no, device_fp, amount_fen, product, grant_days, renew_code, pay_url, pay_qr, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(order, fp, priceFen, product, grantDays, renewCode, resp.url || '', resp.url_qrcode || '', now());
    log(`ORDER_NEW ${order} fp=${fp.slice(0, 8)} product=${product} ¥${priceFen / 100}`
        + `${renewCode ? ` target=${renewCode}` : ''}`);
    return {
        ok: true, order, pay_url: resp.url || '', pay_qr: resp.url_qrcode || '',
        renew: Boolean(renewCode), price_fen: priceFen, product,
    };
}

// 对上游查单限频:同一订单 4.5s 内只查一次。App 轮询 2s,叠加节流后实际上游
// 频率约 6s 一次,落在虎皮椒官方建议的 5-10s 区间内;notify 到达时可再快一拍。
const orderCheckAt = new Map();

/**
 * 向虎皮椒确认支付;确认到账则发码或续期(幂等:一单永远只发同一个码)。返回最新订单行。
 */
async function confirmPaid(order) {
    let row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
    if (!row || row.status === 'paid' || row.code) return row;
    if (row.status !== 'pending') return row;

    const last = orderCheckAt.get(order) || 0;
    if (Date.now() - last < 4500) return row;
    orderCheckAt.set(order, Date.now());
    if (orderCheckAt.size > 10_000) orderCheckAt.clear(); // 同 rateBuckets 的内存兜底

    let q;
    try {
        q = await xhPost('/payment/query.html', { out_trade_order: order });
    } catch (e) {
        log(`ORDER_QUERY_FAIL ${order} product=${row.product} ${e.message}`);
        return row;
    }
    // data.status: WP待支付 OD已支付 CD已取消;仅 OD 发码
    if (Number(q.errcode) !== 0 || !q.data || q.data.status !== 'OD') return row;

    // 上游 await 之后以写事务重读订单。履约与 paid 标记在同一事务中：
    // notify、App 轮询甚至另一个服务进程同时确认，也只会有一个事务真正发放权益。
    let code;
    let target = null;
    let paidRow;
    let redundantPermanent = false;
    try {
        db.exec('BEGIN IMMEDIATE');
        row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
        if (!row || row.status === 'paid' || row.code) {
            db.exec('COMMIT');
            return row;
        }
        if (row.status !== 'pending') throw new Error(`BAD_ORDER_STATUS_${row.status}`);
        if (!PRODUCTS.has(row.product)) throw new Error(`BAD_ORDER_PRODUCT_${row.product}`);
        if (row.product === PRODUCT_ANNUAL &&
            (!Number.isInteger(row.grant_days) || row.grant_days <= 0)) {
            throw new Error(`BAD_ORDER_GRANT_DAYS_${row.grant_days}`);
        }

        // 目标在下单后被吊销时改为发新码：钱已到账，不能履约成一个不可用的死码。
        target = row.renew_code
            ? db.prepare("SELECT code, expires_at FROM codes WHERE code = ? AND status = 'active'")
                .get(row.renew_code)
            : null;
        if (target) {
            code = target.code;
            if (row.product === PRODUCT_LIFETIME) {
                // 有效或过期年费码均原地升级，绑定关系和激活码都不变。
                db.prepare('UPDATE codes SET expires_at = NULL WHERE code = ?').run(code);
            } else if (target.expires_at) {
                // 年费只使用订单 grant_days 快照；提前续不损失剩余时间。
                const base = Math.max(Date.now(), Date.parse(target.expires_at));
                db.prepare('UPDATE codes SET expires_at = ? WHERE code = ?')
                    .run(new Date(base + row.grant_days * 24 * 3600_000).toISOString(), code);
            } else {
                // 下单时还是年费、付款前被管理员或另一张永久订单升级。钱已到账只能记账幂等，
                // 但永久权益无法再延长；单独打高优先级日志供人工核对/退款，绝不能静默吞掉。
                redundantPermanent = true;
            }
        } else {
            const ins = db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)');
            const expiresAt = row.product === PRODUCT_LIFETIME
                ? null : new Date(Date.now() + row.grant_days * 24 * 3600_000).toISOString();
            for (;;) {
                code = newCode();
                try { ins.run(code, `xh:${order}`, now(), expiresAt); break; }
                catch (e) { if (!String(e.message).includes('UNIQUE')) throw e; } // 撞码重试(概率 ~0)
            }
        }
        const marked = db.prepare(`UPDATE orders SET status = 'paid', code = ?, charge_id = ?, paid_at = ?
                                   WHERE out_trade_no = ? AND status = 'pending' AND code IS NULL`)
            .run(code, String(q.data.open_order_id || ''), now(), order);
        if (marked.changes !== 1) throw new Error('ORDER_MARK_PAID_LOST_RACE');
        db.exec('COMMIT');
        paidRow = db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
    } catch (e) {
        try { db.exec('ROLLBACK'); } catch { /* BEGIN 失败时无事务可回滚 */ }
        log(`ORDER_FULFILL_FAILED ${order} product=${row?.product || '-'} err=${e.message}`);
        return db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order) || row;
    }
    log(`ORDER_PAID ${order} code=${code} product=${paidRow.product}`
        + `${target ? ` target=${target.code}` : ''} xh=${q.data.open_order_id || '-'}`);
    if (redundantPermanent) {
        log(`ORDER_PAID_REDUNDANT_PERMANENT ${order} code=${code} amount_fen=${paidRow.amount_fen}`
            + ` xh=${q.data.open_order_id || '-'} MANUAL_REFUND_REQUIRED`);
    }
    return paidRow;
}

async function apiOrderStatus(body) {
    if (!PAY_ENABLED) return { ok: false, err: 'PAY_DISABLED' };
    const fp = String(body.fp || '').toLowerCase();
    const order = String(body.order || '');
    if (!FP_RE.test(fp) || !/^ZT[A-Z0-9]{4,20}$/.test(order)) return { ok: false, err: 'BAD_REQUEST' };

    let row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ? AND device_fp = ?').get(order, fp);
    if (!row) return { ok: false, err: 'NOT_FOUND' };
    if (!row.code) row = await confirmPaid(order) || row;

    if (row.code) {
        return {
            ok: true,
            status: 'paid',
            code: row.code,
            renew: Boolean(row.renew_code),
            product: row.product,
            price_fen: row.amount_fen,
        };
    }
    // want_url:App 重进购买页续用旧单时才要支付链接,常规轮询不带。
    // 超过复用窗口的旧链接码可能已过期,不再给出——App 拿不到会自行新建订单。
    // price_fen 给的是【下单当时】锁定的 amount_fen,不是现价:二维码是按那个价生成的,
    // 中途改价也不能让付款页显示成新价。
    const out = {
        ok: true,
        status: 'pending',
        renew: Boolean(row.renew_code),
        product: row.product,
    };
    if (body.want_url && row.created_at > new Date(Date.now() - PENDING_REUSE_MS).toISOString()) {
        out.pay_url = row.pay_url;
        out.pay_qr = row.pay_qr;
        out.price_fen = row.amount_fen;
    }
    return out;
}

/**
 * 虎皮椒异步通知(表单编码,带 MD5 签名)。验签通过才处理,发码仍统一走
 * confirmPaid 的主动查单(单一发码路径);处理完固定回纯文本 "success" 停止重推。
 */
async function apiPayNotify(params) {
    if (!PAY_ENABLED) return;
    if (!params.hash || xhHash(params) !== params.hash) {
        log(`NOTIFY_BAD_HASH ${JSON.stringify(params).slice(0, 200)}`);
        return;
    }
    const order = String(params.trade_order_id || '');
    if (params.status === 'OD' && /^ZT[A-Z0-9]{4,20}$/.test(order)) {
        await confirmPaid(order);
    } else if (params.status && params.status !== 'OD') {
        // CD已退款 / RD退款中 / UD退款失败:记日志人工跟进(必要时 /admin/revoke 吊码)
        const row = db.prepare('SELECT product FROM orders WHERE out_trade_no = ?').get(order);
        log(`NOTIFY_REFUND ${order} product=${row?.product || '-'} status=${params.status}`);
    }
}

// ---------------------------------------------------------------- HTTP

function readRaw(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > 8192) { reject(new Error('body too large')); req.destroy(); return; }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

async function readBody(req) {
    const text = await readRaw(req);
    try { return text ? JSON.parse(text) : {}; }
    catch { throw new Error('bad json'); }
}

function send(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(body);
}

// ---------------------------------------------------------------- App 检查更新 / 下载
// 版本信息放 config.json 同目录的 app-latest.json,由 admin.ps1 远程管理,无需登录服务器
// 或重启服务。App 真正开始下载时,服务端才向解析服务换取一次短期直链。原始分享链接
// 同时作为灾备下发,仅在解析服务故障时让用户走浏览器。以后更换解析方无需再升级 App。
const APP_LATEST_PATH = path.join(path.dirname(CONFIG_PATH), 'app-latest.json');
const LANZOU_PARSER_URL = String(cfg.lanzouParserUrl || 'https://lz.qaiu.top/json/parser');

function normalizeRelease(j) {
    if (!j || !Number.isInteger(j.versionCode) || j.versionCode <= 0 || !j.url) {
        throw new Error('versionCode/url 无效');
    }
    const minSupportedVersionCode = Number.isInteger(j.minSupportedVersionCode)
        ? j.minSupportedVersionCode : 1;
    if (minSupportedVersionCode < 1 || minSupportedVersionCode > j.versionCode) {
        throw new Error('minSupportedVersionCode 必须在 1..versionCode 之间');
    }
    const shareUrl = new URL(String(j.url));
    if (shareUrl.protocol !== 'https:') throw new Error('url 必须是 HTTPS');
    const sha256 = String(j.sha256 || '').trim().toLowerCase();
    if (sha256 && !/^[0-9a-f]{64}$/.test(sha256)) throw new Error('sha256 格式无效');
    const sizeBytes = Number(j.sizeBytes || 0);
    if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 0) throw new Error('sizeBytes 格式无效');
    return {
        versionCode: j.versionCode,
        versionName: String(j.versionName || ''),
        minSupportedVersionCode,
        url: shareUrl.toString(),
        password: String(j.password || ''),
        notes: String(j.notes || ''),
        sha256,
        sizeBytes,
        publishedAt: String(j.publishedAt || ''),
    };
}

function releaseInfo() {
    try {
        return normalizeRelease(JSON.parse(fs.readFileSync(APP_LATEST_PATH, 'utf8')));
    } catch {
        return null;
    }
}

const updateCheckStmt = db.prepare(`
INSERT INTO update_stats (
  source_version_code, source_version_name, target_version_code, target_version_name,
  check_count, last_check_at
) VALUES (?, ?, ?, ?, 1, ?)
ON CONFLICT(source_version_code, target_version_code) DO UPDATE SET
  source_version_name = excluded.source_version_name,
  target_version_name = excluded.target_version_name,
  check_count = update_stats.check_count + 1,
  last_check_at = excluded.last_check_at
`);

const updateInstallStmt = db.prepare(`
INSERT INTO update_stats (
  source_version_code, source_version_name, target_version_code, target_version_name,
  install_trigger_count, last_install_at
) VALUES (?, ?, ?, ?, 1, ?)
ON CONFLICT(source_version_code, target_version_code) DO UPDATE SET
  source_version_name = excluded.source_version_name,
  target_version_name = excluded.target_version_name,
  install_trigger_count = update_stats.install_trigger_count + 1,
  last_install_at = excluded.last_install_at
`);

function versionLabel(value) {
    return String(value || '').trim().slice(0, 64);
}

function recordUpdateCheck(params, release) {
    const sourceCode = Number(params.get('currentVersionCode'));
    if (!Number.isInteger(sourceCode) || sourceCode <= 0 || sourceCode > release.versionCode) return;
    updateCheckStmt.run(
        sourceCode,
        versionLabel(params.get('currentVersionName')),
        release.versionCode,
        versionLabel(release.versionName),
        now()
    );
}

function apiAppLatest(params) {
    const j = releaseInfo();
    if (!j) return { ok: false, err: 'NO_VERSION_INFO' };
    try {
        recordUpdateCheck(params, j);
    } catch (e) {
        log(`APP_UPDATE_STATS_CHECK_FAILED err=${e.message}`);
    }
    return {
        ok: true,
        versionCode: j.versionCode,
        versionName: j.versionName,
        minSupportedVersionCode: j.minSupportedVersionCode,
        notes: j.notes,
        sha256: j.sha256,
        sizeBytes: j.sizeBytes,
        publishedAt: j.publishedAt,
        // 既兼容旧 App,也是新版在解析服务故障时的浏览器灾备入口。
        url: j.url,
        password: j.password,
    };
}

function apiAppInstallTrigger(body) {
    const release = releaseInfo();
    if (!release) return { ok: false, err: 'NO_VERSION_INFO' };
    const sourceCode = Number(body.sourceVersionCode);
    const targetCode = Number(body.targetVersionCode);
    if (!Number.isInteger(sourceCode) || sourceCode <= 0 ||
        !Number.isInteger(targetCode) || targetCode !== release.versionCode ||
        targetCode <= sourceCode) {
        return { ok: false, err: 'BAD_UPDATE_STATS' };
    }
    try {
        updateInstallStmt.run(
            sourceCode,
            versionLabel(body.sourceVersionName),
            targetCode,
            versionLabel(release.versionName),
            now()
        );
        return { ok: true };
    } catch (e) {
        log(`APP_UPDATE_STATS_INSTALL_FAILED err=${e.message}`);
        return { ok: false, err: 'UPDATE_STATS_UNAVAILABLE' };
    }
}

async function resolveLanzou(release) {
    const parserUrl = new URL(LANZOU_PARSER_URL);
    if (parserUrl.protocol !== 'https:') throw new Error('PARSER_URL_NOT_HTTPS');
    parserUrl.searchParams.set('url', release.url);
    parserUrl.searchParams.set('pwd', release.password);

    const response = await fetch(parserUrl, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`PARSER_HTTP_${response.status}`);
    const parsed = await response.json();
    if (parsed?.code !== 200 || parsed?.success !== true || !parsed?.data?.directLink) {
        throw new Error(`PARSER_REJECTED_${String(parsed?.code || 'UNKNOWN')}`);
    }
    const direct = new URL(String(parsed.data.directLink));
    if (direct.protocol !== 'https:') throw new Error('DIRECT_URL_NOT_HTTPS');
    // 蓝奏云部分节点返回 :446；同一签名资源在标准 HTTPS 443 可用。
    // 统一成 443，避免 Android DownloadManager 或移动网络长期等待特殊端口。
    if (direct.hostname.endsWith('.lanosso.com') && direct.port === '446') {
        direct.port = '443';
    }
    return { url: direct.toString() };
}

async function apiAppDownload(body) {
    const release = releaseInfo();
    if (!release) return { ok: false, err: 'NO_VERSION_INFO' };
    const requestedVersion = Number(body.versionCode);
    if (!Number.isInteger(requestedVersion) || requestedVersion !== release.versionCode) {
        // 防止本接口被当成任意蓝奏云解析代理,同时避免用旧弹窗下载已经撤回的包。
        return { ok: false, err: 'VERSION_CHANGED', latestVersionCode: release.versionCode };
    }
    try {
        const direct = await resolveLanzou(release);
        log(`APP_DOWNLOAD_RESOLVED version=${release.versionCode}`);
        return {
            ok: true,
            versionCode: release.versionCode,
            url: direct.url,
        };
    } catch (e) {
        log(`APP_DOWNLOAD_PARSE_FAILED version=${release.versionCode} err=${e.message}`);
        return { ok: false, err: 'DOWNLOAD_URL_UNAVAILABLE' };
    }
}

function writeJsonAtomic(target, value) {
    const tmp = `${target}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(tmp, target);
}

function adminGetUpdate() {
    const release = releaseInfo();
    return release ? { ok: true, release } : { ok: false, err: 'NO_VERSION_INFO' };
}

function adminGetUpdateStats() {
    const rows = db.prepare(`
SELECT
  source_version_code AS sourceVersionCode,
  source_version_name AS sourceVersionName,
  target_version_code AS targetVersionCode,
  target_version_name AS targetVersionName,
  check_count AS checkCount,
  install_trigger_count AS installTriggerCount,
  last_check_at AS lastCheckAt,
  last_install_at AS lastInstallAt
FROM update_stats
ORDER BY target_version_code DESC, source_version_code DESC
`).all();
    return { ok: true, rows };
}

async function adminValidateUpdate(body) {
    try {
        let release;
        if (Object.keys(body || {}).length) {
            if (!body.url) throw new Error('url 不能为空');
            const shareUrl = new URL(String(body.url));
            if (shareUrl.protocol !== 'https:') throw new Error('url 必须是 HTTPS');
            // 此时还没下载 APK,版本号稍后从真实安装包读取,不让管理员手填。
            release = { url: shareUrl.toString(), password: String(body.password || '') };
        } else {
            release = releaseInfo();
        }
        if (!release) return { ok: false, err: 'NO_VERSION_INFO' };
        const direct = await resolveLanzou(release);
        return { ok: true, versionCode: release.versionCode || 0, ...direct };
    } catch (e) {
        return { ok: false, err: 'UPDATE_VALIDATION_FAILED', detail: e.message };
    }
}

const MAX_ADMIN_APK_BYTES = 256 * 1024 * 1024;

async function adminDownloadUpdateApk(res, body) {
    try {
        if (!body.url) throw new Error('url 不能为空');
        const shareUrl = new URL(String(body.url));
        if (shareUrl.protocol !== 'https:') throw new Error('url 必须是 HTTPS');
        const release = { url: shareUrl.toString(), password: String(body.password || '') };
        const direct = await resolveLanzou(release);
        const response = await fetch(direct.url, {
            redirect: 'follow',
            signal: AbortSignal.timeout(300_000),
        });
        if (!response.ok) throw new Error(`APK_HTTP_${response.status}`);

        const declaredSize = Number(response.headers.get('content-length') || 0);
        if (declaredSize > MAX_ADMIN_APK_BYTES) throw new Error('APK_TOO_LARGE');
        const chunks = [];
        let total = 0;
        for await (const chunk of response.body) {
            total += chunk.length;
            if (total > MAX_ADMIN_APK_BYTES) throw new Error('APK_TOO_LARGE');
            chunks.push(Buffer.from(chunk));
        }
        if (total <= 0) throw new Error('APK_EMPTY');

        const apk = Buffer.concat(chunks, total);
        res.writeHead(200, {
            'Content-Type': 'application/vnd.android.package-archive',
            'Content-Length': apk.length,
            'Cache-Control': 'no-store',
        });
        res.end(apk);
        log(`ADMIN_UPDATE_APK_PROXIED bytes=${apk.length}`);
    } catch (e) {
        log(`ADMIN_UPDATE_APK_PROXY_FAILED err=${e.message}`);
        if (!res.headersSent) send(res, 502, { ok: false, err: 'APK_DOWNLOAD_FAILED' });
        else res.destroy();
    }
}

function adminPublishUpdate(body) {
    try {
        const next = normalizeRelease(body);
        const current = releaseInfo();
        if (current && next.versionCode <= current.versionCode) {
            return { ok: false, err: 'VERSION_NOT_NEWER' };
        }
        if (!next.publishedAt) next.publishedAt = now();
        writeJsonAtomic(APP_LATEST_PATH, next);
        log(`APP_UPDATE_PUBLISHED version=${next.versionCode} min=${next.minSupportedVersionCode}`);
        return { ok: true, release: next };
    } catch (e) {
        return { ok: false, err: 'BAD_UPDATE_INFO', detail: e.message };
    }
}

function adminSetUpdatePolicy(body) {
    const current = releaseInfo();
    if (!current) return { ok: false, err: 'NO_VERSION_INFO' };
    try {
        const next = normalizeRelease({
            ...current,
            minSupportedVersionCode: body.minSupportedVersionCode === undefined
                ? current.minSupportedVersionCode : Number(body.minSupportedVersionCode),
        });
        writeJsonAtomic(APP_LATEST_PATH, next);
        log(`APP_UPDATE_POLICY min=${next.minSupportedVersionCode}`);
        return { ok: true, release: next };
    } catch (e) {
        return { ok: false, err: 'BAD_UPDATE_POLICY', detail: e.message };
    }
}

const server = https.createServer(
    { cert: fs.readFileSync(cfg.tlsCertPath), key: fs.readFileSync(cfg.tlsKeyPath) },
    async (req, res) => {
        const ip = req.socket.remoteAddress || '?';
        try {
            const url = new URL(req.url, 'https://x');
            const route = `${req.method} ${url.pathname}`;

            // ★ 每条路由都要限速。别在这下面加"顺手不限速"的接口:哪怕只读,
            //   裸奔的接口就是别人拿来打 DB/CPU/磁盘的入口。
            const limit = (cls) => rateLimited(ip, cls);

            if (route === 'GET /healthz') {
                if (limit('read')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, { ok: true });
            }
            // App 检查更新 / 取当前定价:公开小接口,仍需限速。
            if (route === 'GET /v1/app/latest') {
                if (limit('read')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiAppLatest(url.searchParams));
            }
            if (route === 'POST /v1/app/download-url') {
                if (limit('download')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, await apiAppDownload(await readBody(req)));
            }
            if (route === 'POST /v1/app/install-trigger') {
                if (limit('stats')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiAppInstallTrigger(await readBody(req)));
            }
            if (route === 'GET /v1/pricing') {
                if (limit('read')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiPricing());
            }

            if (url.pathname.startsWith('/admin/')) {
                // 限速放在验令牌【之前】:顺带把令牌爆破也压住。管理操作是人在菜单里点,
                // 一分钟 60 次绰绰有余。
                if (limit('admin')) return send(res, 429, { ok: false, err: 'RATE_LIMITED' });
                if (!constantTimeEq(req.headers['x-admin-token'] || '', cfg.adminToken)) {
                    log(`ADMIN_DENIED ${route} ip=${ip}`);
                    return send(res, 401, { ok: false, err: 'UNAUTHORIZED' });
                }
                if (route === 'POST /admin/codes') return send(res, 200, adminNewCodes(await readBody(req)));
                if (route === 'GET /admin/codes') return send(res, 200, adminListCodes());
                if (route === 'POST /admin/unbind') return send(res, 200, adminUnbind(await readBody(req)));
                if (route === 'POST /admin/revoke') return send(res, 200, adminRevoke(await readBody(req)));
                if (route === 'POST /admin/unrevoke') return send(res, 200, adminUnrevoke(await readBody(req)));
                if (route === 'POST /admin/pricing') return send(res, 200, adminSetPricing(await readBody(req)));
                if (route === 'POST /admin/expiry') return send(res, 200, adminSetExpiry(await readBody(req)));
                if (route === 'GET /admin/update') return send(res, 200, adminGetUpdate());
                if (route === 'GET /admin/update/stats') return send(res, 200, adminGetUpdateStats());
                if (route === 'POST /admin/update/validate') return send(res, 200, await adminValidateUpdate(await readBody(req)));
                if (route === 'POST /admin/update/apk') return adminDownloadUpdateApk(res, await readBody(req));
                if (route === 'POST /admin/update/publish') return send(res, 200, adminPublishUpdate(await readBody(req)));
                if (route === 'POST /admin/update/policy') return send(res, 200, adminSetUpdatePolicy(await readBody(req)));
                return send(res, 404, { ok: false, err: 'NOT_FOUND' });
            }

            // 发码 / 绑定 / 收钱这三个共用最紧的一本账:最贵,也最该防爆破。
            // 这里回 200 而不是 429 —— App 靠响应体里的 err 认状态,老版本认不得 429。
            if (route === 'POST /v1/activate') {
                if (limit('write')) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiActivate(await readBody(req)));
            }
            if (route === 'POST /v1/restore') {
                if (limit('write')) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiRestore(await readBody(req)));
            }
            if (route === 'POST /v1/order/create') {
                if (limit('write')) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, await apiOrderCreate(await readBody(req)));
            }
            // renew 每次要签一张通行证(有 CPU 成本),正常一天才一次
            if (route === 'POST /v1/renew') {
                if (limit('renew')) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiRenew(await readBody(req)));
            }
            // 查单是付款页每 2 秒一次的轮询,额度必须给足(见 LIMITS.poll);
            // 真正贵的上游查询另有 confirmPaid 内部的 4.5s/单 节流兜着。
            if (route === 'POST /v1/order/status') {
                if (limit('poll')) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, await apiOrderStatus(await readBody(req)));
            }
            if (route === 'POST /pay/notify') {
                // 虎皮椒回调是表单编码;无论处理结果如何都回 "success" 停止重推,
                // 万一漏单由 App 轮询查单兜底。
                // 限速额度给得松:这是虎皮椒的服务器在推,它会重试最多 6 次,
                // 挡掉一次只是少了个加速信号(闸三会兜住),但挡不住就是个免费的验签打靶场。
                if (limit('read')) {
                    res.writeHead(429, { 'Content-Type': 'text/plain' });
                    return res.end('rate limited');
                }
                await apiPayNotify(Object.fromEntries(new URLSearchParams(await readRaw(req))));
                res.writeHead(200, { 'Content-Type': 'text/plain' });
                return res.end('success');
            }

            return send(res, 404, { ok: false, err: 'NOT_FOUND' });
        } catch (e) {
            log(`ERROR ip=${ip} ${e.message}`);
            return send(res, 400, { ok: false, err: 'BAD_REQUEST' });
        }
    },
);

// 慢连接兜底。Node 默认 requestTimeout 300 秒——一个人挂着半截请求就能白占一条连接 5 分钟,
// 攒够几百条就把服务拖死(slowloris)。本服务所有接口都是几十毫秒级的小请求,收紧无损。
server.requestTimeout = 30_000;
server.headersTimeout = 15_000;
server.keepAliveTimeout = 10_000;
// 连接数上限:超了直接拒新连接。App 轮询每次也就占一条短连,512 远够用;
// 没有这道,连接洪水能把内存撑爆。
server.maxConnections = 512;

server.listen(cfg.port, () => log(`license server listening on :${cfg.port}, db=${cfg.dbPath}, `
    + (PAY_ENABLED ? `pay=xh annual=¥${pricing().annual.priceFen / 100}` : 'pay=disabled')));
