# 官网启用 HTTPS 证书

## 2026-10-21 最新实测：官网 HTTPS 已完成

本次重新读取 Pages 配置，`https_enforced=true`，证书 `approved`，同时覆盖 `ztransfer.top` 和 `www.ztransfer.top`。公网 HTTPS 正常，HTTP 和根域名正常跳转至 `https://www.ztransfer.top/`。本人授权后已重新部署原官网代码，Pages 结果 `built`；新增 iOS 政策页仍是本地草稿。无需重复启用 HTTPS，较早的失败现象保留为历史。证据及后端独立核对见[本次记录](../发布与运维/官网发布与安卓后端核对-20261021.md)。

## 2026-10-21 最新决定（以本节为准）

本人已确认 `ztransfer.top` 域名备案通过，并再次确定官网根域名 `ztransfer.top` 与 `www.ztransfer.top` 继续使用GitHub Pages，iOS政策也放在同一官网。复用 `yuui226/ztransfer-site`，本地网站源为仓库根 `site/`；保留现有安卓首页与内容，只追加iOS路径。允许先开始本地接入，内容定稿后才发布。

下方旧计划中“官网迁到腾讯云”“不得恢复GitHub Pages”及因此暂停官网HTTPS步骤的决定，对官网已失效；保留原文仅供追溯，冲突时以本节为准。域名备案通过不等于App备案、网站发布、GitHub域名绑定或HTTPS已完成，实际访问与配置需按当前结果核对。

2026-10-21本人进一步确认：官网与后端原本就是分离架构，`api.ztransfer.top` 指向后端的配置已经做好；不能再依据下方旧迁移计划将后端描述为仍待切换。这是本人确认的当前状态，本轮未执行迁移，也不据此推断具体后端IP或所有接口均已验收。

API/授权服务迁移未由本轮执行或变更：不据此改动它的目标、账号、现有服务、数据库、密钥或接口解析。下方与API/授权服务有关的历史计划和状态保留，不能把官网托管决定当成该服务已经迁移或需要回退。

以下保留原计划及当时事实。

创建日期：2026-10-13

状态：先不做。2026-10-14 起，`ztransfer.top` 和 `www` 的解析已为备案暂停。备案通过后官网改到腾讯云，按 [备案通过后迁移授权服务](备案通过后迁移授权服务.md) 办理，不要把解析恢复到 GitHub Pages，也不要按下面的步骤打开 GitHub HTTPS。

## 现象

用 HTTPS 打开 `ztransfer.top` 或 `www.ztransfer.top` 时，浏览器提示连接不安全。服务器拿出的证书是 GitHub Pages 的 `*.github.io`，里面没有这个域名。

备案通过不会消掉这个提示。备案不签发证书，也不会改 GitHub 上的证书。

2026-10-13 核对结果：

- 官网仓库是 `yuui226/ztransfer-site`，Pages 从 `master` 发布，自定义域名是 `www.ztransfer.top`。
- Pages 设置里 **Enforce HTTPS** 未勾选，GitHub 记录的地址仍是 `http://www.ztransfer.top/`。
- `www.ztransfer.top` 的 CNAME 指向 `yuui226.github.io`。
- `ztransfer.top` 的 A 记录是 GitHub Pages 的四个地址：`185.199.108.153`、`185.199.109.153`、`185.199.110.153`、`185.199.111.153`。
- 域名没有 CAA 记录，不阻挡 Let's Encrypt。

阿里云解析不用改。不要把官网域名指到新服务器，那是备案通过之后的另一件事。

## 操作

1. 用 `yuui226` 登录 GitHub，打开 <https://github.com/yuui226/ztransfer-site/settings/pages>。
2. 确认 **Custom domain** 是 `www.ztransfer.top`。不要删掉重填。
3. 勾选 **Enforce HTTPS**。
4. 如果勾选是灰的，GitHub 还在向 Let's Encrypt 申请证书。快则几分钟，慢则大约一天。过一会儿刷新设置页，勾选亮了再勾上。

## 做完后检查

用浏览器无痕窗口打开下面两个地址，都不应再报不安全：

- `https://www.ztransfer.top`
- `https://ztransfer.top`，应跳到带 `www` 的地址

点开证书，颁发给的名字应包含 `www.ztransfer.top`，颁发机构是 Let's Encrypt，而不是 `*.github.io`。
