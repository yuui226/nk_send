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

function requestId(n) {
    return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
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

test('OSS 更新地址只接受 apk.ztransfer.top 下的永久版本 APK', () => {
    const status = api.adminGetUpdate();
    assert.equal(status.publishProtocol, 3);
    assert.equal(status.ossUpdateHost, 'apk.ztransfer.top');
    assert.equal(
        api.isOssReleaseUrl('https://apk.ztransfer.top/releases/ZTransfer-v1.57-a1b2c3d4e5f6.apk'),
        true,
    );
    // 已上传或发布的旧 versionCode 命名对象继续允许读取，不影响历史版本。
    assert.equal(
        api.isOssReleaseUrl('https://apk.ztransfer.top/releases/ZTransfer-v27-a1b2c3d4e5f6.apk'),
        true,
    );
    for (const url of [
        'http://apk.ztransfer.top/releases/ZTransfer-v27-a.apk',
        'https://apk.ztransfer.top:8443/releases/ZTransfer-v27-a1b2c3d4e5f6.apk',
        'https://ztransfer.oss-cn-hongkong.aliyuncs.com/releases/ZTransfer-v27-a.apk',
        'https://apk.ztransfer.top/ZTransfer.apk',
        'https://apk.ztransfer.top/releases/other.apk',
        'https://apk.ztransfer.top/releases/ZTransfer-v27-a.apk',
        'https://apk.ztransfer.top/releases/ZTransfer-v27-a.bin',
        'https://apk.ztransfer.top/releases/ZTransfer-v27-a.apk?Expires=123',
        'https://apk.ztransfer.top/releases/ZTransfer-v1..57-a1b2c3d4e5f6.apk',
    ]) {
        assert.equal(api.isOssReleaseUrl(url), false, url);
    }
});

test('OSS 更新地址直接下发，不调用蓝奏云解析', async () => {
    const url = 'https://apk.ztransfer.top/releases/ZTransfer-v1.57-a1b2c3d4e5f6.apk';
    assert.deepEqual(
        await api.resolveReleaseDownload({ url, password: '' }),
        { url, source: 'OSS' },
    );

    const legacyUrl = 'https://ztransfer.oss-cn-beijing.aliyuncs.com/releases/ZTransfer-v26-7d30093f669c.bin';
    assert.deepEqual(
        await api.resolveReleaseDownload({ url: legacyUrl, password: '' }),
        { url: legacyUrl, source: 'OSS_LEGACY' },
    );
});

test('OSS 发布元数据必须与版本化文件名严格一致', () => {
    const sha256 = 'a1b2c3d4e5f6' + '0'.repeat(52);
    const valid = {
        versionCode: 27,
        versionName: '1.57',
        url: 'https://apk.ztransfer.top/releases/ZTransfer-v1.57-a1b2c3d4e5f6.apk',
        password: '',
        sha256,
        sizeBytes: 2_018_435,
    };
    assert.equal(api.isOssReleaseMetadataValid(valid), true);
    for (const override of [
        { versionName: ' ' },
        { versionName: '1.58' },
        { sha256: 'b'.repeat(64) },
        { sha256: '' },
        { sizeBytes: 0 },
        { password: 'legacy' },
    ]) {
        assert.equal(api.isOssReleaseMetadataValid({ ...valid, ...override }), false);
    }
    assert.equal(
        api.adminPublishUpdate({ ...valid, sha256: 'b'.repeat(64) }).err,
        'OSS_METADATA_MISMATCH',
    );
});

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
    await suite.test('旧订单迁移为 annual/365，增加请求号并移除废弃退款字段', () => {
        const row = db.prepare(`
            SELECT product, grant_days, request_id
            FROM orders WHERE out_trade_no = 'ZTLEGACY1'`).get();
        assert.equal(row.product, 'annual');
        assert.equal(row.grant_days, 365);
        assert.equal(row.request_id, null);
        const columns = db.prepare('PRAGMA table_info(orders)').all().map((item) => item.name);
        assert.equal(columns.includes('refund_reason'), false);
        const indexes = db.prepare("SELECT name FROM sqlite_master WHERE type = 'index'").all()
            .map((item) => item.name);
        assert.equal(indexes.includes('idx_orders_creating_fp'), false);
        assert.equal(indexes.includes('idx_orders_fp'), false);
        assert.equal(indexes.includes('idx_orders_request_id'), true);
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

    await suite.test('旧版全零共享指纹仍可正常付款发新码，绝不返回历史码', async () => {
        const fp = '793843504c099edbb6c7d97dad20313f';
        const oldCode = 'ACDEFG';
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(oldCode, 'old-zero-id-owner', new Date().toISOString(), null);
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(oldCode, fp, new Date().toISOString());
        const statuses = new Map();
        installUpstream(statuses);

        const created = await api.apiOrderCreate({ fp, product: 'annual' });
        assert.equal(created.ok, true);
        assert.ok(created.order);
        assert.equal(created.code, undefined);
        assert.equal(created.token, undefined);
        statuses.set(created.order, 'OD');
        const paid = await api.confirmPaid(created.order, { force: true });
        assert.equal(paid.status, 'paid');
        assert.notEqual(paid.code, oldCode);
    });

    await suite.test('年费续原码必须明确提交激活码，缺码则新购而不按设备指纹推断', async () => {
        const fp = '12121212121212121212121212121212';
        const code = 'ABCDGH';
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, 'explicit-renew', new Date().toISOString(),
                new Date(Date.now() + 86_400_000).toISOString());
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(code, fp, new Date().toISOString());
        const statuses = new Map();
        installUpstream(statuses);

        const missing = await api.apiOrderCreate({
            fp, product: 'annual', renew: true, request_id: requestId(7),
        });
        assert.equal(missing.ok, true);
        assert.equal(missing.renew, false);
        assert.equal(db.prepare('SELECT renew_code FROM orders WHERE out_trade_no = ?')
            .get(missing.order).renew_code, null);
        statuses.set(missing.order, 'OD');
        const newlyPaid = await api.confirmPaid(missing.order, { force: true });
        assert.equal(newlyPaid.status, 'paid');
        assert.notEqual(newlyPaid.code, code);
        const explicit = await api.apiOrderCreate({
            fp, product: 'annual', renew: true, renew_code: code, request_id: requestId(5),
        });
        assert.equal(explicit.ok, true);
        assert.equal(explicit.renew, true);
        assert.equal(db.prepare('SELECT renew_code FROM orders WHERE out_trade_no = ?')
            .get(explicit.order).renew_code, code);
        db.prepare('UPDATE codes SET expires_at = ? WHERE code = ?')
            .run(new Date(Date.now() - 1000).toISOString(), code);
        statuses.set(explicit.order, 'OD');
        const paidAfterExpiry = await api.confirmPaid(explicit.order, { force: true });
        assert.notEqual(paidAfterExpiry.code, code);
        assert.equal(paidAfterExpiry.renew_code, null);

        const expiredCode = 'BCDEGH';
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(expiredCode, 'expired-renew', new Date().toISOString(),
                new Date(Date.now() - 86_400_000).toISOString());
        const expired = await api.apiOrderCreate({
            fp, product: 'annual', renew: true, renew_code: expiredCode, request_id: requestId(8),
        });
        assert.equal(expired.ok, true);
        assert.equal(expired.renew, false);
        statuses.set(expired.order, 'OD');
        const expiredPaid = await api.confirmPaid(expired.order, { force: true });
        assert.notEqual(expiredPaid.code, expiredCode);
    });

    await suite.test('同一随机请求号并发只触达一次上游建单', async () => {
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
        const rid = requestId(1);
        const firstPromise = api.apiOrderCreate({ fp, product: 'annual', request_id: rid });
        await started;
        const second = await api.apiOrderCreate({ fp, product: 'annual', request_id: rid });
        assert.equal(second.err, 'ORDER_CREATING');
        assert.equal(createCalls, 1);
        release();
        assert.equal((await firstPromise).ok, true);
    });

    await suite.test('订单复用只认随机请求号，相同设备指纹的另一请求完全独立', async () => {
        const upstream = installUpstream();
        const fp = '33333333333333333333333333333333';
        const createdAt = new Date(Date.now() - 5.5 * 60_000).toISOString();
        db.prepare(`INSERT INTO orders
            (out_trade_no, device_fp, amount_fen, product, grant_days, status, request_id, created_at)
            VALUES ('ZTWINDOW1', ?, 2690, 'annual', 365, 'pending', ?, ?)`)
            .run(fp, requestId(2), createdAt);
        const same = await api.apiOrderCreate({
            fp, product: 'annual', request_id: requestId(2),
        });
        assert.equal(same.err, 'PENDING_ORDER_ACTIVE');
        assert.ok(same.retry_after_ms > 0);
        assert.equal(same.pay_url, undefined);
        const other = await api.apiOrderCreate({
            fp, product: 'annual', request_id: requestId(3),
        });
        assert.equal(other.ok, true);
        assert.equal(other.product, 'annual');
        assert.equal(upstream.createCalls, 1);
    });

    await suite.test('验签通知绕过 WP 轮询节流，并在事务中只履约一次', async () => {
        const fp = '44444444444444444444444444444444';
        const statuses = new Map();
        const upstream = installUpstream(statuses);
        const rid = requestId(6);
        const created = await api.apiOrderCreate({ fp, product: 'annual', request_id: rid });
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
        const binding = db.prepare('SELECT device_fp FROM bindings WHERE code = ?').get(paid.code);
        assert.equal(binding.device_fp, fp);
        assert.equal(db.prepare('SELECT COUNT(*) AS n FROM activations WHERE code = ?')
            .get(paid.code).n, 1);
        const retriedCreate = await api.apiOrderCreate({
            fp, product: 'annual', request_id: rid,
        });
        assert.equal(retriedCreate.status, 'paid');
        assert.equal(retriedCreate.code, paid.code);
        assert.ok(retriedCreate.token);
        const status = await api.apiOrderStatus({
            fp,
            order: created.order,
            model: 'Test Phone',
            app_ver: '9.9',
        });
        assert.equal(status.status, 'paid');
        assert.ok(status.token);
        const tokenPayload = JSON.parse(Buffer.from(status.token.split('.')[0], 'base64url'));
        assert.equal(tokenPayload.code, paid.code);
        assert.equal(tokenPayload.fp, fp);
        const bindingMetadata = db.prepare(
            'SELECT device_model, app_ver FROM bindings WHERE code = ? AND device_fp = ?'
        ).get(paid.code, fp);
        assert.deepEqual({ ...bindingMetadata }, { device_model: 'Test Phone', app_ver: '9.9' });
        assert.equal(api.adminListCodes().paid_unbound.length, 0);
        const expiresAt = db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(paid.code).expires_at;
        await api.confirmPaid(created.order, { force: true });
        assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(paid.code).expires_at,
            expiresAt);
        assert.equal(db.prepare('SELECT COUNT(*) AS n FROM bindings WHERE code = ?').get(paid.code).n, 1);
        assert.equal(db.prepare('SELECT COUNT(*) AS n FROM activations WHERE code = ?')
            .get(paid.code).n, 1);
    });

    await suite.test('首次绑定写入失败时发码与 paid 标记一并回滚', async () => {
        const fp = '45454545454545454545454545454545';
        const statuses = new Map();
        installUpstream(statuses);
        const created = await api.apiOrderCreate({ fp, product: 'annual' });
        db.exec(`CREATE TRIGGER test_fail_paid_binding
                 BEFORE INSERT ON bindings
                 WHEN NEW.device_fp = '${fp}'
                 BEGIN SELECT RAISE(ABORT, 'test binding failure'); END;`);
        try {
            statuses.set(created.order, 'OD');
            const result = await api.confirmPaid(created.order, { force: true });
            assert.equal(result.status, 'pending');
            assert.equal(result.code, null);
            assert.equal(db.prepare('SELECT COUNT(*) AS n FROM codes WHERE note = ?')
                .get(`xh:${created.order}`).n, 0);
            assert.equal(db.prepare('SELECT COUNT(*) AS n FROM bindings WHERE device_fp = ?')
                .get(fp).n, 0);
        } finally {
            db.exec('DROP TRIGGER test_fail_paid_binding');
        }
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

    await suite.test('续费只延期，不改变付款期间已发生的换机绑定', async () => {
        const originalFp = '91919191919191919191919191919191';
        const switchedFp = '92929292929292929292929292929292';
        const code = 'CDEFGH';
        const originalExpiry = new Date(Date.now() + 86_400_000).toISOString();
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, 'test-renew-no-rebind', new Date().toISOString(), originalExpiry);
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(code, originalFp, new Date().toISOString());
        const statuses = new Map();
        installUpstream(statuses);
        const renewal = await api.apiOrderCreate({
            fp: originalFp, product: 'annual', renew: true, renew_code: code,
        });
        db.prepare('UPDATE bindings SET device_fp = ? WHERE code = ?').run(switchedFp, code);
        statuses.set(renewal.order, 'OD');
        const fulfilled = await api.confirmPaid(renewal.order, { force: true });
        assert.equal(fulfilled.code, code);
        assert.equal(db.prepare('SELECT device_fp FROM bindings WHERE code = ?').get(code).device_fp,
            switchedFp);
        assert.ok(db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(code).expires_at
            > originalExpiry);
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

    await suite.test('同一设备已有多张码时新购买仍不返回任何旧码', async () => {
        const fp = '37373737373737373737373737373737';
        const statuses = new Map();
        installUpstream(statuses);

        // 用户先生成永久二维码，又改选年费；两张二维码随后都被付款。
        const lifetime = await api.apiOrderCreate({ fp, product: 'lifetime' });
        const annual = await api.apiOrderCreate({ fp, product: 'annual' });
        statuses.set(lifetime.order, 'OD');
        statuses.set(annual.order, 'OD');
        const lifetimePaid = await api.confirmPaid(lifetime.order, { force: true });
        const annualPaid = await api.confirmPaid(annual.order, { force: true });

        const next = await api.apiOrderCreate({
            fp, product: 'annual', request_id: requestId(4),
        });
        assert.equal(next.ok, true);
        assert.ok(next.order);
        assert.equal(next.code, undefined);
        assert.equal(next.token, undefined);
        assert.notEqual(next.order, annual.order);
        assert.notEqual(next.order, lifetime.order);
    });

    await suite.test('旧年费单在原码变永久后付款，仍按新购交付一张新年费码', async () => {
        const fp = '88888888888888888888888888888888';
        const code = 'ABCDEF';
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, 'test-upgrade', new Date().toISOString(),
                new Date(Date.now() + 86_400_000).toISOString());
        db.prepare('INSERT INTO bindings (code, device_fp, activated_at) VALUES (?, ?, ?)')
            .run(code, fp, new Date().toISOString());

        const statuses = new Map();
        installUpstream(statuses);
        const annual = await api.apiOrderCreate({
            fp, product: 'annual', renew: true, renew_code: code,
        });
        assert.equal(annual.ok, true);
        // 原续费目标已不可续，到账后仍遵守“一笔付款交付一份权益”，按新购发码。
        db.prepare('UPDATE codes SET expires_at = NULL WHERE code = ?').run(code);
        statuses.set(annual.order, 'OD');
        const fulfilled = await api.confirmPaid(annual.order, { force: true });
        assert.equal(fulfilled.status, 'paid');
        assert.notEqual(fulfilled.code, code);
        assert.equal(fulfilled.renew_code, null);
        const appStatus = await api.apiOrderStatus({ fp, order: annual.order });
        assert.equal(appStatus.status, 'paid');
        assert.equal(appStatus.code, fulfilled.code);
    });

    await suite.test('管理台暴露任何历史已付款未绑定异常', () => {
        const code = 'DEFGHJ';
        const order = 'ZTUNBOUND1';
        const previouslyBoundCode = 'EFGHJK';
        const previouslyBoundOrder = 'ZTUNBOUND2';
        const paidAt = new Date(Date.now() - 120_000).toISOString();
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(code, `xh:${order}`, paidAt, new Date(Date.now() + 86_400_000).toISOString());
        db.prepare(`INSERT INTO orders
                    (out_trade_no, device_fp, amount_fen, product, grant_days, status,
                     code, created_at, paid_at)
                    VALUES (?, ?, 2690, 'annual', 365, 'paid', ?, ?, ?)`)
            .run(order, '93939393939393939393939393939393', code, paidAt, paidAt);
        // 有激活历史但当前无 binding 代表人工解绑/正常换机过程，不是“付款从未交付”。
        db.prepare('INSERT INTO codes (code, note, created_at, expires_at) VALUES (?, ?, ?, ?)')
            .run(previouslyBoundCode, `xh:${previouslyBoundOrder}`, paidAt,
                new Date(Date.now() + 86_400_000).toISOString());
        db.prepare(`INSERT INTO orders
                    (out_trade_no, device_fp, amount_fen, product, grant_days, status,
                     code, created_at, paid_at)
                    VALUES (?, ?, 2690, 'annual', 365, 'paid', ?, ?, ?)`)
            .run(previouslyBoundOrder, '94949494949494949494949494949494',
                previouslyBoundCode, paidAt, paidAt);
        db.prepare(`INSERT INTO activations
                    (code, device_fp, device_model, app_ver, at)
                    VALUES (?, ?, 'Old Phone', '1.0', ?)`)
            .run(previouslyBoundCode, '94949494949494949494949494949494', paidAt);
        const anomalies = api.adminListCodes().paid_unbound;
        const anomaly = anomalies.find((item) => item.out_trade_no === order);
        assert.equal(anomaly.code, code);
        assert.equal(anomalies.some((item) => item.out_trade_no === previouslyBoundOrder), false);
    });
});
