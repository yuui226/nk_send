# TestFlight 当前版本上传（2026-11-10）

用户要求提交当前版本至 TestFlight。营销版本2.05，构建号80递增为81，project.yml与pbxproj同步。当前工作树包含本轮生成完整原图生命周期修复及冷启动后台清理，已有16项定向测试通过。

| 任务 | 状态 |
| --- | --- |
| T01 Release归档、签名及包检查 | 完成，ARCHIVE SUCCEEDED / exit0，codesign严格验证通过，包检查errors为空 |
| T02 Apple校验与上传 | 完成，Validated ZTransfer、Upload succeeded、EXPORT SUCCEEDED / exit0 |
| T03 Apple处理、内部组分配与测试说明回读 | 完成，81已加入本人内部测试，群组列表显示正在测试，中文英文测试说明已保存并回读 |

归档证据在 ios/.build/appstore-20261110/build81，包括版本变更前快照、编译输入摘要、归档日志和测试重点。复用已有Release缓存，不重复运行整套测试。真实Photos写入和物理设备杀进程测试仍待验证。

11月10日后台只读确认已有80、79、78，均关联“本人内部测试”。正式App版本仍选80，且已存在用户上传的MP4审核附件。本轮任务是TestFlight内部测试分发。

归档输入1168项前后SHA256一致，实际产物com.ztransfer.ios，2.05(81)，iOS16起，iPhone/iPad，非豁免加密false，UIRequiresFullScreen为true。

完成3/3。构建ID 83edf90d-1712-4d48-a957-5d079c03fd72，上传11:07成功，线上处理完成。既有内部组1名测试员、4个构建，81状态正在测试；既有80/79/78保留。中文说明保存后从新标签页回读，英文说明保存后在群组添加完成界面回读。正式版本页面本轮核对仍选80，用户已上传MP4附件。未操作正式提交、发布或手机安装。
