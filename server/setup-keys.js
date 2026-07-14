#!/usr/bin/env node
// 一次性初始化工具。
//   node setup-keys.js init [目录]     生成签发密钥对 + admin token + config.json 模板,
//                                      并打印 App 需要内置的公钥(base64 SPKI)
//   node setup-keys.js pin cert.pem    计算 TLS 证书的 SPKI SHA-256 pin(App 内置用)
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const cmd = process.argv[2];

if (cmd === 'init') {
    const dir = path.resolve(process.argv[3] || '.');
    const keyPath = path.join(dir, 'signing-key.pem');
    const cfgPath = path.join(dir, 'config.json');
    if (fs.existsSync(keyPath)) {
        console.error(`已存在 ${keyPath},拒绝覆盖(覆盖会使已发出的所有通行证失效)`);
        process.exit(1);
    }

    const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
    fs.writeFileSync(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    const pubB64 = publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
    const adminToken = crypto.randomBytes(32).toString('base64url');

    if (!fs.existsSync(cfgPath)) {
        fs.writeFileSync(cfgPath, JSON.stringify({
            port: 8443,
            dbPath: path.join(dir, 'license.db'),
            tlsCertPath: path.join(dir, 'tls-cert.pem'),
            tlsKeyPath: path.join(dir, 'tls-key.pem'),
            signingKeyPath: keyPath,
            adminToken,
        }, null, 2) + '\n', { mode: 0o600 });
    }

    console.log(`签发私钥已写入: ${keyPath}(备份它!丢失后已售激活码全部无法续签)`);
    console.log(`config.json 已写入: ${cfgPath}(含 adminToken,自行保管)`);
    console.log('');
    console.log('=== App 内置公钥(License.kt 的 PUBLIC_KEY_B64)===');
    console.log(pubB64);
    console.log('');
    console.log('=== 下一步:生成自签名 TLS 证书(替换 <ECS公网IP>)===');
    console.log('openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \\');
    console.log('  -keyout tls-key.pem -out tls-cert.pem -days 3650 -nodes \\');
    console.log('  -subj "/CN=ztransfer-license" -addext "subjectAltName=IP:<ECS公网IP>"');
    console.log('然后: node setup-keys.js pin tls-cert.pem');
} else if (cmd === 'pin') {
    const certPem = fs.readFileSync(process.argv[3], 'utf8');
    const cert = new crypto.X509Certificate(certPem);
    const spki = cert.publicKey.export({ type: 'spki', format: 'der' });
    const pin = crypto.createHash('sha256').update(spki).digest('base64');
    console.log('=== App 内置证书指纹(License.kt 的 CERT_PIN_B64)===');
    console.log(pin);
} else {
    console.log('用法: node setup-keys.js init [目录] | node setup-keys.js pin cert.pem');
    process.exit(1);
}
