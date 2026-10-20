# GPS 按钮材质与 STA 状态文字

依据：本地 Android `25860ae6`。已阅读 `SettingsScreen.kt` 的 `GpsStatusButton`、`HomeScreen.kt` 的 `StaConnectButtonState` 和完整连接按钮、`ButtonStateTextMotion.kt`，以及 `GpsConnectionPresentationTest` 和 `ConnectionCardMaterialTest` 的相关规则。用户要求修复 GPS 开启按钮的灰色外观，并为 STA 连接状态增加快速上下滚动。

| 任务 | 内容 | 状态 |
| --- | --- | --- |
| B01 | 核对安卓材质、状态顺序与动画参数 | 已完成 |
| B02 | 修复 GPS 材质、实现 STA 文字滚动与中断清理 | 已完成 |
| B03 | 实际图层与原有 GPS 手势回归，记录验证边界 | 已完成（开发侧） |

- GPS：原 `panel: true` 将按钮当作内嵌面板，液态玻璃分支因此退化成主文字色 5% 的灰底；改为常规主题按钮。保留安卓要求的语义文字色，不叠加连接色，不修改开启、重试、权限跳转或 800ms 长按关闭及触感。
- STA：维持 idle/searching/pairing/connecting/connected 顺序及原文案；失败、取消和重新连接归到原 idle 操作。前进旧文案向上退出、新文案从下方进入，回退相反。位移分别为 220/190ms，淡入 35ms 延迟后 150ms、淡出 120ms，曲线为 FastOutSlowIn（0.4,0,0.2,1）；位移为文字行高 20pt，按钮固定 42pt。
- 已连接时保留原来的禁止重复点击规则，但按安卓 `disabledAlpha = 1` 保持材质和文字完整亮度，避免收尾滚动时按钮突然变灰。
- 使用非交互原生文字图层，按钮材质和命中区域不参与滚动。快速切换从当前呈现位置/透明度续接，可复用仍在退出的同一状态文字；失效的完成回调不能删除新状态。相同状态/错误详情变化不重播；隐藏 STA、后台及卸载时收束并清除退出文字。没有新增持续帧钟、轮询、延迟连接或动画完成后才能点击的门控。
- 没有修改静态灯泡、GPS 状态业务、相机协议或监看端侧录制豁免；本轮不安装真机、不提交或推送。用户此前“稍后再测”的联合相机验收保持待办。

## 验证记录

- `/tmp/ztransfer-1020-connection-button-labels.log` / `.xcresult`：29/29通过，TEST SUCCEEDED/exit0（5个文字图层专项、23个连接状态回归、1个GPS真实模拟器触摸用例）。覆盖实际前进/回退图层呈现、途中逆转无位置跳变/无迟到误删、快速状态切换、同状态120次更新不重播、后台/卸载清理和弱引用释放。GPS短按不关闭、800ms长按完成、松手不重新开启、下一次点击开启均通过。
- `/tmp/ztransfer-1020-connection-button-hosts.log` / `.xcresult`：7/7通过，TEST SUCCEEDED/exit0（6个组件专项+上述GPS真实触摸重复验证）。新增真实ConnectionMethodCard宿主验证：同一个原生文字视图收到搜索/失败状态，确实播放图层动画，按钮文字视口始终20pt且位置/宽度不变，不接管触摸。工程文件仅保留两个新文件的8处引用，撤去生成器的无关重排。
- 截图已导出并实际检查：`/tmp/ztransfer-1020-button-attachments/EFF2F06A-BB90-47CE-80C5-29FB811035DA.png` 为实际GPS关闭后的“开启GPS”按钮；`72AB37F6-606C-454E-BCFA-056A5E929672.png` 为实际STA卡片，未出现空白按钮或材质/文字错位。前者是带测试控制区的真实GPS组件，后者为真实连接卡片的隔离宿主，不冒充真机连接截图。
- 收尾“已连接不压暗”已补入真实卡片用例：`/tmp/ztransfer-1020-sta-connected.log` / `.xcresult`，1/1通过，TEST SUCCEEDED/exit0；已连接后文字/固定几何和退出文字清理通过。以上不同专项为30项，重复执行和测试命名清理不累加。未运行安卓测试或全套iOS测试；未安装真机、未提交/推送。模拟器结果不能代替真机手感验收。

本轮3/3开发侧完成，全部构建/测试进程结束，diff检查通过。真机手感留给用户后续验收，不核销全应用性能台账P34/C02。
