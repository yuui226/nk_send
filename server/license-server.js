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

// ---------------------------------------------------------------- HTTP

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > 8192) { reject(new Error('body too large')); req.destroy(); return; }
            chunks.push(c);
        });
        req.on('end', () => {
            try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
            catch { reject(new Error('bad json')); }
        });
        req.on('error', reject);
    });
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

            return send(res, 404, { ok: false, err: 'NOT_FOUND' });
        } catch (e) {
            log(`ERROR ip=${ip} ${e.message}`);
            return send(res, 400, { ok: false, err: 'BAD_REQUEST' });
        }
    },
);

server.listen(cfg.port, () => log(`license server listening on :${cfg.port}, db=${cfg.dbPath}`));
