'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const adminScript = fs.readFileSync(path.join(__dirname, '..', 'admin.ps1'), 'utf8');

function functionSource(name) {
    const marker = `function ${name}`;
    const start = adminScript.indexOf(marker);
    assert.notEqual(start, -1, `missing ${name}`);
    const next = adminScript.indexOf('\nfunction ', start + marker.length);
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

test('版本对象禁止覆盖而固定地址必须显式允许覆盖', () => {
    const upload = functionSource('Upload-ApkToOss');
    const publish = functionSource('Invoke-UpdatePublish');

    assert.match(upload, /if \(\$allowOverwrite\) \{ "--force" \} else \{ "--ignore-existing" \}/);
    assert.match(publish, /LatestOssUri[\s\S]+\$true/);
});

test('菜单默认安全入口与正式发布入口不会混淆', () => {
    const menu = functionSource('Invoke-UpdateMenu');
    const publish = functionSource('Invoke-UpdatePublish');

    assert.match(menu, /"3"\s*\{\s*Invoke-UpdateStage\s*\}/);
    assert.match(menu, /"4"\s*\{\s*Invoke-UpdatePublish\s*\}/);
    assert.match(publish, /-cne "PUBLISH"/);
    assert.match(publish, /LatestOssUri/);
    assert.match(publish, /"POST"\s+"\/admin\/update\/publish"/);
});
