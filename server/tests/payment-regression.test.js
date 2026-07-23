'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ztransfer-payment-test-'));
const dbPath = path.join(tempDir, 'license.db');
const signingKeyPath = path.join(tempDir, 'signing.pem');
const configPath = path.join(tempDir, 'config.json');
const pricingPath = path.join(tempDir, 'pricing.json');

const privateKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey;
fs.writeFileSync(signingKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));

// 从旧版订单表启动，真实执行生产迁移，而不是在测试里复制迁移逻辑。
const oldDb = new DatabaseSync(dbPath);
oldDb.exec(`
CREATE TABLE orders (
  out_trade_no TEXT PRIMARY KEY,
  device_fp TEXT NOT NULL,
  amount_fen INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  code TEXT,
  charge_id TEXT,
  pay_url TEXT,
  created_at TEXT NOT NULL,
  paid_at TEXT
);
INSERT INTO orders (out_trade_no, device_fp, amount_fen, created_at)
VALUES ('ZTLEGACY1', '00000000000000000000000000000000', 1990, '2020-01-01T00:00:00.000Z');
`);
oldDb.close();

fs.writeFileSync(configPath, JSON.stringify({
    port: 19443,
    dbPath,
    tlsCertPath: path.join(tempDir, 'unused-cert.pem'),
    tlsKeyPath: path.join(tempDir, 'unused-key.pem'),
    signingKeyPath,
    adminToken: '0123456789abcdef0123456789abcdef',
    xhAppId: 'test-app-id',
    xhAppSecret: 'test-app-secret',
    priceFen: 1990,
    payNotifyUrl: 'https://merchant.invalid/pay/notify',
}));

process.argv[2] = configPath;
const serverModule = require('../license-server.js');
const api = serverModule.__testing;
const db = api.db;

function signed(payload) {
    const result = structuredClone(payload);
    result.hash = api.xhHash(result);
    return result;
}

function feeText(fen) {
    return `${Math.floor(fen / 100)}.${String(fen % 100).padStart(2, '0')}`;
}

function createResponse(order, overrides = {}) {
    return signed({
        errcode: 0,
        errmsg: 'success',
        url: `https://pay.invalid/${order}`,
        url_qrcode: `https://qr.invalid/${order}.png`,
        ...overrides,
    });
}

function queryResponse(order, status = 'WP', overrides = {}) {
    const row = db.prepare('SELECT amount_fen FROM orders WHERE out_trade_no = ?').get(order);
    // 虎皮椒生产查单响应目前不带文档示例中的 hash。
    return {
        errcode: 0,
        errmsg: 'success',
        data: {
            status,
            open_order_id: `XH-${order}`,
            out_trade_order: order,
            total_amount: feeText(row.amount_fen),
            appid: 'test-app-id',
            ...overrides,
        },
    };
}

function installUpstream(statusByOrder = new Map()) {
    let createCalls = 0;
    let queryCalls = 0;
    api.setPaymentPost(async (endpoint, params) => {
        if (endpoint === '/payment/do.html') {
            createCalls++;
            return createResponse(params.trade_order_id);
        }
        queryCalls++;
        return queryResponse(params.out_trade_order,
            statusByOrder.get(params.out_trade_order) || 'WP');
    });
    return {
        get createCalls() { return createCalls; },
        get queryCalls() { return queryCalls; },
    };
}

test.after(() => {
    try { db.close(); } catch { /* already closed */ }
    fs.rmSync(tempDir, { recursive: true, force: true });
});

test('payment regression suite', async (suite) => {
    await suite.test('旧订单迁移为 annual/365，并增加退款状态字段', () => {
        const row = db.prepare(`
            SELECT product, grant_days, refund_reason
            FROM orders WHERE out_trade_no = 'ZTLEGACY1'`).get();
        assert.equal(row.product, 'annual');
        assert.equal(row.grant_days, 365);
        assert.equal(row.refund_reason, null);
        assert.equal(db.prepare('PRAGMA busy_timeout').get().timeout, 5000);
    });

    await suite.test('冷启动定价文件损坏时 fail closed，缺失文件仍兼容默认价格', () => {
        fs.writeFileSync(pricingPath, '{broken');
        assert.deepEqual(api.apiPricing(), { ok: false, err: 'PRICING_UNAVAILABLE' });
        fs.rmSync(pricingPath);
        const fallback = api.apiPricing();
        assert.equal(fallback.price_fen, 1990);
        assert.equal(fallback.products.lifetime.price_fen, 5990);
        assert.equal(fallback.products.lifetime.original_fen, 9990);
    });

    await suite.test('legacy 定价升级保留年费并写入永久默认价', () => {
        fs.writeFileSync(pricingPath, JSON.stringify({ priceFen: 2590, originalFen: 3990 }));
        assert.equal(api.adminSetPricing({
            product: 'annual', price_fen: 2690, original_fen: 3990,
        }).ok, true);
        const stored = JSON.parse(fs.readFileSync(pricingPath, 'utf8'));
        assert.deepEqual(stored.annual, { priceFen: 2690, originalFen: 3990 });
        assert.deepEqual(stored.lifetime, { priceFen: 5990, originalFen: 9990 });
    });

    await suite.test('旧 APK 不传 product 仍只创建 annual，renew 必须是布尔值', async () => {
        const upstream = installUpstream();
        const fp = '11111111111111111111111111111111';
        assert.equal((await api.apiOrderCreate({ fp, renew: 'false' })).err, 'BAD_REQUEST');
        const created = await api.apiOrderCreate({ fp });
        assert.equal(created.ok, true);
        assert.equal(created.product, 'annual');
        assert.equal(created.price_fen, 2690);
        assert.equal(upstream.createCalls, 1);
        const row = db.prepare('SELECT product, grant_days, status FROM orders WHERE out_trade_no = ?')
            .get(created.order);
        assert.deepEqual({ ...row }, { product: 'annual', grant_days: 365, status: 'pending' });
    });

    await suite.test('creating 占位阻止同设备并发请求触达第二次上游建单', async () => {
        const fp = '22222222222222222222222222222222';
        let release;
        let startedResolve;
        const started = new Promise((resolve) => { startedResolve = resolve; });
        let createCalls = 0;
        api.setPaymentPost(async (endpoint, params) => {
            if (endpoint !== '/payment/do.html') return queryResponse(params.out_trade_order);
            createCalls++;
            startedResolve();
            return new Promise((resolve) => { release = () => resolve(createResponse(params.trade_order_id)); });
        });
        const firstPromise = api.apiOrderCreate({ fp, product: 'annual' });
        await started;
        const second = await api.apiOrderCreate({ fp, product: 'lifetime' });
        assert.equal(second.err, 'PENDING_OTHER_PRODUCT');
        assert.equal(createCalls, 1);
        release();
        assert.equal((await firstPromise).ok, true);
    });

    await suite.test('同商品临期订单等待，不同商品立即创建独立订单', async () => {
        const upstream = installUpstream();
        const fp = '33333333333333333333333333333333';
        const createdAt = new Date(Date.now() - 4.5 * 60_000).toISOString();
        db.prepare(`INSERT INTO orders
            (out_trade_no, device_fp, amount_fen, product, grant_days, status, created_at)
            VALUES ('ZTWINDOW1', ?, 2690, 'annual', 365, 'pending', ?)`)
            .run(fp, createdAt);
        const same = await api.apiOrderCreate({ fp, product: 'annual' });
        assert.equal(same.err, 'PENDING_ORDER_ACTIVE');
        assert.ok(same.retry_after_ms > 0);
        assert.equal(same.pay_url, undefined);
        const other = await api.apiOrderCreate({ fp, product: 'lifetime' });
        assert.equal(other.ok, true);
        assert.equal(other.product, 'lifetime');
        assert.equal(upstream.createCalls, 1);
    });

    await suite.test('验签通知绕过 WP 轮询节流，并在事务中只履约一次', async () => {
        const fp = '44444444444444444444444444444444';
        const statuses = new Map();
        const upstream = installUpstream(statuses);
        const created = await api.apiOrderCreate({ fp, product: 'annual' });
        statuses.set(created.order, 'WP');
        assert.equal((await api.apiOrderStatus({ fp, order: created.order })).status, 'pending');
        const beforeNotifyQueries = upstream.queryCalls;
        statuses.set(created.order, 'OD');
        const notification = signed({
            trade_order_id: created.order,
            total_fee: feeText(created.price_fen),
            transaction_id: 'WX-1',
            open_order_id: `XH-${created.order}`,
            order_title: 'ZTransfer Pro 年费版',
            status: 'OD',
            appid: 'test-app-id',
            time: String(Math.floor(Date.now() / 1000)),
            nonce_str: 'notify-1',
        });
        assert.equal((await api.apiPayNotify(notification)).ack, true);
        assert.equal(upstream.queryCalls, beforeNotifyQueries + 1);
        const paid = db.prepare('SELECT status, code FROM orders WHERE out_trade_no = ?')
            .get(created.order);
        assert.equal(paid.status, 'paid');
        assert.ok(paid.code);
        const expiresAt = db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(paid.code).expires_at;
        await api.confirmPaid(created.order, { force: true });
        assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(paid.code).expires_at,
            expiresAt);
    });

    await suite.test('已验签通知未履约或金额不符时不确认', async () => {
        const fp = '55555555555555555555555555555555';
        installUpstream();
        const created = await api.apiOrderCreate({ fp, product: 'annual' });
        const wrongAmount = signed({
            trade_order_id: created.order,
            total_fee: '0.01',
            status: 'OD',
            appid: 'test-app-id',
            time: '1',
            nonce_str: 'notify-2',
        });
        assert.equal((await api.apiPayNotify(wrongAmount)).ack, false);

        api.setPaymentPost(async () => { throw new Error('temporary upstream outage'); });
        const valid = signed({
            trade_order_id: created.order,
            total_fee: feeText(created.price_fen),
            status: 'OD',
            appid: 'test-app-id',
            time: '2',
            nonce_str: 'notify-3',
        });
        assert.equal((await api.apiPayNotify(valid)).ack, false);
        assert.equal(db.prepare('SELECT status FROM orders WHERE out_trade_no = ?')
            .get(created.order).status, 'pending');
    });

    await suite.test('无签名查单只在订单字段全部匹配时履约，坏签名仍 fail closed', async () => {
        const fp = '56565656565656565656565656565656';
        installUpstream();
        const created = await api.apiOrderCreate({ fp, product: 'annual' });

        api.setPaymentPost(async () => ({
            ...queryResponse(created.order, 'OD'),
            hash: 'bad',
        }));
        assert.equal((await api.confirmPaid(created.order, { force: true })).status, 'pending');

        api.setPaymentPost(async () => queryResponse(created.order, 'OD', {
            total_amount: '0.01',
        }));
        assert.equal((await api.confirmPaid(created.order, { force: true })).status, 'pending');

        api.setPaymentPost(async () => queryResponse(created.order, 'OD', {
            out_trade_order: 'ZTWRONGORDER',
        }));
        assert.equal((await api.confirmPaid(created.order, { force: true })).status, 'pending');

        api.setPaymentPost(async () => queryResponse(created.order, 'OD', {
            appid: 'wrong-app-id',
        }));
        assert.equal((await api.confirmPaid(created.order, { force: true })).status, 'pending');

        api.setPaymentPost(async () => queryResponse(created.order, 'OD', {
            open_order_id: '',
        }));
        assert.equal((await api.confirmPaid(created.order, { force: true })).status, 'pending');

        api.setPaymentPost(async () => queryResponse(created.order, 'OD'));
        const paid = await api.confirmPaid(created.order, { force: true });
        assert.equal(paid.status, 'paid');
        assert.ok(paid.code);
    });

    await suite.test('无效上游签名或非 HTTPS 支付链接 fail closed', async () => {
        const fp1 = '66666666666666666666666666666666';
        api.setPaymentPost(async (endpoint, params) => ({
            errcode: 0,
            url: `https://pay.invalid/${params.trade_order_id}`,
            hash: 'bad',
        }));
        assert.equal((await api.apiOrderCreate({ fp: fp1, product: 'annual' })).err,
            'PAY_UPSTREAM');

        const fp2 = '77777777777777777777777777777777';
        api.setPaymentPost(async (endpoint, params) => createResponse(params.trade_order_id, {
            url: 'http://insecure.invalid/pay',
            url_qrcode: '',
        }));
        assert.equal((await api.apiOrderCreate({ fp: fp2, product: 'annual' })).err,
            'PAY_UPSTREAM');
    });

    await suite.test('年费后购买永久另发新码，原年费码保持有效', async () => {
        const fp = '99999999999999999999999999999999';
        const code = 'BCDEFG';
        const annualExpiry = new Date(Date.now() + 86_400_000).toISOString();
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, 'test-separate-lifetime', new Date().toISOString(), annualExpiry);
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(code, fp, new Date().toISOString());
        const statuses = new Map();
        installUpstream(statuses);
        const lifetime = await api.apiOrderCreate({ fp, product: 'lifetime', renew: true });
        assert.equal(lifetime.renew, false);
        statuses.set(lifetime.order, 'OD');
        const fulfilled = await api.confirmPaid(lifetime.order, { force: true });
        assert.notEqual(fulfilled.code, code);
        assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(code).expires_at,
            annualExpiry);
        assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?')
            .get(fulfilled.code).expires_at, null);
    });

    await suite.test('年费与永久二维码分别付款时各自自然发码', async () => {
        const fp = '36363636363636363636363636363636';
        const statuses = new Map();
        installUpstream(statuses);
        const annual = await api.apiOrderCreate({ fp, product: 'annual' });
        const lifetime = await api.apiOrderCreate({ fp, product: 'lifetime' });
        assert.equal(annual.ok, true);
        assert.equal(lifetime.ok, true);
        statuses.set(annual.order, 'OD');
        statuses.set(lifetime.order, 'OD');
        const annualPaid = await api.confirmPaid(annual.order, { force: true });
        const lifetimePaid = await api.confirmPaid(lifetime.order, { force: true });
        assert.notEqual(annualPaid.code, lifetimePaid.code);
        assert.equal(annualPaid.status, 'paid');
        assert.equal(lifetimePaid.status, 'paid');
        assert.ok(db.prepare('SELECT expires_at FROM codes WHERE code = ?')
            .get(annualPaid.code).expires_at);
        assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?')
            .get(lifetimePaid.code).expires_at, null);
    });

    await suite.test('旧年费单在权益变永久后付款，持久标记退款', async () => {
        const fp = '88888888888888888888888888888888';
        const code = 'ABCDEF';
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, 'test-upgrade', new Date().toISOString(),
                new Date(Date.now() + 86_400_000).toISOString());
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(code, fp, new Date().toISOString());

        const statuses = new Map();
        installUpstream(statuses);
        const annual = await api.apiOrderCreate({ fp, product: 'annual', renew: true });
        assert.equal(annual.ok, true);
        // 模拟另一条已完成的永久升级在这张旧年费二维码付款前生效。
        db.prepare('UPDATE codes SET expires_at = NULL WHERE code = ?').run(code);
        statuses.set(annual.order, 'OD');
        const fulfilled = await api.confirmPaid(annual.order, { force: true });
        assert.equal(fulfilled.status, 'refund_required');
        assert.equal(fulfilled.code, code);
        assert.equal(fulfilled.refund_reason, 'annual_payment_after_permanent_upgrade');
        const appStatus = await api.apiOrderStatus({ fp, order: annual.order });
        assert.equal(appStatus.status, 'paid'); // 旧 APK 仍能结束付款流程
        assert.equal(appStatus.refund_required, true);
        const ledger = api.adminListCodes();
        const refund = ledger.refund_required.find((item) => item.out_trade_no === annual.order);
        assert.equal(refund.product, 'annual');
        assert.equal(refund.amount_fen, annual.price_fen);
        assert.equal(refund.refund_reason, 'annual_payment_after_permanent_upgrade');
    });
});
