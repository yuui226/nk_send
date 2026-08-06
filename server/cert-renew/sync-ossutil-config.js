'use strict';

const fs = require('fs');
const path = require('path');

const sourcePath = '/root/.aliyun/config.json';
const targetPath = '/opt/ztransfer-cert-renew/ossutil.conf';
const preferredProfile = process.env.ZT_ALIYUN_PROFILE || 'ztransfer-';

function pick(object, names) {
    for (const name of names) {
        const value = object?.[name];
        if (typeof value === 'string' && value.trim()) return value.trim();
    }
    return '';
}

function iniValue(value, label) {
    if (!value || /[\r\n"]/u.test(value)) {
        throw new Error(`${label} 格式无效`);
    }
    return `"${value}"`;
}

const config = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
const profiles = Array.isArray(config.profiles) ? config.profiles : [];
const profile = profiles.find((item) => item?.name === preferredProfile)
    || profiles.find((item) => String(item?.name || '').startsWith('ztransfer'));

if (!profile) throw new Error(`找不到阿里云 CLI profile: ${preferredProfile}`);

const accessKeyId = pick(profile, ['access_key_id', 'accessKeyId', 'accessKeyID']);
const accessKeySecret = pick(profile, ['access_key_secret', 'accessKeySecret']);
if (!accessKeyId || !accessKeySecret) throw new Error('阿里云 CLI profile 缺少 AccessKey');

const content = [
    '[default]',
    'mode = AK',
    `accessKeyID = ${iniValue(accessKeyId, 'AccessKey ID')}`,
    `accessKeySecret = ${iniValue(accessKeySecret, 'AccessKey Secret')}`,
    'region = cn-hongkong',
    'endpoint = https://oss-cn-hongkong.aliyuncs.com',
    'output-format = json',
    '',
].join('\n');

fs.mkdirSync(path.dirname(targetPath), { recursive: true, mode: 0o700 });
const tempPath = `${targetPath}.new`;
fs.writeFileSync(tempPath, content, { encoding: 'utf8', mode: 0o600 });
fs.chmodSync(tempPath, 0o600);
fs.renameSync(tempPath, targetPath);
console.log('ossutil 配置已同步');
