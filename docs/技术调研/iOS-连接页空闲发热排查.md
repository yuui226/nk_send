# iOS 连接页空闲发热排查（2026-10-18）

状态：用户授权的静态红点方案已完成开发侧专项、两轮真机CPU测量及最终安装。连接页空闲CPU高占用已显著消除；实际降温和整机功耗未验收。历史失败记录保留，不代表当前实现。

## 复现及测量边界

用户报告新 iPhone 15 Plus 未进入照片列表就明显发烫。相机拔下后连接页可复现持续负载。系统 thermalState 为 2（serious）。临时 DEBUG 探针通过 getrusage 计算应用 CPU 时间 / 墙钟时间，百分比以一个核心为 100%，不是整机功耗或 GPU 使用率。每轮 2 秒采样、20 秒，排除头两组启动样本。对照不修改用户持久偏好或相机逻辑，诊断入口在最终交付前移除。

初轮实际已自动进入照片列表，静止 CPU 约 0.1–0.5%，不能用作连接页基线。随后用户拔下相机，截图确认连接页、STA、GPS 关闭。

| 同机对照 | 平均 CPU 单核百分比 | 日志（/tmp/ztransfer-heat- 前缀） |
|---|---:|---|
| 原连接页 | 38.045% | home-baseline.log |
| 暂停提示灯 | 38.038% | home-no-tips.log |
| 暂停卡片呼吸 | 36.101% | home-no-breathing.log |
| 同时暂停两者 | 9.320% | home-no-both.log |
| 仅用 EmptyView 替换收起的面板内容 | 38.077% | empty-closed.log |
| 两者暂停，再暂停 GPS 填充呼吸、移除收起面板 | 0.062% | all-static.log |
| 改 GeometryEffect / 隐式重复动画，仍保留相同参数 | 38.669% | render-effects.log |

刷新计数表明稳定期每两秒提示灯 Timeline 闭包约 480 次（多实例合计）；连接场景/卡片成功动画、弹窗宿主没有持续重建。因此不能把原因写成“整页每帧重建”或“隐藏弹窗每帧布局”。GeometryEffect 试验未改善，已撤回；首轮 Swift 6 Animatable 隔离编译失败也已保留日志，不算验证通过。

## 行为依据

- Android HomeScreen.kt connectionAttention：2.4 秒 smootherstep 呼吸，Wi-Fi 相位偏移 0.5，幅度 0.04；attentionIntensity 320ms FastOutSlowIn。
- Android TipLightbulbButton.kt：900ms FastOutSlowIn 往返，按钮 1–1.09、红点 0.72–1.12、透明度 0.58–1，graphicsLayer 阶段应用。
- Android SettingsScreen.kt rememberGpsEntryAmbientAlpha：关闭/开启分别 2800/2400ms 往返；关闭 0.05–0.145，开启 0.075–0.160。不是可以直接删除的忙碌轮询。
- Apple 建议多个液态玻璃控件使用 [GlassEffectContainer](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) 合并渲染。初步合并及关闭交互玻璃的对照 CPU 仍约 36%，不能单凭文档认定根因已修复。

## 工具与下一步

无线 devicectl 可安装、启动和读取探针，但 xctrace 当时设备 offline，未得到调用栈。用户随后已将 iPhone 用数据线连接电脑；xctrace 设备在线，但按名称/PID attach 未找到进程。随后 Time Profiler 全进程采样成功：15 秒内本应用采样累计 5567ms，其中主线程 5557ms，主要落在 SwiftUI/AttributeGraph 更新。系统符号不完整，不推断具体私有函数。SwiftUI 模板导出的 updates/causes 表为空，不作为因果证据。


## 持续动画优化与灯泡回归（仍在验证）

用户明确否决播放三轮后停止及严重热状态暂停的提案，要求保留持续动画。当前方案保留安卓周期、幅度、曲线及状态，改用 Core Animation 重复图层动画，不引入有限轮次或发热暂停。

原生卡片与灯泡试验稳定 CPU 约 5.2%；GPS 填充也移到原生透明度动画后，大多数样本约 0.025–0.18%，但有 2.9%/12.98% 波峰，未证实来源，不删除这些样本。用户随后报告灯泡间歇变色、发虚；真机截图 bulb-regression 可见灰色底板。该版本有显示回归，不能交付为最终方案。

恢复原灯泡 Timeline 渲染后截图 bulb-restored 显示颜色/清晰度恢复，但 CPU 又约 36%。因此继续验证独立透明 UIKit 容器承载动画，避免直接修改 UIHostingController 自己管理的根图层。此因果尚待真机结果，不能先记修复完成。

第一轮 native-tests 出现 Date 的 1970/referenceDate 转换精度导致的周期断言失败；改用 referenceDate 构造精确测试时钟，冻结样本按实际 Date 差值比较。后续 native-tests-fixed 已输出 38/38 无失败，但最终测试进程收尾仍待确认。测试不等同用户真机视觉验收，也未测 GPU/整机功耗或证明手机降温。


## 用户要求回退灯泡（2026-10-18）

用户明确要求“灯泡相关的不能直接改回去吗，现在一直有问题”。TipLightbulbButton.swift 已完整恢复为 HEAD b3f6f510 原文件，保留原 Timeline、按钮/红点持续动画及读状态、弹窗暂停/恢复，不再继续试改灯泡。新原生容器中 bulb/dot 两个实验分支及其专用测试已删除。保留卡片呼吸与 GPS 填充的原生图层优化，所有业务连接逻辑未改。

透明容器试验及只传公开环境值的试验均未消除灰块，不能作为成功修复。后者显式倍率改善边缘，但灰块仍存在；该公开环境白名单改动已撤回。保留透明容器承载卡片动画，避免直接修改 SwiftUI 根层。

已完成 container-tests 38/38、TEST SUCCEEDED，但这是包含被撤回灯泡分支的中间版本；最终删除实验分支后的验证另外记录。临时 CPU 探针已删除。回退对照 bulb-restore 中样本3–10仍约36%单核 CPU，因此本轮不能宣称发热已解决，也不能引用撤回版本约0.04%的数字代表当前版本。用户优先恢复灯泡；暂无温度恢复证据。


回退交付：bulb-rollback-build 为 BUILD SUCCEEDED，已安装到当前 iPhone 15 Plus，目录 FDF89FC7-07F8-4FED-B7D4-2A8143987E2D，普通无参数启动成功。bulb-rollback-final.png 真机截图确认灯泡恢复白色玻璃底板及清晰橙色图标/红点；不代表全动画周期的用户验收。TipLightbulbButton.swift 与 App/ZTransferApp.swift 对 HEAD 的 git diff 均为空。该安装包不再调用灯泡原生实验分支；其后源码删除未使用分支及测试，属于死代码清理，最终专项仍在运行。未提交或推送。

最终源码专项 /tmp/ztransfer-heat-rollback-tests.log：37/37、0失败、TEST SUCCEEDED、exit0；覆盖保留的卡片/GPS生命周期、连接状态与工作区分页。git diff --check通过。发热问题仍未收尾，灯泡按用户要求恢复原实现并已安装。


## 再次优化与用户批准静态红点（2026-10-18）

用户要求继续优化 CPU、保留持续动画且不能再破坏灯泡。主代理自行开展两轮保留 SwiftUI 原材质的对照：隔离 Timeline 到纯变换 modifier 仍约37%；用半周期低频状态更新和 SwiftUI 内建缩放/透明度插值、临时启动参数强制未读（不写保存配置）仍约40%。两次真机截图保持正常白色玻璃及橙色图标。半周期分割曲线与按钮/连接呈现专项 segment-tests 21/21 通过，但性能不达目标，方案已撤回；visualEffect 变体仅构建/安装，没有完成启动采样，不能声称有效。

用户随后明确提出“给灯泡的呼吸效果停了试试，只有红点其实也可以”。这是新的平台差异授权：静态灯泡、静态7pt红点，点击后仍由原独立持久化已读状态移除；按钮材质、图标、尺寸、点击和辅助功能保持；卡片和 GPS 的持续动画保留。删除不再需要的灯泡相位/暂停参数，并撤回所有半周期实验和专用测试。当前 static-tip 构建/真机对照中，结果待补，不提前算发热解决。


静态红点实测：/tmp/ztransfer-heat-static-tip.log 共15个2秒样本，排除前两组启动样本后，应用CPU均值0.0309076%单核，范围0.0165122–0.0620583%；同机 bulb-restore 基线36.654%。以NSArgumentDomain临时覆盖四个提示未读标志进行最不利未读场景测量，没有修改保存偏好；后续无覆盖复测另记。static-tip-first/second 两张真机截图已查看，灯泡白色玻璃底板、橙色图标、完整红点均正常，卡片呼吸姿态和GPS颜色处于不同阶段。系统thermalState仍2，不声称已经降温或量得GPU功耗。临时CPU探针已从最终源码移除，等待最终构建/安装。

普通设置复测：static-tip-normal.log 同样15个2秒样本；去除前两组后均值0.042578%单核，范围0.015156–0.199506%。没有启动参数覆盖提示状态，仍处于原连接页，说明降幅并非来自把未读状态清除。最终static-tip-tests 40/40、0失败、TEST SUCCEEDED、exit0；含保留动画模型/原生容器、按钮控制器、连接呈现与连接状态。ConnectionState里两项旧灯泡曲线测试仅检验仍被卡片/GPS使用的数学参考，不代表灯泡仍有呼吸动画，也不是全页面UI自动化。App源文件已与HEAD一致，确认CPU探针移除；最后交付构建进行中。


最终交付：static-tip-delivery-build 为 BUILD SUCCEEDED、exit0，已安装当前 iPhone 15 Plus（999CFD32-9660-4BD0-A83A-ED0491868AB4），随后无参数普通启动成功。最终源码中无临时探针、半周期试验和原生灯泡实验分支，git diff --check通过。共享灯泡仅保留静态未读点与原按钮交互；卡片/GPS持续动画没有有限轮次或热状态暂停。已更新长期记忆，无子代理、无提交/推送；全功能历史台账分母不变。用户主观持续使用/温度确认仍待自然使用反馈，不把本轮CPU结果扩展为传输过程或所有设备的功耗验收。


## 全部灯泡入口复核（2026-10-18）

用户明确扩展为“所有的灯泡按钮的呼吸全去掉”。按全量源码搜索与调用点上下文阅读核验7/7：ConnectionMethodCard 的 STA/AP、GPSConnectionControl、SettingsView 的主设置/照片效果设置、LocalPhotoEffectsView、PhotoFilterPopupOverlay 的评级帮助，全都复用静态 TipLightbulbButton。没有另外实现的灯泡图标或调用方无限呼吸；评级帮助原本 attention=false，继续不显示未读点。GPS 启用状态的有限显隐/缩小过渡保留，未把它误判为常驻呼吸。

公共组件不再有 TimelineView、循环任务、相位状态或持续缩放/透明度动画；红点仍由每个入口原有独立持久化状态决定，点击回调/辅助标签/材质原样保留。TipAttentionValues 只作为卡片/GPS的数学插值参考被调用，不会启动任何灯泡动画或刷新任务。

之前交付的999CFD32版本已经包含上述公共组件改动，因此此次无需新的功能修改或重复安装。仅更新全局禁用注释和长期约定，git diff --check通过；没有新增测试、构建或真机全页面功耗测量，不将连接页0.04%推广为所有页面功耗数据。
