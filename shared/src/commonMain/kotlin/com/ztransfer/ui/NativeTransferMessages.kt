package com.ztransfer.ui

/** Platform messages carry stable codes; rendering stays live with the shared language setting. */
object NativeTransferMessages {
    private val entries = mapOf(
        "pairing" to listOf("正在配对，请在相机端确认。", "Pairing; confirm on the camera.", "正在配對，請在相機端確認。"),
        "no_services" to listOf("未发现 Bonjour 服务；请检查 Wi-Fi 或输入地址。这不代表权限被拒绝。", "No Bonjour service found. Check Wi-Fi or enter an address; this does not prove permission denial.", "未找到 Bonjour 服務；請檢查 Wi-Fi 或輸入位址。這不代表權限遭拒。"),
        "no_verified_route" to listOf("相机暂无已验证地址，请明确选择服务或输入地址；不会自动扫描网段。", "No verified camera address. Select a service or enter an address; no automatic subnet scan.", "相機暫無已驗證位址，請明確選擇服務或輸入位址；不會自動掃描網段。"),
        "paired_camera" to listOf("已配对相机 · {0}", "Paired camera · {0}", "已配對相機 · {0}"),
        "service" to listOf("服务", "Service", "服務"),
        "cancelled" to listOf("已取消未完成部分，原片保留。", "Remaining work cancelled; originals retained.", "已取消未完成部分，原檔保留。"),
        "disk_full" to listOf("存储空间不足。请释放空间后重试；已有原片保留。", "Storage is full. Free space and retry; existing originals are retained.", "儲存空間不足。請釋放空間後重試；既有原檔保留。"),
        "permission" to listOf("目录访问被拒绝或已撤销，请重新选择保存目录。", "Directory access denied or revoked. Select the save location again.", "目錄存取遭拒或已撤銷，請重新選擇儲存目錄。"),
        "source_changed" to listOf("原片缺失、已变化或未完整发布；请核对目录后重试。", "Original missing, changed or unpublished. Check the source and retry.", "原檔遺失、已變更或未完整發布；請核對目錄後重試。"),
        "timeout" to listOf("相机响应超时，请检查 Wi-Fi 后重试；超时不代表权限被拒绝。", "Camera timed out. Check Wi-Fi and retry; a timeout does not prove permission denial.", "相機回應逾時，請檢查 Wi-Fi 後重試；逾時不代表權限遭拒。"),
        "network_denied" to listOf("本地网络权限被系统拒绝。请到系统设置允许后重试。", "Local Network access was denied. Allow it in Settings, then retry.", "本機網路權限遭系統拒絕。請到系統設定允許後重試。"),
        "wifi" to listOf("相机 Wi-Fi 路由不可用，请确认热点或同一局域网后重连。", "Camera Wi-Fi route unavailable. Check the hotspot or LAN and reconnect.", "相機 Wi-Fi 路由不可用，請確認熱點或同一區域網路後重新連接。"),
        "closed" to listOf("连接已关闭，请重新连接；旧句柄不会用于新会话。", "Connection closed. Reconnect; old handles are not used in a new session.", "連線已關閉，請重新連接；舊控制代碼不會用於新工作階段。"),
        "busy" to listOf("相机或当前操作正忙，请稍后重试。", "Camera or operation is busy. Retry shortly.", "相機或目前操作忙碌，請稍後重試。"),
        "protocol" to listOf("相机数据不完整或事务不匹配，请重新连接。", "Incomplete camera data or transaction mismatch. Reconnect.", "相機資料不完整或交易不符，請重新連接。"),
        "rejected" to listOf("相机拒绝了操作，操作码/响应码：{0}", "Camera rejected the operation. Operation/response: {0}", "相機拒絕操作，操作碼/回應碼：{0}"),
        "unsafe" to listOf("文件名或路径不安全，未覆盖或删除已有原片。", "Unsafe filename or path; existing originals were not overwritten or deleted.", "檔名或路徑不安全，未覆寫或刪除既有原檔。"),
        "verify" to listOf("副本校验失败，未发布不完整文件；原片保留。", "Copy verification failed; no incomplete file was published. Originals retained.", "副本驗證失敗，未發布不完整檔案；原檔保留。"),
        "photo_denied" to listOf("未获得图库添加权限；原片保留，可使用分享或 Files。", "Photos add permission denied; originals retained. Use Share or Files.", "未取得圖庫新增權限；原檔保留，可使用分享或 Files。"),
        "photo_unsupported" to listOf("图库不支持此文件，请改用分享或 Files 导出原片。", "Photos does not support this file. Export the original via Share or Files.", "圖庫不支援此檔案，請改用分享或 Files 匯出原檔。"),
        "photo_failed" to listOf("图库导入失败；原片保留，请检查权限后重试。", "Photos import failed; originals retained. Check permission and retry.", "圖庫匯入失敗；原檔保留，請檢查權限後重試。"),
        "failed" to listOf("操作未完成；原片保留。请核对连接或保存目录后重试。错误代码：{0}", "Operation failed; originals retained. Check the connection or destination and retry. Error code: {0}", "操作未完成；原檔保留。請核對連線或儲存目錄後重試。錯誤代碼：{0}"),
        "invalid_address" to listOf("相机地址无效。", "Invalid camera address.", "相機位址無效。"),
        "paired_prefix" to listOf("已配对 · {0}", "Paired · {0}", "已配對 · {0}"),
        "history_prefix" to listOf("历史地址 · {0}", "History · {0}", "歷史位址 · {0}"),
        "find_service" to listOf("请查找相机后选择服务。", "Find the camera, then select its service.", "請尋找相機後選擇服務。"),
        "bonjour" to listOf("Bonjour · 连接时验证相机", "Bonjour · camera verified when connecting", "Bonjour · 連接時驗證相機"),
        "stale_choice" to listOf("相机候选已失效，请重新查找。", "Camera candidate expired. Search again.", "相機候選已失效，請重新尋找。"),
        "history_reset" to listOf("地址历史已备份并重置，配对身份保持不变。", "Address history backed up and reset; pairing identity unchanged.", "位址歷史已備份並重置，配對身分保持不變。"),
        "no_address" to listOf("无已验证地址", "No verified address", "無已驗證位址"),
        "identity_reset" to listOf("配对身份已备份并恢复，请重新在相机完成电脑模式配对。", "Pairing identity backed up and recovered. Pair again in camera computer mode.", "配對身分已備份並恢復，請重新在相機完成電腦模式配對。"),
        "identity_valid" to listOf("现有配对身份有效，未进行重置。", "Existing pairing identity is valid; no reset performed.", "既有配對身分有效，未進行重置。"),
        "system_busy" to listOf("系统窗口暂不可用，请关闭其它系统窗口后重试。", "System presentation unavailable. Close other system windows and retry.", "系統視窗暫不可用，請關閉其他系統視窗後重試。"),
        "action_unavailable" to listOf("暂不能操作这些原片，请关闭其它系统窗口或检查保存目录。", "Cannot access these originals. Close other system windows or check the save location.", "暫時無法操作這些原檔，請關閉其他系統視窗或檢查儲存目錄。"),
        "photos_receipt" to listOf("图库接收结果已返回；不支持的 RAW/视频可改用分享或 Files，原片保留。", "Photos results returned; export unsupported RAW/video via Share or Files. Originals retained.", "圖庫接收結果已傳回；不支援的 RAW/影片可改用分享或 Files，原檔保留。"),
        "export_ended" to listOf("导出准备已结束或取消；原片保留，未确认的项目不计成功。", "Export preparation ended or cancelled; originals retained. Unconfirmed items are not successful.", "匯出準備已結束或取消；原檔保留，未確認的項目不計成功。"),
        "share_receipt" to listOf("系统分享回执不代表接收方持久保存或云端同步完成。", "System activity receipt does not verify recipient storage or cloud sync.", "系統分享回執不代表接收方永久儲存或雲端同步完成。"),
        "files_receipt" to listOf("Files 返回 {0} 个结果；部分回执请核对目标后手动重试，不代表云端同步完成。", "Files returned {0} results. Verify partial receipts before manually retrying; cloud sync is not verified.", "Files 傳回 {0} 個結果；部分回執請核對目標後手動重試，不代表雲端同步完成。"),
        "destination_unknown" to listOf("保存目标偏好无法读取；请明确重选目标。原数据保留，未自动切回沙盒。", "Save destination preference unreadable. Select it explicitly; old data retained, no automatic sandbox fallback.", "儲存目標偏好無法讀取；請明確重選目標。原資料保留，未自動切回沙盒。"),
        "destination_repair" to listOf("保存目标未恢复，请重选目录或明确切回应用目录。", "Save destination could not be restored. Select a directory or explicitly choose app storage.", "儲存目標未恢復，請重選目錄或明確切回應用程式目錄。"),
        "destination_busy" to listOf("队列仍在执行，请传完当前并暂停后再切换保存目标。", "Queue is running. Finish the current file and pause before changing destination.", "佇列仍在執行，請傳完目前檔案並暫停後再切換儲存目標。"),
        "destination_provider" to listOf("所选目录：{0}；校验发布后才完成，应用内原片保留。", "Selected directory: {0}; completes after verified publication. App originals retained.", "所選目錄：{0}；驗證發布後才完成，應用程式內原檔保留。"),
        "destination_sandbox" to listOf("应用目录；外部目录中的已有文件不变。", "App storage; existing files in external directories are unchanged.", "應用程式目錄；外部目錄中的既有檔案不變。"),
        "destination_unsaved" to listOf("本次目标已生效，但偏好未保存；下次连接请重新核对。", "Destination applied, but preference was not saved. Verify it on the next connection.", "本次目標已生效，但偏好未儲存；下次連接請重新核對。"),
        "history_unsaved" to listOf("相机已连接，但地址历史未保存；下次连接请重新查找。", "Camera connected, but address history was not saved. Search again next time.", "相機已連接，但位址歷史未儲存；下次連接請重新尋找。"),
        "ready" to listOf("相机已连接，可以浏览与传输原片。", "Camera connected; browse and transfer originals.", "相機已連接，可以瀏覽與傳輸原檔。"),
        "pair_again" to listOf("配对已完成，请重新连接以打开传图会话。", "Pairing completed. Reconnect to open a transfer session.", "配對已完成，請重新連接以開啟傳圖工作階段。")
    )
    fun render(message: String, language: String): String {
        if ("；@ztr|" in message) return message.split("；").joinToString("\n") { render(it, language) }
        val marker = message.indexOf("@ztr|")
        if (marker < 0) return message
        val encoded = message.substring(marker + 5)
        val code = encoded.substringBefore("|")
        val value = encoded.substringAfter("|", "")
        val translations = entries[code] ?: return message
        val tag = language.lowercase().replace('_', '-')
        val index = if (!tag.startsWith("zh")) 1 else if ("hant" in tag || tag.endsWith("-tw") || tag.endsWith("-hk") || tag.endsWith("-mo")) 2 else 0
        return translations[index].replace("{0}", value)
    }
    internal fun codes(): Set<String> = entries.keys
}
