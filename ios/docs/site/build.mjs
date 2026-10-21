import { readFile, writeFile, mkdir, rm, copyFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

// The optional module path lets the local Codex bundled runtime build without
// installing anything. Normal use resolves the pinned package.json dependency.
const { marked } = await import(process.env.ZTRANSFER_MARKED_MODULE
  ? pathToFileURL(process.env.ZTRANSFER_MARKED_MODULE).href : 'marked');
const root = path.dirname(fileURLToPath(import.meta.url));
const docs = path.dirname(root);
const release = process.argv.includes('--release');
const website = process.argv.includes('--website');
const out = path.join(root, website
  ? (release ? 'website-dist' : 'website-preview')
  : (release ? 'dist' : 'preview'));
const websiteSource = path.resolve(root, '../../../site');
const read = name => readFile(path.join(docs, name), 'utf8');
function section(text, start, end) {
  const a = text.indexOf(start);
  const b = text.indexOf(end, a + start.length);
  if (a < 0 || b < 0) throw new Error(`Missing source boundary: ${start} / ${end}`);
  return text.slice(a + start.length, b).trim();
}
const english = await read('英文隐私与条款草稿.md');
const pages = [
  {slug:'privacy', lang:'zh-Hans', title:'隐私政策', body:section(await read('隐私政策草稿.md'), '## 运营者与适用范围', '## 内部依据与发布前核对')},
  {slug:'terms', lang:'zh-Hans', title:'使用条款', body:section(await read('使用条款草稿.md'), '## 提供者与协议范围', '## 内部确认事项')},
  {slug:'support', lang:'zh-Hans', title:'帮助与支持', body:section(await read('支持页面草稿.md'), '## 联系开发者', '## English Support')},
  {slug:'privacy', lang:'en', title:'Privacy Policy', body:section(english, '## Privacy Policy', '## Terms of Use')},
  {slug:'terms', lang:'en', title:'Terms of Use', body:section(english, '## Terms of Use', '## Internal Review Notes')},
  {slug:'support', lang:'en', title:'Help & Support', body:section(await read('支持页面草稿.md'), '## English Support', '## 内部发布检查')},
];
const markers = /【待[^】]*】|\[(?:OWNER INPUT|TECHNICAL REVIEW)[^\]]*\]/g;
const pending = pages.flatMap(p => [...p.body.matchAll(markers)].map(m => `${p.lang}/${p.slug}: ${m[0]}`));
if (release && pending.length) {
  // Validate before replacing any existing dist output.
  throw new Error(`Publication blocked: ${pending.length} unresolved markers.\n${pending.join('\n')}`);
}
// The first publication date is supplied at release time, then retained on
// later builds of the same policy. Preview dates do not assert publication.
const dateArgument = process.argv.find(value => value.startsWith('--effective-date='));
const effectiveDate = dateArgument?.slice('--effective-date='.length)
  ?? (release ? null : new Intl.DateTimeFormat('en-CA', {timeZone:'Asia/Shanghai'}).format(new Date()));
if (!effectiveDate || !/^\d{4}-\d{2}-\d{2}$/.test(effectiveDate)
    || Number.isNaN(Date.parse(`${effectiveDate}T00:00:00Z`))
    || new Date(`${effectiveDate}T00:00:00Z`).toISOString().slice(0, 10) !== effectiveDate) {
  throw new Error('Supply a valid --effective-date=YYYY-MM-DD for publication.');
}
for (const page of pages) {
  page.body = page.body.replaceAll('{{PUBLICATION_DATE}}', effectiveDate);
}
// The existing Android landing page remains the site root. Compose into a
// separate local output; never replace site/ or publish the policy drafts.
let websiteHome;
const websiteAssets = new Map();
if (website) {
  websiteHome = await readFile(path.join(websiteSource, 'index.html'), 'utf8');
  for (const file of ['CNAME', 'icon-320.png']) {
    websiteAssets.set(file, await readFile(path.join(websiteSource, file)));
  }
  if (websiteHome.split('</footer>').length !== 2 || websiteHome.split('</style>').length !== 2) {
    throw new Error('The website footer/style boundaries changed; review the integration before building.');
  }
  const links = `<p class="ios-policy-links"><a href="ios/privacy/">iOS 隐私政策</a><a href="ios/terms/">iOS 使用条款</a><a href="ios/support/">iOS 帮助与支持</a></p>`;
  const notice = release ? '' : '<p class="ios-policy-draft">本地预览：iOS 页面为未发布草稿</p>';
  websiteHome = websiteHome
    .replace('</footer>', `${links}\n${notice}\n</footer>`)
    .replace('</style>', '.ios-policy-links{display:flex;justify-content:center;flex-wrap:wrap;gap:8px 20px;margin-top:14px}.ios-policy-links a{color:inherit;text-underline-offset:3px}.ios-policy-draft{margin-top:8px;color:#ffb74d}\n</style>');
  if (!release) websiteHome = websiteHome.replace('</head>', '<meta name="robots" content="noindex,nofollow">\n</head>');
}
const escape = text => text.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function sameSiteLinks(html, page) {
  // Keep policy links on the current host and under a GitHub project path.
  // Source drafts retain the planned public URLs for App Store metadata.
  const from = path.posix.join('ios', ...(page.lang === 'en' ? ['en'] : []), page.slug);
  return html.replace(/href="https:\/\/ztransfer\.top\/(ios\/(?:en\/)?(?:privacy|terms|support)\/)"/g,
    (_, target) => `href="${path.posix.relative(from, target) || '.'}/"`);
}
function shell({lang, title, content, slug}) {
  const en = lang === 'en';
  const prefix = en ? '../../' : '../';
  const other = en ? '../../' + slug + '/' : '../en/' + slug + '/';
  const stylesheet = website
    ? (en ? '../../assets/style.css' : '../assets/style.css')
    : (en ? '../../../assets/style.css' : '../../assets/style.css');
  const links = en ? ['Privacy','Terms','Support'] : ['隐私政策','使用条款','帮助与支持'];
  const notice = release ? '' : `<aside class="draft" role="note">${en
    ? 'Unpublished draft. Items marked for review must be resolved before release.'
    : '未发布草稿：带有待确认、待填写或待核实标记的内容必须在发布前落实。'}</aside>`;
  const nav = ['privacy','terms','support'].map((s,i)=>`<a href="${en ? '../' : prefix}${s}/"${slug===s?' aria-current="page"':''}>${links[i]}</a>`).join('');
  return `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
${release?'':'<meta name="robots" content="noindex,nofollow">'}
<meta name="description" content="${escape(en?'ZTransfer for iOS: privacy, terms and support.':'Z传 iOS 隐私、条款与支持。')}">
<title>${escape(title)} · ZTransfer</title><link rel="stylesheet" href="${stylesheet}"></head>
<body><a class="skip" href="#content">${en?'Skip to content':'跳转到正文'}</a>
<header><a class="brand" href="${en?'../../../':'../../'}">ZTransfer <span>iOS</span></a>
<nav aria-label="${en?'Information pages':'信息页面'}">${nav}</nav><a href="${other}" lang="${en?'zh-Hans':'en'}">${en?'简体中文':'English'}</a></header>
<main id="content">${notice}<p class="eyebrow">ZTRANSFER FOR iOS</p><h1>${escape(title)}</h1>
<article>${content}</article></main>
<footer>胡钰诗 · <a href="mailto:yuui226@163.com">yuui226@163.com</a></footer></body></html>\n`;
}
// Inputs are trusted repository drafts, not arbitrary user-provided HTML.
await rm(out, {recursive:true, force:true});
const assets = path.join(out, ...(website ? ['ios'] : []), 'assets');
await mkdir(assets, {recursive:true});
await copyFile(path.join(root,'style.css'),path.join(assets,'style.css'));
if (website) {
  for (const [file, bytes] of websiteAssets) {
    await writeFile(path.join(out, file), bytes);
  }
}
for (const p of pages) {
  const dest = path.join(out,'ios',...(p.lang==='en'?['en']:[]),p.slug);
  await mkdir(dest,{recursive:true});
  const headings = p.lang === 'en' ? p.body.replace(/^### /gm, '## ') : p.body;
  const body = headings.replace(markers, m => `<mark>${escape(m)}</mark>`);
  await writeFile(path.join(dest,'index.html'),shell({...p,content:sameSiteLinks(marked.parse(body), p)}));
}
await writeFile(path.join(out,'index.html'),website ? websiteHome : `<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZTransfer · iOS 支持</title><link rel="stylesheet" href="assets/style.css">${release?'':'<meta name="robots" content="noindex,nofollow">'}</head><body><main><p class="eyebrow">ZTRANSFER FOR iOS</p><h1>支持与使用信息</h1>${release?'':'<aside class="draft">未发布草稿 / Unpublished draft</aside>'}<p>连接相机，浏览与传输照片，使用实时监看和照片效果。</p><nav class="index-links"><a href="ios/support/">帮助与支持</a><a href="ios/privacy/">隐私政策</a><a href="ios/terms/">使用条款</a></nav><nav class="index-links" lang="en"><a href="ios/en/support/">Support</a><a href="ios/en/privacy/">Privacy Policy</a><a href="ios/en/terms/">Terms of Use</a></nav><p><a href="mailto:yuui226@163.com">yuui226@163.com</a></p></main></body></html>\n`);
await writeFile(path.join(out,'.nojekyll'),'');
await writeFile(path.join(root,website ? 'website-build-report.json' : 'build-report.json'),JSON.stringify({
  mode:release?'release':'preview', output:path.basename(out), effectiveDate,
  pages:pages.map(p=>`${p.lang}/${p.slug}`), unresolvedMarkers:pending,
},null,2)+'\n');
console.log(`Built ${pages.length + 1} pages in ${out}; unresolved markers: ${pending.length}.`);
