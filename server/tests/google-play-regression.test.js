'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ztransfer-google-play-test-'));
const dbPath = path.join(tempDir, 'license.db');
const signingKeyPath = path.join(tempDir, 'signing.pem');
const configPath = path.join(tempDir, 'config.json');
const privateKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey;
fs.writeFileSync(signingKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));
fs.writeFileSync(configPath, JSON.stringify({
    port: 19444,
    dbPath,
    tlsCertPath: path.join(tempDir, 'unused-cert.pem'),
    tlsKeyPath: path.join(tempDir, 'unused-key.pem'),
    signingKeyPath,
    adminToken: '0123456789abcdef0123456789abcdef',
    googlePlay: {
        packageName: 'com.ztransfer.play',
        pubsubAudience: 'https://license.invalid/google-play/rtdn',
        pubsubServiceAccountEmail: 'push@example.iam.gserviceaccount.com',
    },
}));

process.argv[2] = configPath;
const api = require('../license-server.js').__testing;
const db = api.db;

const fp1 = '11111111111111111111111111111111';
const fp2 = '22222222222222222222222222222222';
let nextPurchase;
let acknowledgeCount = 0;
let voided = [];
const client = {
    async verifyProduct(productId, purchaseToken) {
        return {
            kind: 'inapp',
            productId,
            purchaseToken,
            orderId: `order-${purchaseToken}`,
            purchased: nextPurchase?.purchased ?? true,
            acknowledged: nextPurchase?.acknowledged ?? false,
            expiresAt: null,
            rawState: nextPurchase?.rawState || 'PURCHASED',
        };
    },
    async verifySubscription(productId, purchaseToken) {
        return {
            kind: 'subs',
            productId,
            purchaseToken,
            orderId: `order-${purchaseToken}`,
            purchased: nextPurchase?.purchased ?? true,
            acknowledged: nextPurchase?.acknowledged ?? false,
            expiresAt: nextPurchase?.expiresAt,
            rawState: nextPurchase?.rawState || 'SUBSCRIPTION_STATE_ACTIVE',
        };
    },
    async acknowledge() { acknowledgeCount++; },
    async pubsubIdentity(token) {
        if (token !== 'valid-rtdn-jwt') throw new Error('bad jwt');
        return { email: 'push@example.iam.gserviceaccount.com' };
    },
    async listVoided() {
        return { voidedPurchases: voided };
    },
};
api.setGooglePlayClient(client);

test.after(() => {
    db.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
});

test('Google Play verification is idempotent and binds a lifetime entitlement', async () => {
    nextPurchase = { purchased: true, acknowledged: false };
    const body = {
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_lifetime',
        purchase_token: 'lifetime-token-0001',
        app_ver: '2.0',
    };
    const first = await api.apiGooglePlayVerify(body);
    const second = await api.apiGooglePlayVerify(body);
    assert.equal(first.ok, true);
    assert.equal(first.product, 'lifetime');
    assert.equal(first.expires_at, undefined);
    assert.equal(second.code, first.code);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM google_play_purchases').get().n, 1);
    assert.equal(db.prepare('SELECT expires_at FROM codes WHERE code = ?').get(first.code).expires_at, null);
    assert.equal(db.prepare('SELECT device_fp FROM bindings WHERE code = ?').get(first.code).device_fp, fp1);
    assert.equal(acknowledgeCount, 2);
});

test('package, product, token and fingerprint validation fail closed', async () => {
    const base = {
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_lifetime',
        purchase_token: 'validation-token-01',
    };
    assert.equal((await api.apiGooglePlayVerify({ ...base, package_name: 'evil.pkg' })).err, 'BAD_REQUEST');
    assert.equal((await api.apiGooglePlayVerify({ ...base, product_id: 'evil_product' })).err, 'BAD_REQUEST');
    assert.equal((await api.apiGooglePlayVerify({ ...base, purchase_token: 'short' })).err, 'BAD_REQUEST');
    assert.equal((await api.apiGooglePlayVerify({ ...base, fp: 'bad' })).err, 'BAD_REQUEST');
});

test('annual entitlement uses Google expiry exactly and restore moves only its binding', async () => {
    const expiresAt = new Date(Date.now() + 45 * 24 * 3600_000).toISOString();
    nextPurchase = { purchased: true, acknowledged: true, expiresAt };
    const body = {
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_annual',
        purchase_token: 'annual-token-000001',
        app_ver: '2.0',
    };
    const first = await api.apiGooglePlayVerify(body);
    const restored = await api.apiGooglePlayVerify({ ...body, fp: fp2 });
    assert.equal(first.ok, true);
    assert.equal(first.expires_at, expiresAt);
    assert.equal(restored.code, first.code);
    assert.deepEqual(
        db.prepare('SELECT device_fp FROM bindings WHERE code = ?').all(first.code)
            .map((row) => row.device_fp),
        [fp2],
    );
});

test('inactive/refunded Google purchase revokes only its Google-owned code', async () => {
    db.prepare(`INSERT INTO codes (code, note, created_at, expires_at)
                VALUES ('ABCDEFG', 'domestic-manual', ?, NULL)`).run(new Date().toISOString());
    nextPurchase = { purchased: true, acknowledged: true };
    const body = {
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_lifetime',
        purchase_token: 'refund-token-00001',
    };
    const paid = await api.apiGooglePlayVerify(body);
    nextPurchase = { purchased: false, acknowledged: true, rawState: 'CANCELLED' };
    const canceled = await api.apiGooglePlayVerify(body);
    assert.equal(canceled.err, 'PURCHASE_NOT_ACTIVE');
    assert.equal(db.prepare('SELECT status FROM codes WHERE code = ?').get(paid.code).status, 'revoked');
    assert.equal(db.prepare("SELECT status FROM codes WHERE code = 'ABCDEFG'").get().status, 'active');
});

test('RTDN requires authenticated push identity and refreshes known purchase', async () => {
    nextPurchase = { purchased: true, acknowledged: true };
    const body = {
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_lifetime',
        purchase_token: 'rtdn-token-0000001',
    };
    await api.apiGooglePlayVerify(body);
    const envelope = {
        message: {
            data: Buffer.from(JSON.stringify({
                packageName: 'com.ztransfer.play',
                oneTimeProductNotification: {
                    sku: 'ztransfer_pro_lifetime',
                    purchaseToken: body.purchase_token,
                    notificationType: 1,
                },
            })).toString('base64'),
        },
    };
    assert.equal((await api.apiGooglePlayRtdn('Bearer invalid', envelope)).status, 401);
    assert.equal((await api.apiGooglePlayRtdn('Bearer valid-rtdn-jwt', envelope)).status, 204);
});

test('voided purchase reconciliation revokes matching Google rows only', async () => {
    nextPurchase = { purchased: true, acknowledged: true };
    const token = 'voided-token-000001';
    const paid = await api.apiGooglePlayVerify({
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_lifetime',
        purchase_token: token,
    });
    voided = [{ purchaseToken: token, voidedReason: 1 }];
    const result = await api.adminGooglePlayReconcileVoided();
    assert.deepEqual(result, { ok: true, checked: 1, revoked: 1 });
    assert.equal(db.prepare('SELECT status FROM codes WHERE code = ?').get(paid.code).status, 'revoked');
});

test('an older voided subscription renewal does not revoke the current paid renewal', async () => {
    nextPurchase = {
        purchased: true,
        acknowledged: true,
        expiresAt: new Date(Date.now() + 365 * 24 * 3600_000).toISOString(),
    };
    const token = 'voided-annual-token-01';
    const paid = await api.apiGooglePlayVerify({
        fp: fp1,
        package_name: 'com.ztransfer.play',
        product_id: 'ztransfer_pro_annual',
        purchase_token: token,
    });
    voided = [{ purchaseToken: token, orderId: 'GPA.old-renewal', voidedReason: 1 }];
    assert.deepEqual(
        await api.adminGooglePlayReconcileVoided(),
        { ok: true, checked: 1, revoked: 0 },
    );
    assert.equal(db.prepare('SELECT status FROM codes WHERE code = ?').get(paid.code).status, 'active');
});
