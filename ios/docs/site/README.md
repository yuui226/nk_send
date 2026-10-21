# GitHub Pages 官网与 iOS 网页交付

## 最新发布状态（2026-10-21）

六个中英文隐私、条款和支持页面已正式发布并通过HTTPS访问；原14处待定标记清零。官网提交为`3d138907edde01603e2ae57bf19a87ec37bc143d`，Pages为built。[发布记录](../iOS协议页定稿与发布记录-20261021.md)和[证据](../evidence/policy-publication-20261021.json)记录实际范围，下方早先“仅本地草稿/14标记/未上线”是历史。

根site/继续作为原安卓首页输入；website-dist/才包含iOS页及新增入口。远端现已多出这些文件，不再与根site/三个文件完整一致；后续必须核对最新远端并用生成器合并，不得用原三个文件覆盖已发布页面。正式重建同一政策版本时保留`--effective-date=2026-10-21`；修改实际政策时再更新生效日期。

这里是隐私、条款和支持网页的生成器。内容直接取自上一级已维护的文档，避免中文、英文、网页各改一份造成不一致。没有后端、在线字体、第三方脚本、上传表单、支付入口或网站统计。网页本身不设置 Cookie；托管方日志另按其政策处理。

2026-10-21本人确认剩余政策选择后，正文已定稿，正式生成结果为 **0处待定标记**。以顶部最新发布记录判断是否已上线；下方较早14处标记记录保留为历史。预览版本始终带草稿提示，不能上传代替正式输出。正式模式发现 `【待…】`、`[OWNER INPUT…]` 或 `[TECHNICAL REVIEW…]` 就失败，不覆盖已有 dist。此检查只能识别显式标记，不能代替人工确认真实政策与代码一致。

## 当前已确认的官网接入方式

正式生成现在要求 `--effective-date=YYYY-MM-DD`：首次公开时用实际发布日期；以后仅重建同一政策版本时保留原生效日期，实际更新政策时再调整日期。预览日期仅用于排版。正式模式检查标记和日期后才写输出。

**2026-10-21 后续发布结果：** 本人随后授权发布官网。现有 `site/` 三文件仍与远端一致，已重新触发 `yuui226/ztransfer-site` 的 Pages 部署，提交 `3987f2ab00505a5e55b8e0b5ad6727567cbd44ca`，结果 `built`。最新检查中强制 HTTPS 已开启，证书已批准且同时覆盖根域名与 www；公网首页、跳转和图标正常。新增 iOS 页面仍有待定事实，继续保持本地草稿，没有随此次原官网重新部署发布。下文较早“HTTPS 未开启”的快照已由最新证据更新，不能再作为当前待办。见[官网发布与安卓后端核对](../../../docs/发布与运维/官网发布与安卓后端核对-20261021.md)。

2026-10-21本人确认域名备案已通过，官网和iOS协议页继续使用GitHub Pages；只授权本地接入，内容定稿后才发布。本地官网源码在仓库根目录 `site/`，远端官网仓库为 `yuui226/ztransfer-site`。只读核对时，`index.html`、`CNAME`、`icon-320.png`三文件Git blob摘要完全一致。

本轮较早只读查询得到的Pages配置为`master`分支根目录、Custom domain=`www.ztransfer.top`、状态`built`；`https_enforced=false`、`https_certificate=null`，返回站点地址仍为HTTP。此为本次只读快照；没有修改Pages、DNS或证书。旧运维材料中“官网迁腾讯云”的决定已被本人本次选择替代，授权接口与APK托管保持各自安排。

本人随后明确：官网与后端本来就分开，现有配置已经完成，`api.ztransfer.top`指向后端。后续沿用这一既有架构，不再把“拆分官网/后端”或“配置API指向”当作待办；只为官网追加iOS页面。上面的Pages字段保留为当时的查询快照，发布时按实际访问结果复核，不用历史配置推断当前API状态。

合并模式保留安卓官网内容、图标和CNAME，只在输出的首页页脚增加iOS隐私、条款、支持三个链接；六个中英文页面仍在`/ios/`下，样式隔离到`/ios/assets/style.css`。本地官网源不被生成器覆盖。首页原有展示动画脚本保留，没有新增第三方脚本或数据收集代码。

本人仍需确定实际客服翻译服务、受众、日期及EULA方案等事实；中英文14处重复标记没有因备案通过而自动解决。正式家庭共享待商品后台核对。标记清零前只生成明显标注“本地预览/未发布草稿”的预览，正式输出仍失败。

## 独立政策预览（保留的辅助模式）

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
npm run release-build -- --effective-date=2026-10-21
```

这里的`dist/`是独立政策站输出，**不能用于覆盖现有官网**。本项目实际采用下一节的`website-dist/`合并发布方式。`build-report.json`只保留独立模式、页面与未解决项；内部报告、Markdown草稿和App源码均不放进公开网站仓库。

## 现有官网的本地合并（本次使用）

在本目录执行：

```sh
npm run website-preview
python3 -m http.server 8766 --bind 127.0.0.1 --directory website-preview
```

打开 `http://127.0.0.1:8766/` 可查看原官网及页脚新增入口。`website-preview/`只用于本地预览，不上传；它与`website-dist/`已被Git忽略。原来`preview-build`生成的是独立文档预览，可继续检查正文，但不要拿它的首页覆盖安卓官网。

内容定稿并解决正式商品依赖后，执行：

```sh
npm run website-release -- --effective-date=2026-10-21
```

只有成功后，`website-dist/`才是合并官网的发布目录。该目录包含原官网首页（增加三个iOS链接）、原图标与CNAME、`.nojekyll`以及`ios/`；没有App源码、内部Markdown、报告、node_modules或开发脚本。正式模式在改动输出前检查待填标记，失败时保留已有输出。当前没有生成正式目录，也没有推送或公开部署。

生成器只读取当前官网的三个已知文件。以后若官网新增图片或脚本文件，先同步合并清单并验证引用，不能直接假定这些文件会自动加入输出。上传前再次比较远端仓库，防止覆盖他人期间的改动。

文件对应关系：

| 正式文件 | 域名配置完成后的地址 |
|---|---|
| ios/privacy/index.html | https://ztransfer.top/ios/privacy/ |
| ios/terms/index.html | https://ztransfer.top/ios/terms/ |
| ios/support/index.html | https://ztransfer.top/ios/support/ |
| ios/en/privacy/index.html | https://ztransfer.top/ios/en/privacy/ |
| ios/en/terms/index.html | https://ztransfer.top/ios/en/terms/ |
| ios/en/support/index.html | https://ztransfer.top/ios/en/support/ |

## 定稿后发布到现有 GitHub 官网仓库

1. 使用已有 `yuui226/ztransfer-site`，无需新建仓库，不把App仓库公开。
2. 内容和正式配置确认后运行`npm run website-release`。失败时处理明确待填项，不上传`website-preview/`代替。
3. 核对远端期间有无变化后，将`website-dist/`里的内容同步到官网仓库根目录。保留当前`www.ztransfer.top`的CNAME，不上传整个`ios/docs/`或整个App仓库。
4. 沿用实际发布源`master`根目录，核对Pages构建成功；不要把已有官网切成独立政策首页。
5. 正式域名HTTPS准备好后，检查首页原下载链接及六个中英文iOS链接，再接入App和商店元数据。以后每次发布前重复核对内容与实际可访问状态。

公开仓库可使用GitHub Free的Pages；此站用于产品说明、下载链接和支持文字，不在Pages运行支付处理或动态授权接口。[发布来源](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)、[使用限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

## 你需要操作：域名

**DNS只能把整个域名或子域名指向托管方，不能只把`/ios/`路径指过去。** 现在已明确复用同一GitHub官网承载安卓首页和iOS页面，无需另设托管方。当前主域名为`www.ztransfer.top`；材料中的`https://ztransfer.top/ios/...`仍是规划地址，要在根域名HTTPS及跳转有效后才能采用。若最终使用带www的地址，再统一回填App和商店字段，不提前把未验证网址标为上线。

1. 在 GitHub 账号的 Pages 设置中验证域名所有权，按它给出的 TXT 内容到域名管理平台添加记录。
2. 在现有网页仓库 Settings → Pages 核对Custom domain仍为`www.ztransfer.top`。不因材料原先写了根域名就擅自删除或改写；按官方说明同时配置根域名到www的访问。
3. 核对`www`的CNAME指向`yuui226.github.io`（不含仓库路径），再核对根域名（通常为`@`）指向GitHub Pages。当前官方A记录为 `185.199.108.153`、`185.199.109.153`、`185.199.110.153`、`185.199.111.153`；实际操作前按官方页面复核。不要设置通配符 `*`。
4. 不要删除邮件 MX/TXT 等不相关记录。如果根域名已有其他网站 A/CNAME，先解决用途冲突，再替换对应记录。
5. 等待 DNS 检查和证书签发；随后启用 Enforce HTTPS。验证中文、英文六个链接均能直接打开，不要求登录、不出现证书警告。

按照 GitHub 建议先在平台绑定域名，再修改指向；DNS 生效可能需要时间。域名备案、App 备案和 GitHub 托管是不同事项，本文件不把其中一项当作其他项已完成。[自定义域名](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)、[HTTPS](https://docs.github.com/en/pages/getting-started-with-github-pages/securing-your-github-pages-site-with-https)

## 发布后助手完成

- 检查 HTTP 状态、HTTPS、手机访问、导航、语言切换及全部正文。
- 将真正可访问的政策和条款地址写入 iOS 工程的 `ZTransferPrivacyPolicyURL`、`ZTransferTermsOfUseURL`，同时维护 `project.yml` 与生成工程。
- 验证 App 购买页链接可打开，再填 App Store Connect 对应网址。
- 若最终不是根域名托管，在所有中英文材料里统一改地址，不留混用。

## 现有官网接入验证（2026-10-21）

本地合并7页已生成。原官网源、图标/CNAME及首页main正文保持；首页只追加页脚入口、对应样式和预览提示。站点根路径及GitHub项目路径的本地链接/锚点核对通过。Chromium本地HTTP检查7页×浅深色14个375×812状态，均无横向溢出；首页进入中文隐私、切英文、返回原官网流程通过。手机/桌面页脚及中英文政策4张实际截图已核看。临时HTTP服务和浏览器已关闭。

正式合并命令因14处标记按预期失败，没有创建website-dist，也没有覆盖预览/报告。中英文隐私正文已如实补充原官网的本地展示动画脚本；没有新增追踪服务。仅本地Chromium，不代表手机Safari、公网或App链接验收。完整范围、只读远端快照、来源哈希和截图见[接入验证记录](../evidence/website-integration-20261021.json)。

## 独立政策预览的既往验证记录

2026-10-21本次独立材料复核重新读取了 Apple 官方字段、审核资料、隐私与订阅要求，没有沿用前一轮“已完成”的状态。修复英文商店/政策链接指向中文页，以及 GitHub 项目地址下正文仍跳往未上线自定义域名的问题；`build.mjs` 将正文本站链接转换为对应页面的相对地址。补齐原有客服翻译待确认项中的接收方保护与发送个人信息给第三方 AI 前的明确许可要求，没有虚构服务商、同意记录或已上线网站。

本次用已有本地 Node / marked 17.0.5生成 **7页、14处未解决标记**。49个本地文件引用、6个页内锚点有效；同一批引用在站点根路径与 `/ztransfer-pages/` 项目路径各验证一次，共98项路径解析通过。另有23个外部/邮件引用；这不等于全部外网链接实时可访问。内部记录未进入网页，七页无 script、form 或 iframe，正文不再遗留指向规划域名的本站绝对链接。正式模式按预期返回 exit 1、`Publication blocked: 14 unresolved markers`，没有创建或覆盖 dist，也未覆盖 preview 报告。详细字段长度、来源、输入哈希和检查范围见[verification-report.json](verification-report.json)。本轮没有执行 App 构建、模拟器、浏览器截图或公网部署。

未解决项包含12处本人标记和2处正式家庭共享技术标记；本人标记有中英文重复，生效日期又在政策和条款分别出现，另有翻译服务、QQ、受众与 EULA 决定，并非12个不同问题。家庭共享须会员生效并创建商品后核实，不构成购买会员的先决条件；先准备内容和部署文件，再完成后台核对及正式网页发布。标记之外仍要检查已上线事实、可访问网址、App法律入口和实际服务商处理，不能仅凭标记清零保证发布合规。

此前同日已按 1.98 / build 1 的实际队列计数、监看计时、水印配置与购买页，对齐中英文免费额度及高级版权益，去除了两份条款中相同的宽泛技术标记；代码依据与历史测试适用范围见[条款内部记录](../使用条款草稿.md#内部确认事项)。此前检查的43个本地引用、6个锚点、27个外部/邮件引用及12处正文属于当时版本，本次以以上最新检查数量为准。本人事实与正式家庭共享配置未被替填。

此前 2026-10-20 的文案更新已同步“城市和地区需同时关闭才停止照片地名查询”、兼容性说明和英文续订建议，并将既有 EULA 待确认事项加入中文正文；该轮标记由 15 处变为 16 处，多出的是同一 EULA 决定的中文标记，并非新增本人决定。本次解决中英文额度/权益标记后由 16 处降为 14 处。

本轮仅更新文案，没有重拍截图。此前 2026-10-20 的 1280×720 桌面浏览器已验证中英文政策与支持页切换；375×812 小屏下，七页分别检查浅色和深色，共 14 个状态，全部 `scrollWidth == innerWidth == 375`，14 张截图已逐张查看，未见内容覆盖或边界裁断。已有截图对应此前文案版本，不将其写成这次全部文案的新增视觉验收。

已有证据：[小屏测量](../evidence/site-mobile-20261020.json)、[截图清单与哈希](../evidence/site-mobile-images-20261020.json)，图片保存在 `evidence/mobile/`。以上针对当前草稿、本地 Chromium 和 file URL；真实手机 Safari、正式内容替换后的页面及部署后的 HTTPS/外网可访问性仍须检查。不要为了核销步骤把未发布页面写为“已上线”。

当前正式构建被未解决的政策标记阻止是预期行为。需要本人提供或决定的事实集中见[材料清单的交接分工](../上架所需信息与材料.md#本轮材料交接与剩余分工)，不需要把中英重复标记逐项再回答一次。
