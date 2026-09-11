# W11—W20：连接、STA-direct、预览与分批扫描

基线：research/ios 的 e5dbadb（W07—W10已推送）。本文件说明随后 W11—W20 的实现与验收边界；正式计分以 [剩余任务进度表](./iOS剩余任务进度表.md) 为准。

## 所有者与 Android 边界

- 沿用 CameraHandshakeProbe 唯一会话、原 PTP 命令门、事件观察、CameraCatalog、原片队列和保存目标；没有另造相机、连接、队列或事件订阅。
- Android 不是零文件变化。三个文件只做受控提取：HomeScreen 的卡片时间函数/常量；NikonCamera 的 STA 媒体纯解析；CameraViewModel 的缩略图黑边判定。原网络收发、锁、服务、传输、重试与位图读写留在 Android。
- home_card_extraction.py、sta_media_extraction.py、thumbnail_crop_extraction.py 分别校验完整 Android 文件和完整公共提取结果。QuickTime 秒数解析共享，Android 原本机时区格式化保留。
- ThumbnailFillQueue 仅增加批次追加方法，Android 已有调用不改；Native 包装器与图片预算仅由 iOS 使用。原 EXIF 五数值入口保留，嵌入 JPEG 元数据补充只在 Native 的 readMetadata 入口启用。
- 不改版本、code、Gradle依赖、签名、dist/build.bat 或 dist-debug/build-debug.bat；本轮不打包/发布 APK。

## 每项实际行为

| 项 | 实际入口和规则 | 主要边界 |
|---|---|---|
| W11 | 真实 ready 后按原 500/620/760ms 曲线推进成功效果，单次打开文件页；失败、取消、旧请求完成不导航；配对等待有实际回调 | 不用预设进度冒充连接成功。分批扫描上线后不再等整目录才能打开页面 |
| W12 | 先标准 STA 兼容探测，检查首/中/末 ObjectInfo；失败时以 GetSize + 非空 partial 证明 direct；必要时一次应用模式切换，失败回退 | 不凭相机名称猜能力；不支持仍报失败，不借 AP 冒充成功 |
| W13 | Nikon 日期/文件名索引、头部与 MakerNote 文件编号复用 shared；可靠卡槽才显示过滤，混叠句柄只读一次 | ObjectInfo缺失不能伪造保护标记/卡槽；失败不清空上一份有效目录 |
| W14 | direct 原片仍走原片队列、共享分块规则、64位 offset；高速模式也强制适用 partial，首块不支持的完整下载回退沿用共享规则 | 续传不能回退重读整片；超长块/不足总长不能成功；原片字节不改 |
| W15 | 同一优先窗口先 FHD，LargeThumb 要有声明；Busy 与不支持分别处理；JPG 再按共享 MPF 读取独立 JPEG 范围；缩略图只取 EXIF 内嵌图 | 不为生成预览下载整个主图；空/坏预览不是传图成功 |
| W16 | RAW 缩略图取最小索引 JPEG、同会话偏移提示、240KiB至16MiB递增前缀降级；FHD采用独立候选与1600长边判定；本地RAW复用已验证描述符和按像素数选图 | 短读可重试，确定缺图才记源端 miss；缩略图裁黑边用原 Android 算法；FHD和原片不裁 |
| W17 | MOV/MP4先头部内嵌JPEG，再最多8MiB前缀提帧；缺视频日期时最多256KiB尾部；原有视频信息/占位和原片保存、分享/系统打开复用现有页面与所有者 | 不新增播放器/遥控录像；AVFoundation与Android系统解码器对损坏或不支持编码的支持可能不同，须Mac样本验收 |
| W18 | 标准标签、ISO、镜头、日期、已有GPS继续共享格式化；补 RAW 缺尺寸目录的内嵌JPEG属性读取；目录占用、大小端、区域日期与非ASCII字段用实际AndroidX作对照 | 不任意扫描MakerNote里的JPEG当元数据；不增加GPS发送；私有相机样本仍须Mac验收 |
| W19 | 相机缩略图保持像素方向，先原尺寸裁黑边再做128/512显示缩放；诊断decode单独自动EXIF转正；原片仍全分辨率；色彩/alpha/8方向/取消/来源冻结用Apple样本验证 | 本地图片字节读取256MiB，原片像素96×1024²、缩略图32×1024²上限；超限拒绝，不静默缩小原片。视频/原片复制仍分块流式，不受图片字节读取上限限制 |
| W20 | 每20个可见目录行发布临时快照、追加缩略图工作；完整扫描才确认删除/自动新增；文件页可跟随首次扫描，失败恢复旧快照 | 事件扫描仍是推测式事务，不提前发布；日期优先、忙时让路、失败重试复用原规则；关闭页只释放页请求，关闭连接释放会话 |

## EXIF 证据与已知限制

Windows 可运行 iosApp/scripts/check_exif_rational_oracle.py，它直接加载缓存中的 AndroidX ExifInterface 1.3.7 AAR，仅替换日志类，不改变 Android 项目配置。AAR SHA256：

0e8f1832266c5b0667ad3d3b1098e624e49a09075493a014a7e88af01fd30ad3

新增对照包括 RAW 主目录有/无尺寸、嵌入 JPEG、无关 MakerNote、大小端及 ISO/文本/日期。保留一个原库细节：其 retrieveJpegImageSize 将 JPEG offset 再作为缓冲区长度；这里锁定实际行为，不趁迁移修改 Android。读取仍受预算与取消约束，不承诺任意损坏文件完全相同。

ImageIO负责Apple平台读取和编码，shared负责产品字段/选择/裁切规则。Windows能验证共享运算、数据样本与接线，不能证明Apple SDK导出、色彩显示、编解码器覆盖、峰值内存或真机PTP时序。

## Mac 必须补验

按 [Mac首次操作指南](../测试与验证/iOS首次Mac操作指南.md) 先生成框架并完整编译测试，再跑：

1. AP、标准STA、需要配对的STA-direct：首次/已有配对、拒绝配对、失败回退、取消、断开再连；成功动画一次，扫描未完成也能打开文件页。
2. 双卡普通与备份/混叠目录：文件名、日期、卡槽、去重、缺ObjectInfo、刷新失败保留旧行。
3. direct JPG：FHD成功、Busy、不支持、MPF独立图、缺/坏APP1缩略图；同时传原片时预览交互不串线。
4. RAW：相机小缩略图、FHD、本地RAW索引/无索引、>2GiB偏移、不完整前缀、裁黑边；保存文件哈希不变。
5. MOV/MP4：内嵌JPEG、有/无可解首帧、日期在尾部、>4GB信息、原片保存后分享或系统打开；不得出现照片解码成功假象。
6. EXIF：大小端、目录共用偏移、RAW内嵌属性、原始/数码/文件日期、非拉丁名字、法语/阿拉伯数字、既有GPS经纬度和海拔。
7. 色彩和生命周期：sRGB、Display P3、灰度、透明PNG、8方向、旋转、跨页固定原片来源、取消/关闭/内存压力；用Instruments记录45MP实拍和连续预览峰值，不仅看能显示。
8. 大目录：第一批出现早于全量完成；日期筛选优先、边扫边填、预览/传输让路；中途删片、断网、重试、退出页面/重连，旧快照及缓存不被迟到结果覆盖。

所有 XCTest/Native 图片样本必须在 Mac 运行；源码方法数不是通过数。若失败，重开对应 W 项，不用 WIN-DONE 掩盖问题。

## 源码保护与本批验证

本批新接线有当前契约检查与行为样本；历史精确逆转换仍继续执行。transfer_completion_wiring.py 用固定的完整文件 SHA256（UTF-8/LF）替代越来越长的 Swift 文本副本：任何字符变动先失败，匹配之后才从 e5dbadb 读取旧文件进入历史守卫。每个已登记文件有额外的篡改拒绝测试；不是无条件返回基线、跳过比较。

2026-09-08最终验证：串行Gradle BUILD SUCCESSFUL in 2m50s，744项shared+317项app=1061项测试零失败/错误；common metadata、Android Release Kotlin编译、shared/app Debug Lint通过（shared 0问题，app 0错误/179 Warning）。340项Python、工程结构、原UI/完整提取守卫及git diff --check通过；实际AndroidX 1.3.7对照3213项PASS。42个App Swift/8个测试文件内430项XCTest和另17项Native图片测试尚未在Mac执行。W11—W20在e5dbadb上实现并随本次提交归档，主进度20/50；未打包APK，未将Apple源码检查记为编译或真机通过。

Apple接口依据：[AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator)、[取消提帧](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/cancelallcgimagegeneration())、[生成尺寸](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/maximumsize)、[仅在缺少缩略图时生成主图缩略图的开关](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimageifabsent)。这些API文档不是本项目运行证据。
