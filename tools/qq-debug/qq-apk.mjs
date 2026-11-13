#!/usr/bin/env node
import { chmod, mkdir, readFile, realpath, rename, stat, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';
import { Writable } from 'node:stream';

const directory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(directory, '../..');
const configPath = process.env.ZTRANSFER_QQ_CONFIG || resolve(repositoryRoot, '.build-tools/qq-debug/config.json');
const [command, apkArgument] = process.argv.slice(2);
const sensitiveValues = new Set();
process.umask(0o077);

async function readConfig() {
  try {
    const metadata = await stat(configPath);
    if ((metadata.mode & 0o077) !== 0) await chmod(configPath, 0o600);
    return JSON.parse(await readFile(configPath, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function saveConfig(config) {
  await mkdir(dirname(configPath), { recursive: true, mode: 0o700 });
  const temporaryPath = `${configPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  await rename(temporaryPath, configPath);
  await chmod(configPath, 0o600);
}

async function promptCredentials() {
  if (!process.stdin.isTTY) throw new Error('首次 setup 请在终端运行，或先写入权限为 600 的本机配置（appId、appSecret）。');
  let muted = false;
  const output = new Writable({
    write(chunk, encoding, callback) {
      if (!muted) process.stdout.write(chunk, encoding);
      callback();
    },
  });
  const input = createInterface({ input: process.stdin, output, terminal: true });
  try {
    const appId = (await input.question('AppID: ')).trim();
    process.stdout.write('AppSecret（隐藏输入）: ');
    muted = true;
    const appSecret = (await input.question('')).trim();
    process.stdout.write('\n');
    return { appId, appSecret };
  } finally {
    input.close();
  }
}

function validateCredentials(config) {
  for (const value of [config?.appSecret, config?.appId, config?.targetOpenid]) {
    if (typeof value === 'string' && value.trim()) sensitiveValues.add(value.trim());
  }
  if (!config || typeof config.appId !== 'string' || !config.appId.trim()
      || typeof config.appSecret !== 'string' || !config.appSecret.trim()) {
    throw new Error('配置缺少 appId 或 appSecret。');
  }
}

function validateRecipient(config) {
  if (typeof config.targetOpenid !== 'string' || !config.targetOpenid.trim()) {
    throw new Error('配置未绑定有效收件人，请先运行 setup。');
  }
}

async function loadSdk() {
  try {
    return await import('@tencent-connect/qqbot-nodejs');
  } catch (error) {
    if (error.code === 'ERR_MODULE_NOT_FOUND') {
      throw new Error('请先运行 npm --prefix tools/qq-debug ci --ignore-scripts。');
    }
    throw error;
  }
}

function publicError(error) {
  // Avoid dumping SDK request bodies, credentials, tokens, or signed upload URLs.
  if (error instanceof SyntaxError) return '私密配置不是有效 JSON；请检查文件内容。';
  let summary = [error.name, error.message,
    error.httpStatus && `HTTP=${error.httpStatus}`,
    (error.bizCode ?? error.code) && `code=${error.bizCode ?? error.code}`,
    error.cause?.code && `cause.code=${error.cause.code}`,
    error.cause?.message && `cause=${error.cause.message}`,
    error.stack?.split('\n').find(line => line.trim().startsWith('at ')),
  ].filter(Boolean).join(' | ');
  for (const value of sensitiveValues) summary = summary.split(value).join('[REDACTED]');
  return summary
    .replace(/\b(?:https?|wss?):\/\/\S+/g, '[URL]')
    .replace(/\b(?:QQBot|Bearer)\s+\S+/g, '[AUTH]')
    .replace(/(appSecret|clientSecret|access_token|authorization)["']?\s*[:=]\s*["']?[^\s,"'}]+/gi, '$1=[REDACTED]')
    .replace(/[A-Za-z0-9_+/=-]{24,}/g, '[REDACTED]')
    .slice(0, 600);
}

async function setup() {
  const config = await readConfig() ?? await promptCredentials();
  validateCredentials(config);
  if (config.targetOpenid !== undefined) {
    validateRecipient(config);
    console.log('已绑定唯一收件人；无需再次 setup。');
    return;
  }
  const { QQBot } = await loadSdk();
  const bot = new QQBot({
    appId: config.appId.trim(), appSecret: config.appSecret.trim(),
    baseUrl: 'https://api.bot.qq.com',
    intents: 1 << 25, reconnect: { maxAttempts: 1 },
  });
  const challenge = `ZD绑定${randomBytes(3).toString('hex').toUpperCase()}`;
  let targetOpenid;
  let connectionError;
  bot.on('ready', () => console.log(`请在手机 QQ 与这个机器人单聊，发送：${challenge}\n等待绑定，最长 5 分钟；绑定不会发送任何回复。`));
  bot.on('message', (_context, message) => {
    if (targetOpenid || message.kind !== 'c2c' || message.content?.trim() !== challenge) return;
    const candidate = message.replyTarget.targetId;
    if (typeof candidate !== 'string' || !candidate.trim()) return;
    targetOpenid = candidate.trim();
    bot.stop();
  });
  bot.on('error', error => { connectionError = error; bot.stop(); });
  const stop = () => bot.stop();
  const timeout = setTimeout(stop, 5 * 60_000);
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  try {
    await bot.start();
  } finally {
    clearTimeout(timeout);
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
    bot.stop();
  }
  if (connectionError) throw connectionError;
  if (!targetOpenid) throw new Error('未收到绑定码，已退出；没有绑定或发送消息。');
  await saveConfig({ appId: config.appId.trim(), appSecret: config.appSecret.trim(), targetOpenid });
  console.log('本人收件人已绑定；连接已关闭。凭证仅保存在本机配置文件（600）。');
}

async function send() {
  const config = await readConfig();
  if (!config) {
    console.log('SKIPPED：尚未配置并绑定 QQ 收件人。');
    return;
  }
  validateCredentials(config);
  validateRecipient(config);
  if (!apkArgument) throw new Error('用法：node qq-apk.mjs send /绝对路径/ZD-时间戳.apk');
  const apkPath = await realpath(resolve(apkArgument));
  const allowedDirectory = await realpath(resolve(repositoryRoot, 'dist-debug'));
  const metadata = await stat(apkPath);
  if (dirname(apkPath) !== allowedDirectory || !metadata.isFile()
      || !/^ZD-\d{4}-\d{6}\.apk$/.test(basename(apkPath))) {
    throw new Error('仅发送仓库根 dist-debug 中的 ZD-MMdd-HHmmss.apk 时间戳文件。');
  }
  if (metadata.size <= 0 || metadata.size > 100 * 1024 * 1024) {
    throw new Error('APK 必须大于 0 且不超过官方 SDK 当前的 100 MB 上限。');
  }
  const { QQBot } = await loadSdk();
  const bot = new QQBot({ appId: config.appId.trim(), appSecret: config.appSecret.trim(), baseUrl: 'https://api.bot.qq.com' });
  // No start(): sendFile uses token + HTTP APIs, without a WebSocket listener.
  console.log(`发送 ${basename(apkPath)}（${(metadata.size / 1024 / 1024).toFixed(1)} MB）至已绑定本人 QQ。`);
  let lastBucket = -1;
  try {
    const result = await bot.sendFile(
      { scope: 'c2c', targetId: config.targetOpenid.trim() },
      { localPath: apkPath },
      {
        fileName: basename(apkPath),
        onProgress(uploaded, total) {
          const bucket = Math.floor(uploaded / total * 4);
          if (bucket !== lastBucket) {
            lastBucket = bucket;
            console.log(`上传 ${Math.floor(uploaded / total * 100)}%`);
          }
        },
      },
    );
    if (!result.message?.id) throw new Error('未取得消息 ID，不能确认发送成功；请先查看手机 QQ，避免重复发送。');
    console.log('QQ 已接受文件消息，请在手机验证下载与安装。');
  } finally {
    bot.stop();
  }
}

// SDK upload retries are bounded by this process deadline. The final message is sent once.
const sendTimeout = command === 'send' ? setTimeout(() => {
  console.error('QQ 发送超过 120 秒，已退出；请先查看手机 QQ，避免重复发送。');
  process.exit(1);
}, 120_000) : null;

try {
  if (command === 'setup') await setup();
  else if (command === 'send') await send();
  else console.log('用法：\n  node qq-apk.mjs setup\n  node qq-apk.mjs send /绝对路径/ZD-时间戳.apk');
} catch (error) {
  console.error(publicError(error));
  process.exitCode = 1;
} finally {
  if (sendTimeout) clearTimeout(sendTimeout);
}
