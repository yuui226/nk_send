# GitHub Pages 静态网页交付

这里是隐私、条款和支持网页的生成器。内容直接取自上一级已维护的文档，避免中文、英文、网页各改一份造成不一致。没有后端、在线字体、第三方脚本、上传表单、支付入口或网站统计。网页本身不设置 Cookie；托管方日志另按其政策处理。

当前仅生成 **preview 草稿**，不可作为已发布政策提交。正式模式发现 `【待…】`、`[OWNER INPUT…]` 或 `[TECHNICAL REVIEW…]` 就失败，不覆盖已有 dist。此检查只能识别显式标记，不能代替人工确认真实政策与代码一致。

## 你现在无需操作

先由助手处理技术标记、检查页面和准备文件。本人已确认客服记录结案后保留 12 个月、到期删除不再需要内容，以及 AI 翻译前去除个人识别信息。定稿时仍需确定实际客服翻译服务、受众、日期及 Apple 标准 EULA 方案；不能只删除标记而不落实内容。

2026-10-20 已完成桌面导航及 375×812 小屏浅色/深色预览复查：七页共 14 张小屏截图已查看，未发现横向溢出或内容覆盖。证据及范围见文末。它们是本地 Chromium 检查，不代表已发布、HTTPS 正常或手机 Safari 已验收。

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

2026-10-21 已使用现有本地 Node/marked 重新生成首页和六份内容页，没有联网安装依赖。按当前 1.98 / build 1 的实际队列计数、监看计时、水印配置与购买页，对齐了中英文免费额度及高级版权益，去除了两份条款中相同的宽泛技术标记；代码依据与历史测试的适用范围见[条款内部记录](../使用条款草稿.md#内部确认事项)。`build-report.json` 当前为 preview，**14 处未解决标记**，其中包含中英文重复项。本人确认与正式家庭共享配置没有被替填。

本轮检查 43 个本地文件引用、6 个页内锚点全部有效，另识别 27 个外部或邮件引用；12 处本次核对的正文已出现在目标 HTML，内部技术记录没有进入对外页面，七页均无 script、form 或 iframe。正式模式以 `Publication blocked: 14 unresolved markers` 返回 exit 1，没有创建 `dist/`，也没有覆盖 preview 模式的报告。该失败是预期发布保护；没有删除未解决标记来绕过保护、没有发布网站。

此前 2026-10-20 的文案更新已同步“城市和地区需同时关闭才停止照片地名查询”、兼容性说明和英文续订建议，并将既有 EULA 待确认事项加入中文正文；该轮标记由 15 处变为 16 处，多出的是同一 EULA 决定的中文标记，并非新增本人决定。本次解决中英文额度/权益标记后由 16 处降为 14 处。

本轮仅更新文案，没有重拍截图。此前 2026-10-20 的 1280×720 桌面浏览器已验证中英文政策与支持页切换；375×812 小屏下，七页分别检查浅色和深色，共 14 个状态，全部 `scrollWidth == innerWidth == 375`，14 张截图已逐张查看，未见内容覆盖或边界裁断。已有截图对应此前文案版本，不将其写成这次全部文案的新增视觉验收。

已有证据：[小屏测量](../evidence/site-mobile-20261020.json)、[截图清单与哈希](../evidence/site-mobile-images-20261020.json)，图片保存在 `evidence/mobile/`。以上针对当前草稿、本地 Chromium 和 file URL；真实手机 Safari、正式内容替换后的页面及部署后的 HTTPS/外网可访问性仍须检查。不要为了核销步骤把未发布页面写为“已上线”。

当前正式构建被未解决的政策标记阻止是预期行为。需要本人提供或决定的事实集中见[材料清单的交接分工](../上架所需信息与材料.md#本轮材料交接与剩余分工)，不需要把中英重复标记逐项再回答一次。
