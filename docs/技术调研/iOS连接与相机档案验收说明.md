# iOS 连接与相机档案：W07—W10 验收说明

基线：`6ab3302`；本轮工作区修改，提交/推送状态以 Git 为准。主进度仍以 [剩余任务表](./iOS剩余任务进度表.md) 为唯一入口。

## 代码边界

- 首页只使用既有 CameraWorkspaceBridge → CameraHandshakeProbe 这一位会话所有者；文件/队列仍用既有 shared 页面，导航不创建第二条相机连接。
- 原 Android ConnectionMethodCard、WifiModeTabs、反馈/图标/成功效果绘制提取到 SharedConnectionMethodCard.kt。Android 的原调用点、窗口坐标、SystemClock、资源字符串、会员/GPS/USB逻辑不变。home_card_extraction.py 对照 6ab3302，验证完整 Android 文件及提取后的完整公共组件，而非只看行数。
- iOS 首页接入同一卡片，增加 AP/STA 模式记忆、简中/繁中/英文静态文案和“配对完成但尚未连接”的反馈。连接成功时间线属于 W11；完整队列转场/飞入动画属于 W24；平台错误文案等跨页三语收口属于 W39。
- iOS只提供当前 AP / 标准 STA，不创建 USB 入口。Android原USB能力不动。W12—W15的STA-direct仍未完成。

## 路由、发现与权限

- 实际 NWConnection 限定 Wi-Fi；明确选择了带接口的 Bonjour 服务时，还限定该具体接口。不会自动改走蜂窝网络。
- 连接 ready 前核对实际 NWPath；已连接后路径不可用会安全关闭，不伪造仍可传输。重连编排仍归 W32。
- 只有系统路径明确给出 localNetworkDenied 才显示拒权。提示框尚未选择、未广播、普通等待或超时都不能被解释为拒权。
- 不用“是否能上互联网”拦截相机热点，不另建权限探测 socket，不触发后台网段扫描。系统设置入口使用公开的 UIApplication.openSettingsURLString；它不是 Wi-Fi 深层跳转，页面明确提示用户手动切换 Wi-Fi。
- 两类 Bonjour 服务按广播实例、域、接口分组；这不是已认证的相机身份去重。同名异域/异接口保留，真实身份仍由 PTP 应答及用户选择的 responder GUID 核对。
- 备用服务必须由用户明确点选。旧服务失效、超时或配对失败都不会自动切换到另一服务/另一机身。
- 历史 IP 仅是连接提示。Bonjour 地址来自真实 ready 连接的数字 remoteEndpoint；读取后再次检查取消/会话状态，核对 responder 后才保存。未解析服务名、候选广播、失败连接和 AP 地址都不能冒充 STA 成功历史。

Apple API 依据：[currentPath](https://developer.apple.com/documentation/network/nwconnection/currentpath)、[remoteEndpoint](https://developer.apple.com/documentation/network/nwpath/remoteendpoint)、[requiredInterface](https://developer.apple.com/documentation/network/nwparameters/requiredinterface)、[localNetworkDenied](https://developer.apple.com/documentation/network/nwpath/unsatisfiedreason-swift.enum/localnetworkdenied)。接口已核对；Windows不能验证系统回调时序，仍需Mac与iPhone验收。

## 存储职责与版本

| 内容 | 现有位置/所有者 | 写入条件与边界 |
|---|---|---|
| AP/STA页面模式 | UserDefaults：ztransfer.connection.preferences；CameraConnectionPreferences | v1，仅version/mode。默认AP；不存ready、连接对象、配对许可或身份。未知/损坏数据不覆盖，当前页可选择模式但提示无法保存。 |
| 安装PC身份与配对标记 | Application Support/ZTransfer/station-identity.json；StationProfileStore | 保留既有v1格式。initiator为本安装的稳定PTP协议身份；pairedResponders只由已有相机确认路径写入。文件重读核对当前initiator，旧实例不能改新身份。 |
| 相机地址历史 | Application Support/ZTransfer/camera-endpoint-history.json；CameraEndpointHistory | v1，responder GUID、显示名、验证后的地址、成功时间。没有安装身份/密码；历史地址不能授予配对信任。 |
| Keychain | 本轮未引入 | 本流程没有新增登录密码或支付凭据。不能为了W10迁移既有协议身份，造成原配对失效或更改卸载/恢复生命周期；将来新增秘密凭据时另行设计。 |
| 原片、目录授权、队列 | 既有store/provider/bookmark/queue所有者 | 与相机档案独立；忘记或重置档案不删除照片，也不清除目录授权。 |

这里的“多身份”是多个相机 responder 的独立选择/标记，不是新增多套安装PC身份。NativeStationChoice.paired沿用已有“档案行/服务行”类型标志；真正配对状态来自StationProfileStore，不由候选行布尔值授权。

现有格式都是v1，本轮原位读取兼容，不需要改写已有效数据。未来版本或损坏内容拒绝猜测迁移；显式恢复先保留完整原字节，不能默认重置。身份文件新增普通文件/非符号链接检查，避免从链接读取或覆盖身份。

## 恢复路径

| 情况 | 用户操作与结果 |
|---|---|
| 已配对但没有成功地址 | 保留配对档案，提示明确选择Bonjour服务或输入地址；继续核对所选GUID，不自动猜IP。 |
| 地址历史损坏 | 显示错误，同时保留独立身份文件中可读的配对列表；用户确认后备份并重置历史，身份/照片不动。 |
| 忘记一台相机 | 确认后先删该机配对标记，再删地址。其它机身与安装initiator保留。 |
| 忘记只完成一半 | 地址写失败会报错并重新加载实际档案，已删除的信任标记不回滚、不继续显示为已配对。修复历史后可再次处理地址记录。 |
| 重新配对 | 用户再次明确允许电脑模式配对并在相机确认；只有确认应答写入标记。配对完成不等于会话ready，需完成相机提示后再次连接。 |
| 身份文件损坏 | 用户确认恢复后只移动这个普通文件到UUID备份；下次明确连接创建新安装身份，所有机身需重新配对。有效身份文件不会被重置。 |
| 旧对象遇到已更换的身份文件 | 拒绝写入，不允许旧会话标记新安装身份；地址历史不参与身份授权。 |

## 回归证据与Mac补验

- W07：新增6项common、2项XCTest；原卡片全文对照、Kotlin/Android测试通过。
- W08：新增1项common、1项XCTest；默认AP地址恢复、活动/STA互斥及明确拒权/路由不可用分离。
- W09：新增3项XCTest；数字远端来源、Bonjour成功历史、连接前/关闭后不可取得可用远端。
- W10：新增5项XCTest；包含启动时已损坏历史的恢复入口、运行中损坏历史仍保留配对、部分忘记不留假信任、单机重新配对与其它身份隔离、符号链接拒绝。发现专用history句柄可延后首次校验以展示恢复页面，实际读写仍严格校验；已有版本/备份/旧身份隔离测试保留。
- 新增Python契约同时验证当前接线与精确历史逆转换。最终1033项Kotlin/Android、325项Python通过，common metadata/Release Kotlin编译/两模块Debug Lint通过；shared Lint零问题，app零错误。410项Apple测试只是源码已注册，未运行；详情见主表本轮记录。

在Mac按 [首次操作指南](../测试与验证/iOS首次Mac操作指南.md) 执行串行验证。重点运行CameraWorkspaceTests、CameraDiscoveryProfileTests、CameraNetworkTests并完成：

1. 三种语言、切换AP/STA与重启；配对许可不随模式保存，浏览/队列入口只在真实ready开放。
2. iPhone加入无互联网相机热点；本地网络允许/拒绝/设置返回后重试；不要把普通超时视为拒权。
3. 同Wi-Fi STA发现、服务消失/超时/停止、手动选备用服务、历史IP变化及相机身份不匹配。
4. 两台相机分别配对；忘记其中一台不影响另一台；完成配对后重新连接才进入可传图状态。
5. 临时测试容器内注入损坏历史/身份及写失败，确认备份、拒绝覆盖和恢复提示；不要破坏真实用户档案做测试。

Windows不能代替实际Network回调、Apple Swift类型检查、iOS原生导出签名、系统授权和画面/触感验证；发现问题要重开所属W项。
