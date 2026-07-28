'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createGooglePlayClient } = require('../google-play');

const servicePair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const oidcPair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const serviceAccount = {
    type: 'service_account',
    client_email: 'publisher@example.iam.gserviceaccount.com',
    private_key: servicePair.privateKey.export({ type: 'pkcs8', format: 'pem' }),
};
const calls = [];
let publisherBody = {};

async function fakeFetch(url, init = {}) {
    calls.push({ url: String(url), init });
    if (String(url) === 'https://oauth2.googleapis.com/token') {
        return new Response(JSON.stringify({ access_token: 'access', expires_in: 3600 }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
        });
    }
    if (String(url) === 'https://www.googleapis.com/oauth2/v3/certs') {
        return new Response(JSON.stringify({
            keys: [{
                ...oidcPair.publicKey.export({ format: 'jwk' }),
                kid: 'oidc-key',
                alg: 'RS256',
                use: 'sig',
            }],
        }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    return new Response(JSON.stringify(publisherBody), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
    });
}

const client = createGooglePlayClient({
    packageName: 'com.ztransfer.play',
    pubsubAudience: 'https://license.invalid/google-play/rtdn',
    pubsubServiceAccountEmail: 'push@example.iam.gserviceaccount.com',
}, { serviceAccount, fetch: fakeFetch });

test('native client verifies v2 one-time product response and acknowledges', async () => {
    publisherBody = {
        orderId: 'GPA.1',
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
        purchaseStateContext: { purchaseState: 'PURCHASED' },
        productLineItem: [{ productId: 'ztransfer_pro_lifetime' }],
    };
    const purchase = await client.verifyProduct('ztransfer_pro_lifetime', 'token-value');
    assert.equal(purchase.purchased, true);
    assert.equal(purchase.orderId, 'GPA.1');
    await client.acknowledge(purchase);
    assert.match(calls.at(-1).url, /purchases\/products\/ztransfer_pro_lifetime\/tokens\/token-value:acknowledge$/);
    assert.equal(calls.at(-1).init.method, 'POST');
});

test('subscription cancellation retains access until exact Google expiry', async () => {
    const expiry = new Date(Date.now() + 3600_000).toISOString();
    publisherBody = {
        acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
        subscriptionState: 'SUBSCRIPTION_STATE_CANCELED',
        lineItems: [{
            productId: 'ztransfer_pro_annual',
            expiryTime: expiry,
            latestSuccessfulOrderId: 'GPA.2',
        }],
    };
    const purchase = await client.verifySubscription('ztransfer_pro_annual', 'sub-token');
    assert.equal(purchase.purchased, true);
    assert.equal(purchase.expiresAt, expiry);
    assert.equal(purchase.orderId, 'GPA.2');
});

test('Pub/Sub OIDC JWT validation checks signature, audience and email', async () => {
    const now = Math.floor(Date.now() / 1000);
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'oidc-key' })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({
        iss: 'https://accounts.google.com',
        aud: 'https://license.invalid/google-play/rtdn',
        email: 'push@example.iam.gserviceaccount.com',
        email_verified: true,
        iat: now - 10,
        exp: now + 300,
    })).toString('base64url');
    const input = `${header}.${claims}`;
    const signature = crypto.sign('RSA-SHA256', Buffer.from(input), oidcPair.privateKey)
        .toString('base64url');
    const identity = await client.pubsubIdentity(`${input}.${signature}`);
    assert.equal(identity.email, 'push@example.iam.gserviceaccount.com');
    await assert.rejects(
        client.pubsubIdentity(`${input}.invalid`),
        /GOOGLE_PUBSUB_JWT_SIGNATURE/,
    );
});
