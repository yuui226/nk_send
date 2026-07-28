'use strict';

// Google Play Developer API client implemented with Node's standard library.
// This keeps the license service zero-npm-dependency and keeps service-account
// credentials out of SQLite. Credentials are loaded only from an environment
// variable or from the configured file path.

const fs = require('node:fs');
const crypto = require('node:crypto');

const API_ROOT = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GOOGLE_CERTS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

const b64json = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

function loadServiceAccount(config, env = process.env) {
    let raw = env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON;
    if (!raw) {
        const file = env.GOOGLE_PLAY_SERVICE_ACCOUNT_FILE || config.serviceAccountFile;
        if (file) raw = fs.readFileSync(file, 'utf8');
    }
    if (!raw) throw new Error('GOOGLE_PLAY_CREDENTIALS_MISSING');
    const value = JSON.parse(raw);
    if (value.type !== 'service_account' || !value.client_email || !value.private_key) {
        throw new Error('GOOGLE_PLAY_CREDENTIALS_INVALID');
    }
    return value;
}

function decodeJwtPart(value) {
    return JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
}

function createGooglePlayClient(config, options = {}) {
    const fetchImpl = options.fetch || globalThis.fetch;
    if (typeof fetchImpl !== 'function') throw new Error('FETCH_UNAVAILABLE');
    const serviceAccount = options.serviceAccount || loadServiceAccount(config, options.env);
    let access = null;
    let certCache = null;

    async function jsonRequest(url, init = {}) {
        const response = await fetchImpl(url, init);
        const text = await response.text();
        let body = {};
        if (text) {
            try { body = JSON.parse(text); } catch { body = { raw: text.slice(0, 500) }; }
        }
        if (!response.ok) {
            const reason = body?.error?.message || body?.error_description || `HTTP_${response.status}`;
            const error = new Error(`GOOGLE_API_${response.status}:${reason}`);
            error.status = response.status;
            error.body = body;
            throw error;
        }
        return body;
    }

    async function accessToken() {
        if (access && access.expiresAt > Date.now() + 60_000) return access.token;
        const issuedAt = Math.floor(Date.now() / 1000);
        const assertion = `${b64json({ alg: 'RS256', typ: 'JWT' })}.`
            + `${b64json({
                iss: serviceAccount.client_email,
                scope: SCOPE,
                aud: TOKEN_URL,
                iat: issuedAt,
                exp: issuedAt + 3600,
            })}`;
        const signature = crypto.sign(
            'RSA-SHA256',
            Buffer.from(assertion),
            crypto.createPrivateKey(serviceAccount.private_key),
        ).toString('base64url');
        const token = await jsonRequest(TOKEN_URL, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
                grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                assertion: `${assertion}.${signature}`,
            }),
        });
        if (!token.access_token) throw new Error('GOOGLE_ACCESS_TOKEN_MISSING');
        access = {
            token: token.access_token,
            expiresAt: Date.now() + Math.max(60, Number(token.expires_in) || 3600) * 1000,
        };
        return access.token;
    }

    async function publisher(path, { method = 'GET', body } = {}) {
        const token = await accessToken();
        return jsonRequest(`${API_ROOT}/${encodeURIComponent(config.packageName)}${path}`, {
            method,
            headers: {
                Authorization: `Bearer ${token}`,
                ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
            },
            ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        });
    }

    async function verifyProduct(productId, purchaseToken) {
        const value = await publisher(`/purchases/productsv2/tokens/${encodeURIComponent(purchaseToken)}`);
        const item = (value.productLineItem || []).find((line) => line.productId === productId);
        if (!item) throw new Error('GOOGLE_PRODUCT_MISMATCH');
        return {
            kind: 'inapp',
            productId,
            purchaseToken,
            orderId: value.orderId || '',
            purchased: value.purchaseStateContext?.purchaseState === 'PURCHASED',
            acknowledged: value.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
            expiresAt: null,
            rawState: value.purchaseStateContext?.purchaseState || 'UNKNOWN',
        };
    }

    async function verifySubscription(productId, purchaseToken) {
        const value = await publisher(`/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`);
        const item = (value.lineItems || []).find((line) => line.productId === productId);
        if (!item) throw new Error('GOOGLE_PRODUCT_MISMATCH');
        const liveStates = new Set([
            'SUBSCRIPTION_STATE_ACTIVE',
            'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
            // Cancellation stops renewal, not the already-paid access period.
            'SUBSCRIPTION_STATE_CANCELED',
        ]);
        return {
            kind: 'subs',
            productId,
            purchaseToken,
            orderId: item.latestSuccessfulOrderId || '',
            purchased: liveStates.has(value.subscriptionState)
                && Date.parse(item.expiryTime || '') > Date.now(),
            acknowledged: value.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
            expiresAt: item.expiryTime || null,
            rawState: value.subscriptionState || 'UNKNOWN',
            linkedPurchaseToken: value.linkedPurchaseToken || null,
        };
    }

    async function acknowledge(purchase) {
        if (purchase.acknowledged) return;
        const prefix = purchase.kind === 'subs'
            ? `/purchases/subscriptions/${encodeURIComponent(purchase.productId)}`
            : `/purchases/products/${encodeURIComponent(purchase.productId)}`;
        await publisher(`${prefix}/tokens/${encodeURIComponent(purchase.purchaseToken)}:acknowledge`, {
            method: 'POST',
            body: {},
        });
    }

    async function listVoided(startTimeMillis, pageToken) {
        const query = new URLSearchParams({
            type: '1',
            includeQuantityBasedPartialRefund: 'true',
            ...(startTimeMillis ? { startTime: String(startTimeMillis) } : {}),
            ...(pageToken ? { token: pageToken } : {}),
        });
        return publisher(`/purchases/voidedpurchases?${query}`);
    }

    async function pubsubIdentity(jwt) {
        if (!config.pubsubAudience) throw new Error('GOOGLE_PUBSUB_AUTH_NOT_CONFIGURED');
        const parts = String(jwt || '').split('.');
        if (parts.length !== 3) throw new Error('GOOGLE_PUBSUB_JWT_INVALID');
        const header = decodeJwtPart(parts[0]);
        const claims = decodeJwtPart(parts[1]);
        if (header.alg !== 'RS256' || !header.kid) throw new Error('GOOGLE_PUBSUB_JWT_ALG');
        const nowSec = Math.floor(Date.now() / 1000);
        const issuerOk = claims.iss === 'accounts.google.com'
            || claims.iss === 'https://accounts.google.com';
        const audienceOk = claims.aud === config.pubsubAudience
            || (Array.isArray(claims.aud) && claims.aud.includes(config.pubsubAudience));
        if (!issuerOk || !audienceOk
            || !Number.isSafeInteger(claims.exp) || claims.exp < nowSec
            || !Number.isSafeInteger(claims.iat) || claims.iat > nowSec + 60) {
            throw new Error('GOOGLE_PUBSUB_JWT_CLAIMS');
        }
        if (config.pubsubServiceAccountEmail
            && (claims.email !== config.pubsubServiceAccountEmail
                || claims.email_verified !== true)) {
            throw new Error('GOOGLE_PUBSUB_JWT_EMAIL');
        }
        if (!certCache || certCache.expiresAt <= Date.now()) {
            const response = await fetchImpl(GOOGLE_CERTS_URL);
            if (!response.ok) throw new Error(`GOOGLE_CERTS_${response.status}`);
            const jwks = await response.json();
            certCache = { keys: jwks.keys || [], expiresAt: Date.now() + 3600_000 };
        }
        const key = certCache.keys.find((item) => item.kid === header.kid && item.kty === 'RSA');
        if (!key) throw new Error('GOOGLE_PUBSUB_JWT_KEY');
        const valid = crypto.verify(
            'RSA-SHA256',
            Buffer.from(`${parts[0]}.${parts[1]}`),
            crypto.createPublicKey({ key, format: 'jwk' }),
            Buffer.from(parts[2], 'base64url'),
        );
        if (!valid) throw new Error('GOOGLE_PUBSUB_JWT_SIGNATURE');
        return claims;
    }

    return {
        verifyProduct,
        verifySubscription,
        acknowledge,
        listVoided,
        pubsubIdentity,
    };
}

module.exports = { createGooglePlayClient, loadServiceAccount };
