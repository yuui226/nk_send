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

// ---------------------------------------------------------------- 数据库

const db = new DatabaseSync(cfg.dbPath);
db.exec(`
CREATE TABLE IF NOT EXISTS codes (
  code          TEXT PRIMARY KEY,
  status        TEXT NOT NULL DEFAULT 'active',
  max_devices   INTEGER NOT NULL DEFAULT 2,
  note          TEXT,
  created_at    TEXT NOT NULL,
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
CREATE TABLE IF NOT EXISTS orders (
  out_trade_no TEXT PRIMARY KEY,
  device_fp    TEXT NOT NULL,
  amount_fen   INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',  -- pending / paid
  code         TEXT,
  charge_id    TEXT,
  pay_url      TEXT,
  created_at   TEXT NOT NULL,
  paid_at      TEXT
);
CREATE INDEX IF NOT EXISTS idx_orders_fp ON orders(device_fp);
`);

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

// 通行证:base64url(payload JSON) + "." + base64url(ECDSA P-256 DER 签名)
function issueToken(code, fp) {
    const payload = Buffer.from(JSON.stringify({
        v: 1, code, fp, plan: 'pro', iat: Math.floor(Date.now() / 1000),
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

// /v1/activate 简单限速:每 IP 每分钟 10 次(防爆破加保险,码空间本身不可爆破)
const rateBuckets = new Map();
function rateLimited(ip) {
    const t = Date.now(), windowMs = 60_000, max = 10;
    const arr = (rateBuckets.get(ip) || []).filter((x) => t - x < windowMs);
    arr.push(t);
    rateBuckets.set(ip, arr);
    if (rateBuckets.size > 10_000) rateBuckets.clear(); // 内存兜底,正常永远到不了
    return arr.length > max;
}

// ---------------------------------------------------------------- 业务

function apiActivate(body) {
    const code = normCode(body.code), fp = String(body.fp || '').toLowerCase();
    if (!CODE_RE.test(code) || !FP_RE.test(fp)) return { ok: false, err: 'CODE_NOT_FOUND' };

    const row = db.prepare('SELECT status, max_devices FROM codes WHERE code = ?').get(code);
    if (!row) return { ok: false, err: 'CODE_NOT_FOUND' };
    if (row.status !== 'active') return { ok: false, err: 'CODE_REVOKED' };

    const bound = db.prepare('SELECT id FROM bindings WHERE code = ? AND device_fp = ?').get(code, fp);
    if (bound) {
        // 幂等:同一设备重复激活(卸载重装)直接重发通行证
        db.prepare('UPDATE bindings SET last_renew_at = ?, app_ver = ? WHERE id = ?')
            .run(now(), String(body.app_ver || ''), bound.id);
        return { ok: true, token: issueToken(code, fp) };
    }

    const used = db.prepare('SELECT COUNT(*) AS n FROM bindings WHERE code = ?').get(code).n;
    if (used >= row.max_devices) return { ok: false, err: 'SLOTS_FULL' };

    db.prepare(`INSERT INTO bindings (code, device_fp, device_model, app_ver, activated_at, last_renew_at)
                VALUES (?, ?, ?, ?, ?, ?)`)
        .run(code, fp, String(body.model || ''), String(body.app_ver || ''), now(), now());
    log(`ACTIVATE ${code} fp=${fp.slice(0, 8)} model=${body.model || '-'} (${used + 1}/${row.max_devices})`);
    return { ok: true, token: issueToken(code, fp) };
}

function apiRenew(body) {
    const code = normCode(body.code), fp = String(body.fp || '').toLowerCase();
    if (!CODE_RE.test(code) || !FP_RE.test(fp)) return { ok: false, err: 'NOT_BOUND' };

    const row = db.prepare('SELECT status FROM codes WHERE code = ?').get(code);
    if (!row) return { ok: false, err: 'NOT_BOUND' };
    if (row.status !== 'active') return { ok: false, err: 'CODE_REVOKED' };

    const bound = db.prepare('SELECT id FROM bindings WHERE code = ? AND device_fp = ?').get(code, fp);
    if (!bound) return { ok: false, err: 'NOT_BOUND' };

    db.prepare('UPDATE bindings SET last_renew_at = ?, app_ver = ? WHERE id = ?')
        .run(now(), String(body.app_ver || ''), bound.id);
    return { ok: true, token: issueToken(code, fp) };
}

function adminNewCodes(body) {
    const count = Math.min(Math.max(parseInt(body.count, 10) || 1, 1), 100);
    const maxDevices = Math.min(Math.max(parseInt(body.max_devices, 10) || 2, 1), 10);
    const note = String(body.note || '');
    const ins = db.prepare('INSERT INTO codes (code, max_devices, note, created_at) VALUES (?, ?, ?, ?)');
    const codes = [];
    while (codes.length < count) {
        const c = newCode();
        try { ins.run(c, maxDevices, note, now()); codes.push(c); }
        catch (e) { if (!String(e.message).includes('UNIQUE')) throw e; } // 撞码重试(概率 ~0)
    }
    log(`NEW_CODES x${count} note="${note}"`);
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
    return {
        ok: true,
        codes: codes.map((c) => ({
            code: c.code, status: c.status, max_devices: c.max_devices, note: c.note,
            created_at: c.created_at, revoked_at: c.revoked_at, revoke_reason: c.revoke_reason,
            bindings: byCode.get(c.code) || [],
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

function newOrderId() {
    // ZT + 毫秒时间戳36进制 + 4位随机,全大写字母数字,唯一性由 PRIMARY KEY 兜底
    return 'ZT' + Date.now().toString(36).toUpperCase()
        + crypto.randomInt(36 ** 4).toString(36).toUpperCase().padStart(4, '0');
}

async function apiOrderCreate(body) {
    if (!PAY_ENABLED) return { ok: false, err: 'PAY_DISABLED' };
    const fp = String(body.fp || '').toLowerCase();
    if (!FP_RE.test(fp)) return { ok: false, err: 'BAD_REQUEST' };

    // 顺手清理超过 7 天仍未支付的死单
    db.prepare("DELETE FROM orders WHERE status = 'pending' AND created_at < ?")
        .run(new Date(Date.now() - 7 * 24 * 3600_000).toISOString());

    // 同设备 15 分钟内的未支付订单直接复用,反复点购买不会刷出一堆新单
    // (窗口对齐虎皮椒收银台链接的短有效期,过期就换新单新链接)
    const pending = db.prepare(`SELECT out_trade_no, pay_url FROM orders
                                WHERE device_fp = ? AND status = 'pending' AND created_at > ?
                                ORDER BY created_at DESC`)
        .get(fp, new Date(Date.now() - 15 * 60_000).toISOString());
    if (pending) return { ok: true, order: pending.out_trade_no, pay_url: pending.pay_url };

    const order = newOrderId();
    let resp;
    try {
        resp = await xhPost('/payment/do.html', {
            version: '1.1',
            trade_order_id: order,
            total_fee: (cfg.priceFen / 100).toFixed(2),   // 虎皮椒金额单位为元
            title: 'ZTransfer Pro',
            notify_url: cfg.payNotifyUrl,
        });
    } catch (e) {
        log(`ORDER_UPSTREAM_FAIL ${e.message}`);
        return { ok: false, err: 'PAY_UPSTREAM' };
    }
    if (Number(resp.errcode) !== 0 || !resp.url) {
        log(`ORDER_CREATE_REJECTED ${resp.errmsg || JSON.stringify(resp).slice(0, 200)}`);
        return { ok: false, err: 'PAY_UPSTREAM' };
    }
    db.prepare(`INSERT INTO orders (out_trade_no, device_fp, amount_fen, pay_url, created_at)
                VALUES (?, ?, ?, ?, ?)`)
        .run(order, fp, cfg.priceFen, resp.url, now());
    log(`ORDER_NEW ${order} fp=${fp.slice(0, 8)} ¥${cfg.priceFen / 100}`);
    return { ok: true, order, pay_url: resp.url };
}

// 对上游查单限频:同一订单 4.5s 内只查一次。App 轮询 2s,叠加节流后实际上游
// 频率约 6s 一次,落在虎皮椒官方建议的 5-10s 区间内;notify 到达时可再快一拍。
const orderCheckAt = new Map();

/** 向虎皮椒确认支付;确认到账则发码(幂等:一单永远只发同一个码)。返回最新订单行。 */
async function confirmPaid(order) {
    let row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
    if (!row || row.code) return row;

    const last = orderCheckAt.get(order) || 0;
    if (Date.now() - last < 4500) return row;
    orderCheckAt.set(order, Date.now());
    if (orderCheckAt.size > 10_000) orderCheckAt.clear(); // 同 rateBuckets 的内存兜底

    let q;
    try {
        q = await xhPost('/payment/query.html', { out_trade_order: order });
    } catch (e) {
        log(`ORDER_QUERY_FAIL ${order} ${e.message}`);
        return row;
    }
    // data.status: WP待支付 OD已支付 CD已取消;仅 OD 发码
    if (Number(q.errcode) !== 0 || !q.data || q.data.status !== 'OD') return row;

    // await 之后重读再发码;以下全部为同步语句,单线程下不会与并发确认交错出双码
    row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
    if (!row || row.code) return row;
    const ins = db.prepare('INSERT INTO codes (code, max_devices, note, created_at) VALUES (?, 2, ?, ?)');
    let code;
    for (;;) {
        code = newCode();
        try { ins.run(code, `xh:${order}`, now()); break; }
        catch (e) { if (!String(e.message).includes('UNIQUE')) throw e; } // 撞码重试(概率 ~0)
    }
    db.prepare(`UPDATE orders SET status = 'paid', code = ?, charge_id = ?, paid_at = ?
                WHERE out_trade_no = ?`)
        .run(code, String(q.data.open_order_id || ''), now(), order);
    log(`ORDER_PAID ${order} code=${code} xh=${q.data.open_order_id || '-'}`);
    return db.prepare('SELECT * FROM orders WHERE out_trade_no = ?').get(order);
}

async function apiOrderStatus(body) {
    if (!PAY_ENABLED) return { ok: false, err: 'PAY_DISABLED' };
    const fp = String(body.fp || '').toLowerCase();
    const order = String(body.order || '');
    if (!FP_RE.test(fp) || !/^ZT[A-Z0-9]{4,20}$/.test(order)) return { ok: false, err: 'BAD_REQUEST' };

    let row = db.prepare('SELECT * FROM orders WHERE out_trade_no = ? AND device_fp = ?').get(order, fp);
    if (!row) return { ok: false, err: 'NOT_FOUND' };
    if (!row.code) row = await confirmPaid(order) || row;

    if (row.code) return { ok: true, status: 'paid', code: row.code };
    // want_url:App 重进购买页续用旧单时才要支付链接,常规轮询不带。
    // 超过 15 分钟的旧链接可能已过期,不再给出——App 拿不到链接会自行新建订单。
    const out = { ok: true, status: 'pending' };
    if (body.want_url && row.created_at > new Date(Date.now() - 15 * 60_000).toISOString()) {
        out.pay_url = row.pay_url;
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
        log(`NOTIFY_REFUND ${order} status=${params.status}`);
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

const server = https.createServer(
    { cert: fs.readFileSync(cfg.tlsCertPath), key: fs.readFileSync(cfg.tlsKeyPath) },
    async (req, res) => {
        const ip = req.socket.remoteAddress || '?';
        try {
            const url = new URL(req.url, 'https://x');
            const route = `${req.method} ${url.pathname}`;

            if (route === 'GET /healthz') return send(res, 200, { ok: true });

            if (url.pathname.startsWith('/admin/')) {
                if (!constantTimeEq(req.headers['x-admin-token'] || '', cfg.adminToken)) {
                    log(`ADMIN_DENIED ${route} ip=${ip}`);
                    return send(res, 401, { ok: false, err: 'UNAUTHORIZED' });
                }
                if (route === 'POST /admin/codes') return send(res, 200, adminNewCodes(await readBody(req)));
                if (route === 'GET /admin/codes') return send(res, 200, adminListCodes());
                if (route === 'POST /admin/unbind') return send(res, 200, adminUnbind(await readBody(req)));
                if (route === 'POST /admin/revoke') return send(res, 200, adminRevoke(await readBody(req)));
                return send(res, 404, { ok: false, err: 'NOT_FOUND' });
            }

            if (route === 'POST /v1/activate') {
                if (rateLimited(ip)) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, apiActivate(await readBody(req)));
            }
            if (route === 'POST /v1/renew') return send(res, 200, apiRenew(await readBody(req)));

            // 购买下单与限速共用一本账(下单也是敏感写操作);轮询查单不限速,
            // 上游查询频率由 confirmPaid 内部的 2.5s 节流兜住。
            if (route === 'POST /v1/order/create') {
                if (rateLimited(ip)) return send(res, 200, { ok: false, err: 'RATE_LIMITED' });
                return send(res, 200, await apiOrderCreate(await readBody(req)));
            }
            if (route === 'POST /v1/order/status') return send(res, 200, await apiOrderStatus(await readBody(req)));
            if (route === 'POST /pay/notify') {
                // 虎皮椒回调是表单编码;无论处理结果如何都回 "success" 停止重推,
                // 万一漏单由 App 轮询查单兜底。
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

server.listen(cfg.port, () => log(`license server listening on :${cfg.port}, db=${cfg.dbPath}, `
    + (PAY_ENABLED ? `pay=xh ¥${cfg.priceFen / 100}` : 'pay=disabled')));
