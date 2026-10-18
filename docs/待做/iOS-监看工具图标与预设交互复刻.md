# iOS 监看工具图标与预设交互复刻

用户要求：先提交已验证修改，再逐项检查所有小工具图标，完整复刻安卓预设功能的交互。前序性能/监看修复已提交 `df455558`，不推送。本轮主代理独立处理。

基准：当前本机 Android `RemoteScreen.kt`、`RemoteViewfinderFeatures.kt`、`RemoteExposureAnalysis.kt`、`RemotePictureControlPanel.kt`、`PictureControlPresetChooser.kt`、`PictureControlToolState.kt` 和实际 Compose 2023.10.01 / Material Icons 1.5.4；仅改 iOS，安卓保持基准。保留已验收监看逐帧观察、后台解码、原有相机写入/回滚/取消/业务作用域。

## 任务

当前 6/6 开发侧完成；源码、组件渲染、模型与协议专项已核对，真机外观/系统目录选择/相机实际写入的未验证边界见下文。

| 编号 | 范围 | 完成证据 | 状态 |
|---|---|---|---|
| I01 | 20项工具及管理/可见性/Dock/录制状态图标完整对照 | 下列完整源码/动态状态清单，已读 RemoteToolLayoutTest | 已完成 |
| I02 | 静态图标、尺寸、文字与预设四色矢量 | 20项实际像素/路径检查和导出图已查看，实际1.5.4路径与XML | 已完成 |
| I03 | RGB/伪色/倍率/锁定等状态、管理与横屏复用、材质保色 | 三类颜色像素、5材质×明暗保色；共享20项入口，布局/控件回归通过 | 已完成 |
| I04 | 预设开窗/锚点/加载/退出与层级 | 实际宿主开合/层级、延迟失败、关闭/后台写门控和原生产监看逐帧测试通过 | 已完成 |
| I05 | 九槽/编辑/分类/文件夹/清除/返回页及转换 | 源码流程对照、真实宿主页切换/高度/选中行像素、目录返回状态、动画快速打断及既有读写/取消/目录专项通过 | 已完成 |
| I06 | 综合复核与交付记录 | 70个不同专项有最终通过证据、生成器可重复生成、差异检查通过；真机边界明确保留 | 已完成 |

## 初查差异（不是完成声明）

- 预设：Android双层22dp原始矢量+独立四色，iOS使用camera.filters 19pt；预设当前为NavigationStack/List系统sheet，Android为RemoteChoicePopup锚定弹窗/槽位编辑与确认内页，含180ms淡入延迟40ms、140ms淡出与0.85/400尺寸弹簧，转场稳定后才允许操作。
- 波形：Android折线路径并按RGB档分三色，iOS固定W文字。
- 直方图：同为5条，但iOS没有RGB图标状态。
- 曝光辅助：Android斑马/伪色图标随档位变化，iOS一直是斑马。
- 对焦框：Android20×18圆角框+AF，iOS四角框且没有AF。
- 旋转：Android20dp完整270度圆弧与双翼箭头，iOS19pt旧弧线/单翼。
- 曝光尺：Android±EV 10sp，iOS EV 9pt；LUT为10sp，iOS8pt；PC为11sp，iOS10pt。
- 音频与反挤压关闭：iOS手绘近似Material矢量；需要按实际依赖校验/替换。level、zebra原路径大体一致但iOS18pt与Android19dp不同，仍需逐点核对。

## I01 完整清单

| 工具 | Android 基准 | iOS 本轮处理 |
|---|---|---|
| HD / FPS | 13sp / 10.5sp bold，单行 | 统一共享标记，保持字号 |
| Audio | filled VolumeUp 19dp | 实际 1.5.4 字节码路径替代近似图形 |
| Histogram | 5条 1.5dp 圆头，RGB按2/2/1分布 | 补RGB与亮度状态 |
| Grid | 19dp，2dp内边距；OFF显示三分线 | 复用既有精确网格标记 |
| Exposure | 斑马19dp / 三色柱（25/108/250亮度映射） | 依照当前档位切换 |
| Desqueeze | 关闭为outlined AspectRatio 19dp，开启12sp倍率 | 实际依赖路径与既有倍率格式 |
| Level | 19dp，1.65dp轮廓+U形槽+左右分隔 | 保留原几何，修正尺寸 |
| Record | 管理态filled Videocam19dp；正常态14dp圆/停/勾/暂停/继续 | 核对RecControlBar真实自绘路径，保留已对应生产录制条 |
| WB | 11sp | 共享静态标记，加载保持18dp进度 |
| Focus area | filled CenterFocusStrong19dp | 实际依赖路径 |
| Waveform | 7点折线，1.7dp圆头；RGB三分裁剪 | 替换W文字 |
| Focus mode | 管理MODE9sp；普通当前值8sp，AF Macro→AF-M，手动MF | 保留动态值8，修正静态9 |
| Focus frame | 20×18圆角3框1.4+AF8sp | 替换四角近似框 |
| LUT | 10sp bold | 修正8sp |
| Picture control | 22dp双层资源，24:16固有比例，四种颜色独立 | 离线转换原始XML，主题保色 |
| Meter | ±EV10sp | 补±并修正字号 |
| Lock | filled Lock/LockOpen19dp | 锁状态共享实际路径 |
| PC | 11sp bold | 修正10sp |
| Rotate | 原资源20dp，270°圆弧/完整箭头，1.8viewport stroke | 替换旧19dp单翼弧 |
| 管理/完成、显示/隐藏 | Settings/Check19dp、outlined眼标 | 按实际依赖重新生成；可见性角标和拖动规则不改 |
| 横屏Dock、DISP、诊断入口 | Dock19dp四格1.6/间隔3/圆角1.5；DISP8sp；诊断文本 | 核对既有实现，保持；全部工具仍复用同一标记 |

Android官方Maven 1.5.4 extended发布的是fake-sources空jar（已核对module元数据）；生成器改为解析实际classes.jar中公开PathBuilder指令与Float32参数，源类SHA256写入Swift，core使用官方真实源码jar。不以1.7.6近似替代。预设资源转换脚本保留viewport和翻转矩阵，运行时不解析文件。

## 本轮验证

- 实现已接入共享图标、主题四色保留、预设锚定弹窗、两列分类和内部确认页；以下为本轮实际运行的专项证据。
- 新专项包含20项图标实际像素、3类颜色状态、5种材质×明暗保色、切页各时点/停钟、加载取消/关闭/后台写入门控、真实弹窗宿主槽位→编辑→返回；复用目录、槽位读写和工具布局回归。
- `/tmp/ztransfer-preset-icon-first-tests.log` 35/35、`preset-icon-final-tests` 52/52、`preset-interruption-tests` 22/22，均TEST SUCCEEDED/exit0、0失败/跳过，共70个不同专项有通过证据；重复项不累加。
- 最终入口/背景复核 `/tmp/ztransfer-preset-entry-final-tests.log` 26项中25项通过，真实宿主像素测试2条断言失败：背景已经改为显式Rectangle，截图确认底边平直，但检测误把下方“测试日志”的蓝字抗锯齿浅色像素当作背景。检测增加连续填色宽度筛选，保留原边缘2px误差要求；仅重跑失败项 `/tmp/ztransfer-preset-row-final-tests.log` 1/1、0失败/跳过、TEST SUCCEEDED。保留失败日志，不修改生产图形来迁就断言。最终xcresult：`/tmp/ztransfer-usb-ptp-only-tests/Logs/Test/Test-ZTransfer-2026.10.18_21-11-04-+0800.xcresult`。五轮共70个不同专项，均有最终通过证据。
- 第一/最终组件附件已导出至 `/tmp/ztransfer-preset-icons-{first,final}-attachments`，已查看20项工具及真实槽位/两列编辑页截图；各材质四色有独立像素断言。未真机安装、未UI手势自动化、未提交本轮新修改。
- 最终直边选中行截图 `/tmp/ztransfer-preset-row-all-attachments/BAA23D6B-D782-4212-9173-DE888CEBE188.png` 已查看；外壳顶角保持12pt圆角，行底边平直。两套矢量生成器重新运行与当前Swift逐字节相同，`git diff --check`通过。
- 70项包含生产RemoteView普通/HD与RGB波形/直方图下实际画面像素更新、父控件隔离和释放回归；不把组件结果当作新真机FPS。已有“这次流畅了”验收与前序提交保持，本轮未重新安装或要求重复验证同一问题。

### 验证边界与交付

- 已运行模型/协议/组件测试和离屏真实宿主截图；没有运行端到端UI手势自动化。
- 本轮没有在真机打开系统Files选择器、实际写入NP3或逐项对照所有机型外观。目录授权/返回/取消、写入/验证/回滚等自动化证据不等同于这些人工场景已通过。
- 系统目录选择器和分享继续使用既有iOS原生平台路径。新修改留在工作区，未安装、未追加提交、未推送；用户要求的前序提交为`df455558`。

### 交互收口

- 预设再次点入口请求收起；初始化只显示18dp/1.5dp的原Material加载环，读失败原文提示后关闭。浏览不额外要求initialLoaded；没有会话时给Android原“槽位读取失败”提示。相机写入仍有connected/current/mode/busy等既有门控。
- 正常工具栏、编辑态、横屏Dock统一RemoteToolMark；FocusMode正常8sp动态值与管理9sp MODE分别保持。TopIconToggle文字/轮廓按原材质色与180ms Oklab过渡，停稳立即停钟；预设四色绕开统一材质染色。删除旧近似路径，没有新增持续装饰动画。
- 九槽根页自然宽度≤320、编辑260、2列36%/64%间距6，独立滚动；清除/目录提示均为原窗内页，文字复用安卓资源。180/40淡入、140淡出与400/.85 IntSize尺寸弹簧；全部通道结束后恢复点击。相机快速完成可保留多个退场页面，防止前一确认页突然消失。
- 目录状态改监看页持有，弹窗关闭不销毁目录缓存/授权。选择器目标、结果和返回标记保存在弹窗外；后台等待恢复、取消也回原C槽、横竖屏关闭弹窗后可重开原编辑页，隐藏预设工具时不强制重开。真实系统Files交互未自动操作，返回模型/目录IO与书签专项通过。
- 关闭已接受写入只取消UI等待，底层验证/回滚排空和忙碌释放不变；测试已覆盖关闭后迟到读取不得误关替代弹窗、后台不可发起新写入、失败只报原错误。
- 本轮不扩大为全部LUT监看菜单或所有按钮材质表面的重新设计，不改P34其他全应用真机/长时热状态未验收范围。
