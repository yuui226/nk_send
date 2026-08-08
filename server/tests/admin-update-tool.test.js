'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const adminScript = fs.readFileSync(path.join(__dirname, '..', 'admin.ps1'), 'utf8');

function functionSource(name) {
    const marker = new RegExp(`function ${name}(?=\\s*[({])`);
    const match = marker.exec(adminScript);
    const start = match ? match.index : -1;
    assert.notEqual(start, -1, `missing ${name}`);
    const next = adminScript.indexOf('\nfunction ', start + match[0].length);
    return adminScript.slice(start, next === -1 ? adminScript.length : next);
}

test('测试上传与服务端发布和固定地址保持硬隔离', () => {
    const stage = functionSource('Invoke-UpdateStage');

    assert.match(stage, /Upload-VersionedApkToOss/);
    assert.match(stage, /Test-PublicOssApk/);
    assert.match(stage, /-cne "UPLOAD"/);
    assert.doesNotMatch(stage, /\bCall\s+["']/);
    assert.doesNotMatch(stage, /Get-Update(?:Info|PublishState)/);
    assert.doesNotMatch(stage, /Latest(?:ObjectKey|OssUri|PublicUrl)/);
    assert.doesNotMatch(stage, /\/admin\/update\/publish/);
    assert.doesNotMatch(stage, /Upload-ApkToOss/);
});

test('版本上传包装器只接受确定的 releases 哈希地址', () => {
    const upload = functionSource('Upload-VersionedApkToOss');
    const target = functionSource('New-OssReleaseTarget');

    assert.match(upload, /New-OssReleaseTarget/);
    assert.match(upload, /target\.ObjectKey[^\n]+expected\.ObjectKey/);
    assert.match(upload, /target\.OssUri[^\n]+expected\.OssUri/);
    assert.match(upload, /target\.PublicUrl[^\n]+expected\.PublicUrl/);
    assert.match(upload, /\^releases\/ZTransfer-v/);
    assert.match(upload, /Upload-ApkToOss[^\n]+target\.OssUri/);
    assert.match(upload, /filename=.*meta\.VersionName/);
    assert.match(upload, /\$false/);
    assert.match(target, /versionLabel\s*=\s*\(\[string\]\$meta\.VersionName\)/);
    assert.match(target, /ZTransfer-v\{0\}-\{1\}\.apk[^\n]+versionLabel/);
    assert.doesNotMatch(target, /ZTransfer-v\{0\}-\{1\}\.apk[^\n]+VersionCode/);
});

test('版本对象禁止覆盖且固定地址使用 OSS 同桶服务端复制', () => {
    const upload = functionSource('Upload-ApkToOss');
    const publish = functionSource('Invoke-UpdatePublish');
    const copy = functionSource('Copy-VersionedApkToLatest');

    assert.match(upload, /if \(\$allowOverwrite\) \{ "--force" \} else \{ "--ignore-existing" \}/);
    assert.match(publish, /Copy-VersionedApkToLatest/);
    assert.doesNotMatch(publish, /Upload-ApkToOss/);
    assert.match(copy, /target\.OssUri[\s\S]+target\.LatestOssUri/);
    assert.match(copy, /"--metadata-directive", "REPLACE"/);
    assert.match(copy, /"--force"/);
});

test('发布快速校验只读取公网响应头并核对内容指纹', () => {
    const verify = functionSource('Test-PublicOssApk');
    const fullVerify = functionSource('Test-PublicOssApkFull');

    assert.match(verify, /--head/);
    assert.match(verify, /content-length/);
    assert.match(verify, /content-md5/);
    assert.match(verify, /x-oss-meta-sha256/);
    assert.doesNotMatch(verify, /Read-LocalApkMetadata/);
    assert.match(fullVerify, /Read-LocalApkMetadata/);
});

test('菜单默认安全入口与正式发布入口不会混淆', () => {
    const menu = functionSource('Invoke-UpdateMenu');
    const publish = functionSource('Invoke-UpdatePublish');

    assert.match(menu, /"3"\s*\{\s*Invoke-UpdateStage\s*\}/);
    assert.match(menu, /"4"\s*\{\s*Invoke-UpdatePublish\s*\}/);
    assert.doesNotMatch(publish, /PUBLISH/);
    assert.doesNotMatch(publish, /Read-Host\s+"确认正式发布/);
    assert.match(publish, /Copy-VersionedApkToLatest/);
    assert.match(publish, /"POST"\s+"\/admin\/update\/publish"/);
});
