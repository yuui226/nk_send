# 边框品牌矢量素材收集

收集日期：2026-09-28。已将下列 17 个品牌接入 App 的边框 Logo 模式。此目录为来源存档，不随 APK 打包；App 仅包含选用的路径。

## 已收集

- 相机／影像：Nikon、Sony、Fujifilm、Panasonic、Leica、DJI。
- 手机：Apple、Samsung、Huawei、Xiaomi、OPPO、vivo、HONOR、OnePlus、Google、Motorola、Nokia。
- 共 17 个品牌、18 个 SVG；Nikon 同时保留官方彩色版和第三方单色版作对照。App 继续使用现有官方彩色尼康标志。
- `nikon-official.svg`：[尼康官网原始文件](https://www.nikon-image.com/common2/img/mod-header/logo_01.svg)。
- 其他 SVG：[Simple Icons](https://github.com/simple-icons/simple-icons) 收集的路径素材，不是我们重画，也不能称为各品牌官方直接提供。`metadata-source.json` 保留上游品牌来源、颜色及规范入口；`sources.json` 记录抓取结果（Apple 首次失败，随后补取成功）。
- 单色候选不等于最终彩色标志；例如富士局部红色、Google 多色、小米底色，以及品牌组合关系需在接入时逐一核对官方版本。HONOR 也需确认采用哪个版本。

## 补充官方入口／待收集

- [Canon 官方标志下载](https://www.usa.canon.com/pro/resources/download-official-canon-logo)：已找到入口，未保存矢量文件。
- [Samsung 官方品牌标志](https://www.samsung.com/uk/about-us/brand-identity/logo/)。
- [Xiaomi 官方媒体资源](https://www.mi.com/global/about/mediakit/)。
- [HONOR 官方标志规范及 AI 下载](https://www.honor.com/pk/brand-guideline11/basics/logo/)。
- 待补：Hasselblad、Ricoh／Pentax、OM SYSTEM／Olympus、Sigma、GoPro、realme，以及按实际需求选择的 REDMI、iQOO。不要把检索不到的条目当作已收集。
- 上游开源仓库许可不等于品牌商标授权，正式选用时保留各品牌来源与使用规范；不把候选库描述成统一获得品牌授权的素材。

## 体积实测与实现建议

- 18 个 SVG 原文件合计 32,141 字节（31.4 KiB）。内存中按 ZIP DEFLATE 压缩、含文件条目开销共 15,887 字节（15.5 KiB）。已检查均可解析为 XML，尚未逐个视觉验收。
- 这只是素材体积，不是 APK 增量测量；转为 Android 路径后的代码、资源表和布局代码仍有开销。二三十个简洁标志预计为几十 KB 级，最终以同配置 Release 对比为准。
- 只提取选用路径，复用现有 Canvas／PathParser；不引入整个图标库、SVG 运行时或多分辨率位图。
- 品牌文字模式继续保留；Logo 模式按照片 EXIF Make 匹配对应标志，未知品牌回退文字。文字商标本身就是 Logo，不额外拼造图案。
- 方形／圆形图案与横长文字标志分别适配视觉高度、最大宽度和留白；不要全部塞入尼康的正方形尺寸。图片品牌不是手机运行设备品牌，也不因联名镜头而替换 EXIF 品牌。

## 接入记录

- 共用 `FrameBrandLogo` 处理品牌前缀替换、宽度测量、垂直边界和绘制，各边框与参数海报统一使用；未知品牌回退文字。
- 尼康保留现有官方黄色矢量。其他 16 个品牌使用已收集的单色矢量，跟随边框文字颜色，不将单色路径随意染成所谓官方彩色组合。
- 素材按真实路径边界去除 SVG 的正方形空白；保持宽高比。Apple 高度系数 1.08；Huawei、Xiaomi、Leica、Motorola、OnePlus、Google 为 1.0；DJI 为 0.95；OPPO、vivo 为 0.82；Sony、HONOR 为 0.80；Fujifilm、Samsung、Nokia 为 0.78；Panasonic 为 0.72。系数乘以各边框已有的 Logo 比例，横向宽度不超过原品牌文字预算。
- 矢量路径及其边界按品牌首次绘制时初始化一次；判断品牌支持不触发 Android 路径解析。没有新增图标库、图片解码或网络依赖。
- Debug Kotlin 编译通过；未打包、未运行模拟器。各品牌在手机上的实际视觉效果待验。
- 复查补齐 Logo 渲染缓存版本（v3），避免新样式复用旧版成片；更新旧尼康专用测试，覆盖所有已支持品牌、隐藏品牌、文字模式和未知品牌回退。`PhotoFrameMetadataSettingsTest` 共 17 项通过；不代表设备上的路径绘制和视觉验收已完成。
