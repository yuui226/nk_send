# 官网启用 HTTPS 证书

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
