# GitHub Pages 静态网页交付

这里是隐私、条款和支持网页的生成器。内容直接取自上一级已维护的文档，避免中文、英文、网页各改一份造成不一致。没有后端、在线字体、第三方脚本、上传表单、支付入口或网站统计。网页本身不设置 Cookie；托管方日志另按其政策处理。

当前仅生成 **preview 草稿**，不可作为已发布政策提交。正式模式发现 `【待…】`、`[OWNER INPUT…]` 或 `[TECHNICAL REVIEW…]` 就失败，不覆盖已有 dist。此检查只能识别显式标记，不能代替人工确认真实政策与代码一致。

## 你现在无需操作

先由助手处理技术标记、检查页面和准备文件。本人已确认客服记录结案后保留 12 个月、到期删除不再需要内容，以及 AI 翻译前去除个人识别信息。定稿时仍需确定实际客服翻译服务、受众、日期及 Apple 标准 EULA 方案；不能只删除标记而不落实内容。

2026-10-20 本地浏览器复查：中文隐私页首屏已查看，中英文隐私切换、英文支持入口及支持页中文切换实际导航成功；英文支持首屏截图保存在 `evidence/support-en-preview.png`。本轮视口为 1280×720、浅色，只证明这些页面和导航在该环境的表现，不代表手机、深色或公网部署已通过。

## 本地生成

普通 Node.js 环境，进入本目录后：

```sh
npm install
npm run preview-build
```

`marked` 固定为 17.0.5。本机助手也可使用 Codex 自带的同版 marked，无需安装；通过 `ZTRANSFER_MARKED_MODULE` 指定其 `lib/marked.esm.js` 绝对路径。

预览：

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory preview
```

打开 `http://127.0.0.1:8766/`。停止预览用 Ctrl+C。这个本机地址别人打不开，不是正式网址。

定稿后：

```sh
npm run release-build
```

成功后 `dist/` 就是要上传的文件；**上传 dist 里面的内容，不是整个 dist 文件夹，也不是整个 App 仓库。** `build-report.json` 保留模式、页面与未解决项。不要把该内部报告、Markdown 草稿或 App 源码放进公开网站仓库。

文件对应关系：

| 正式文件 | 域名配置完成后的地址 |
|---|---|
| ios/privacy/index.html | https://ztransfer.top/ios/privacy/ |
| ios/terms/index.html | https://ztransfer.top/ios/terms/ |
| ios/support/index.html | https://ztransfer.top/ios/support/ |
| ios/en/privacy/index.html | https://ztransfer.top/ios/en/privacy/ |
| ios/en/terms/index.html | https://ztransfer.top/ios/en/terms/ |
| ios/en/support/index.html | https://ztransfer.top/ios/en/support/ |

## 你需要操作：GitHub

1. 登录你自己的 GitHub 账号。建议新建仅存放对外网页的公开仓库，例如 `ztransfer-pages`；不把当前 App 代码改成公开。
2. 内容定稿、正式生成成功后，将 `dist/` 内的 `index.html`、`assets/`、`ios/` 和 `.nojekyll` 上传到该仓库根目录。网页是公开的，只放计划公开的信息。
3. 仓库 Settings → Pages，选择从分支发布，选择实际分支及根目录，保存。
4. 等 Pages 部署成功。先测试 GitHub 提供的站点地址：在它后面加 `ios/privacy/` 等路径。相对导航支持项目仓库路径，不依赖域名已绑定。
5. 之后每次更新，只上传新生成的正式文件；保留 GitHub 为域名创建的 `CNAME` 文件，不用本地生成结果误删它。

这部分使用公开仓库可以采用 GitHub Free。页面只提供说明和支持，不将其改为交易、收费或 SaaS 系统。[发布来源](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)、[使用限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

## 你需要操作：域名

**DNS 只能把整个域名或子域名指向托管方，不能只把 `/ios/` 路径指过去。** 如果 `ztransfer.top` 根域名还要给别的网站使用，需要先确定由哪个服务统一承载；不要直接覆盖现有解析。只使用本网站时，可将根域名指向 GitHub Pages。也可另用 `support.ztransfer.top`，但必须同步修改所有政策、App 和商店 URL。

1. 在 GitHub 账号的 Pages 设置中验证域名所有权，按它给出的 TXT 内容到域名管理平台添加记录。
2. 在网页仓库 Settings → Pages → Custom domain 填 `ztransfer.top`，保存。
3. 到 DNS 管理平台配置根域名（一般主机记录为 `@`）到 GitHub Pages。当前官方 A 记录为 `185.199.108.153`、`185.199.109.153`、`185.199.110.153`、`185.199.111.153`；实际操作前按官方页面复核。不要设置通配符 `*`。
4. 不要删除邮件 MX/TXT 等不相关记录。如果根域名已有其他网站 A/CNAME，先解决用途冲突，再替换对应记录。
5. 等待 DNS 检查和证书签发；随后启用 Enforce HTTPS。验证中文、英文六个链接均能直接打开，不要求登录、不出现证书警告。

按照 GitHub 建议先在平台绑定域名，再修改指向；DNS 生效可能需要时间。域名备案、App 备案和 GitHub 托管是不同事项，本文件不把其中一项当作其他项已完成。[自定义域名](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)、[HTTPS](https://docs.github.com/en/pages/getting-started-with-github-pages/securing-your-github-pages-site-with-https)

## 发布后助手完成

- 检查 HTTP 状态、HTTPS、手机访问、导航、语言切换及全部正文。
- 将真正可访问的政策和条款地址写入 iOS 工程的 `ZTransferPrivacyPolicyURL`、`ZTransferTermsOfUseURL`，同时维护 `project.yml` 与生成工程。
- 验证 App 购买页链接可打开，再填 App Store Connect 对应网址。
- 若最终不是根域名托管，在所有中英文材料里统一改地址，不留混用。

## 当前验证记录

2026-10-20 已生成首页及六份内容页；43 个本地 HTML 引用检查通过。中文政策已在浏览器实际渲染，英文切换成功；小屏、深色及最终发布版本尚需检查。预览仍有未解决标记，正式构建应当拒绝。
