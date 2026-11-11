import Foundation

/// iOS-only copy that must not be written into AndroidLocalization.swift,
/// which is regenerated from Android resources. Platform-specific permission
/// guidance and setup steps live here so regeneration cannot remove them.
enum IOSLocalization {
    static let byResource: [String: [String: String]] = [
        // User-approved native accessory picker for Nikon's Classic pairing phase.
        "gps_ios_system_pairing": ["zh": "在系统“选择配件”窗口选择相机，核对配对码，并在手机和相机上确认。", "en": "Select your camera in the system accessory picker, check the pairing code, and confirm on both the iPhone and camera.", "hant": "在系統「選擇配件」視窗選擇相機，核對配對碼，並在手機和相機上確認。"],
        "gps_ios_confirm_pairing": ["zh": "配对未完成。若点选相机后窗口自动关闭，请先在手机“设置 → 蓝牙”中忽略这台相机。然后在相机重新开始配对，并在手机和相机上确认配对码。", "en": "Pairing is incomplete. If the picker closes after you select the camera, first forget that camera in Settings → Bluetooth. Then restart pairing on the camera and confirm the pairing code on both devices.", "hant": "配對未完成。若點選相機後視窗自動關閉，請先在手機「設定 → 藍牙」中忘記這台相機。然後在相機重新開始配對，並在手機和相機上確認配對碼。"],
        "gps_ios_forget_pairing": ["zh": "请到手机“设置 → 蓝牙”，点相机旁的 ⓘ 并选择“忽略此设备”，再在相机上重新开始配对。", "en": "In Settings → Bluetooth, tap ⓘ next to the camera and choose Forget This Device, then restart pairing on the camera.", "hant": "請到手機「設定 → 藍牙」，點相機旁的 ⓘ 並選擇「忘記此裝置」，再在相機上重新開始配對。"],
        // Native recovery guidance; missing grants are requested in the app.
        "gps_ios_locationDenied": ["zh": "请前往“设置 → 隐私与安全性 → 定位服务 → Z传”允许定位，返回后自动继续。", "en": "Allow access in Settings → Privacy & Security → Location Services → ZTransfer, then return to continue.", "hant": "請前往「設定 → 隱私權與安全性 → 定位服務 → Z傳」允許定位，返回後自動繼續。"],
        "gps_ios_locationRestricted": ["zh": "定位权限受系统限制，请检查屏幕使用时间或设备管理限制。", "en": "Location access is restricted. Check Screen Time or device management restrictions.", "hant": "定位權限受系統限制，請檢查螢幕使用時間或裝置管理限制。"],
        "gps_ios_locationServicesDisabled": ["zh": "请打开手机“设置 → 隐私与安全性 → 定位服务”的总开关，再返回开启 GPS。", "en": "Turn on Location Services in Settings → Privacy & Security → Location Services, then return to enable GPS.", "hant": "請開啟手機「設定 → 隱私權與安全性 → 定位服務」的總開關，再返回啟用 GPS。"],
        "gps_ios_bluetoothDenied": ["zh": "请前往“设置 → 隐私与安全性 → 蓝牙”允许 Z传使用蓝牙，返回后自动继续。", "en": "Allow ZTransfer in Settings → Privacy & Security → Bluetooth, then return to continue.", "hant": "請前往「設定 → 隱私權與安全性 → 藍牙」允許 Z傳使用藍牙，返回後自動繼續。"],
        "gps_ios_bluetoothRestricted": ["zh": "蓝牙权限受系统限制，请检查屏幕使用时间或设备管理限制。", "en": "Bluetooth access is restricted. Check Screen Time or device management restrictions.", "hant": "藍牙權限受系統限制，請檢查螢幕使用時間或裝置管理限制。"],
        // User-requested NP3 directory wording (2026-11-06).
        "photo_filter_set_folder": ["zh": "设置NP3文件目录", "en": "Set NP3 folder", "hant": "設定NP3檔案目錄"],
        // User-approved iOS difference (2026-10-21): NP3 files are supplied by the user.
        "monitor_help_tool_picture_control": [
            "en": "Switch between existing camera presets, or tap the pencil for a slot to replace or clear it. Choose a folder containing your own .np3 files. Flexible Color .np3 files are not yet supported.",
            "zh": "支持相机已有预设切换，点槽位对应画笔更换或清除。请选择含自行收集的 .np3 文件的文件夹，暂不支持灵活色彩的 .np3。",
            "hant": "支援相機已有預設切換，點槽位對應畫筆更換或清除。請選擇含自行收集的 .np3 檔案的資料夾，暫不支援靈活色彩的 .np3。",
        ],
        "usb_camera_not_ready": [
            "zh": "相机尚未就绪，请确认相机已开机并检查连接",
            "en": "Camera is not ready. Make sure it is powered on and check the connection.",
            "hant": "相機尚未就緒，請確認相機已開機並檢查連線",
        ],
        "usb_storage_unavailable": [
            "zh": "相机存储卡不可用，请检查存储卡",
            "en": "Camera storage is unavailable. Please check the memory card.",
            "hant": "相機記憶卡無法使用，請檢查記憶卡",
        ],
        "local_photo_ios_save_hint": ["zh": "效果图会作为新照片保存到系统照片图库", "en": "Edited photos are saved as new items in your photo library.", "hant": "效果圖會作為新照片儲存到系統照片圖庫"],
        // iOS-only transfer destination (2026-11-09). Android keeps one folder
        // that its media store indexes automatically.
        "transfer_save_destination": ["zh": "保存位置", "en": "Save to", "hant": "儲存位置"],
        "transfer_save_photo_library": ["zh": "保存到相册", "en": "Photo library", "hant": "儲存到相簿"],
        "transfer_save_folder": ["zh": "保存到文件夹", "en": "Folder", "hant": "儲存到資料夾"],
        "transfer_save_destination_summary": ["zh": "保存到相册时，照片和视频进入系统照片里的「Z传」相簿，其他 App 也能看到，此时不能选择存放方式。保存到文件夹时才使用所选目录，并可统一存放、按天存放或按类存放。开始传入相册前，需要允许完全访问照片。", "en": "Photo library saves photos and videos into the Z传 album, where Photos and other apps can see them, and storage mode is unavailable. Folder uses the chosen directory, grouped together, by day, or by type. Full photo access is requested when a transfer to the album starts.", "hant": "儲存到相簿時，照片和影片會進入系統照片裡的「Z傳」相簿，其他 App 也能看到，此時不能選擇儲存方式。儲存到資料夾時才使用所選目錄，並可統一儲存、按天儲存或按類儲存。開始傳入相簿前，需要允許完全取用照片。"],
        "transfer_photo_access_blocked": ["zh": "需要允许完全访问照片，才能保存到「Z传」相簿。请到“设置 → 隐私与安全性 → 照片”中为 Z传 选择完全访问。", "en": "Full photo access is required to save into the Z传 album. In Settings → Privacy & Security → Photos, choose Full Access for ZTransfer.", "hant": "需要允許完全取用照片，才能儲存到「Z傳」相簿。請到「設定 → 隱私權與安全性 → 照片」中為 Z傳 選擇完全取用。"],
        "transfer_photo_import_failed": ["zh": "无法保存到照片图库", "en": "Could not save to the photo library.", "hant": "無法儲存到照片圖庫"],
        "local_photo_batch_generate": ["zh": "生成并保存（%1$d）", "en": "Generate and save (%1$d)", "hant": "產生並儲存（%1$d）"],
        "lut_choose_folder": ["en": "Choose folder", "zh": "选择文件夹", "hant": "選擇資料夾"],
        "cd_remote_fullscreen_exit": ["zh": "退出全屏", "en": "Exit fullscreen", "hant": "退出全螢幕"],
        "lut_change_folder": ["en": "Change folder", "zh": "更换文件夹", "hant": "更換資料夾"],
        "local_photo_replace": ["zh": "更换图片", "en": "Replace photo", "hant": "更換圖片"],
        "skin_liquid_glass": ["zh": "液态玻璃", "en": "Liquid Glass", "hant": "液態玻璃"],
        "iap_confirming": ["zh": "正在确认购买权益，请稍后重试", "en": "Confirming purchases. Please try again shortly.", "hant": "正在確認購買權益，請稍後重試"],
        "iap_pending": ["zh": "购买待批准，批准后将自动解锁", "en": "Purchase awaiting approval. Pro will unlock when approved.", "hant": "購買待批准，批准後將自動解鎖"],
        "iap_purchase_failed": ["zh": "购买未完成，请稍后重试", "en": "Purchase could not be completed. Please try again.", "hant": "購買未完成，請稍後重試"],
        "iap_confirmation_failed": ["zh": "暂时无法确认购买权益，请稍后重试", "en": "Unable to confirm purchases right now. Please try again.", "hant": "暫時無法確認購買權益，請稍後重試"],
        "iap_verification_failed": ["zh": "购买验证未通过，请恢复权益或稍后重试", "en": "Purchase verification failed. Restore access or try again.", "hant": "購買驗證未通過，請恢復權益或稍後重試"],
        "iap_restored": ["zh": "已恢复高级版", "en": "Pro restored", "hant": "已恢復高級版"],
        "iap_restore_empty": ["zh": "未找到有效的高级版购买记录", "en": "No active Pro purchase found", "hant": "未找到有效的高級版購買記錄"],
        "iap_restore_failed": ["zh": "恢复权益失败，请稍后重试", "en": "Could not restore access. Please try again.", "hant": "恢復權益失敗，請稍後重試"],
        "iap_manage_failed": ["zh": "暂时无法打开订阅管理，请稍后重试", "en": "Could not open subscription management. Please try again.", "hant": "暫時無法開啟訂閱管理，請稍後重試"],
        "iap_redeem_failed": ["zh": "暂时无法打开优惠码兑换，请稍后重试", "en": "Could not open offer code redemption. Please try again.", "hant": "暫時無法開啟優惠碼兌換，請稍後重試"],
        "iap_purchased": ["zh": "已解锁高级版", "en": "Pro unlocked", "hant": "已解鎖高級版"],
        "iap_restore": ["zh": "恢复权益", "en": "Restore access", "hant": "恢復權益"],
        "iap_annual_disclosure": ["zh": "按年自动续订，可随时取消", "en": "Renews yearly, cancel anytime", "hant": "按年自動續訂，可隨時取消"],
        "iap_redeem": ["zh": "兑换优惠码", "en": "Redeem offer code", "hant": "兌換優惠碼"],
        "iap_manage": ["zh": "管理订阅", "en": "Manage subscription", "hant": "管理訂閱"],
        "iap_prices_failed": ["zh": "暂时无法加载价格，请确认网络后重试", "en": "Unable to load prices. Check your connection and retry.", "hant": "暫時無法載入價格，請確認網路後重試"],
        "iap_retry": ["zh": "重试", "en": "Retry", "hant": "重試"],
        "iap_loading": ["zh": "加载中…", "en": "Loading…", "hant": "載入中…"],
        "iap_annual_period": ["zh": "1 年", "en": "1 year", "hant": "1 年"],
        // User-requested compact CTA (2026-11-06): the plan name already
        // identifies its duration. Keep Apple's price, without a second suffix.
        "iap_annual_cta": ["zh": "购买一年高级版 · %1$s", "en": "Buy Annual Pro · %1$s", "hant": "購買一年高級版 · %1$s"],
        "buy_lifetime_cta": ["zh": "购买永久高级版 · %1$s", "en": "Buy Lifetime Pro · %1$s", "hant": "購買永久高級版 · %1$s"],
        "iap_renewal_terms": ["zh": "年费每年扣费一次，自动续订，可随时在苹果订阅管理中取消续订。月均价仅供参考，不是按月扣费。", "en": "Annual Pro is billed once a year and renews automatically. Cancel renewal anytime in Apple subscription settings. The monthly equivalent is for reference; billing is annual.", "hant": "年費每年扣費一次，自動續訂，可隨時在蘋果訂閱管理中取消續訂。月均價僅供參考，不是按月扣費。"],
        "iap_account_hint": ["zh": "购买绑定所用的 Apple 账户，同一账户可恢复权益。", "en": "Purchases belong to the Apple Account used to buy them. The same account can restore access.", "hant": "購買綁定所用的 Apple 帳號，同一帳號可恢復權益。"],
        "iap_lifetime_notice": ["zh": "购买永久版不会自动取消年费，请在购买后前往苹果订阅管理取消续订，避免重复扣费。", "en": "Buying Lifetime Pro does not cancel Annual Pro. After purchasing, cancel annual renewal in Apple subscription settings to avoid further charges.", "hant": "購買永久版不會自動取消年費，請在購買後前往蘋果訂閱管理取消續訂，避免重複扣費。"],
        "iap_lifetime_followup": ["zh": "永久版已生效。请管理原年费订阅，确认关闭自动续订。", "en": "Lifetime Pro is active. Manage your previous annual subscription and confirm renewal is off.", "hant": "永久版已生效。請管理原年費訂閱，確認關閉自動續訂。"],
        "iap_renewal_on": ["zh": "自动续订已开启", "en": "Auto-renewal is on", "hant": "自動續訂已開啟"],
        "iap_renewal_off": ["zh": "自动续订已关闭", "en": "Auto-renewal is off", "hant": "自動續訂已關閉"],
        "iap_renewal_unknown": ["zh": "续订状态暂时无法确认", "en": "Renewal status is currently unavailable", "hant": "續訂狀態暫時無法確認"],
        "iap_grace": ["zh": "续费扣款暂未完成，宽限期内可继续使用高级版", "en": "Renewal payment is incomplete. Pro remains available during Apple’s grace period.", "hant": "續費扣款暫未完成，寬限期內可繼續使用高級版"],
        "iap_billing_retry": ["zh": "续费扣款未完成，请检查苹果付款方式", "en": "Renewal payment failed. Check your Apple payment method.", "hant": "續費扣款未完成，請檢查蘋果付款方式"],
        "iap_valid_until": ["zh": "有效期至 %1$s", "en": "Valid until %1$s", "hant": "有效期至 %1$s"],
        "iap_renews_on": ["zh": "年费下次续费日期 %1$s", "en": "Annual renewal on %1$s", "hant": "年費下次續費日期 %1$s"],
        "iap_continue": ["zh": "继续购买", "en": "Continue purchase", "hant": "繼續購買"],
        "iap_privacy": ["zh": "隐私政策", "en": "Privacy policy", "hant": "隱私政策"],
        "iap_terms": ["zh": "使用条款", "en": "Terms of use", "hant": "使用條款"],
        "settings_privacy": ["zh": "隐私", "en": "Privacy", "hant": "隱私"],
        "settings_terms": ["zh": "条款", "en": "Terms", "hant": "條款"],
        "iap_redeem_version": ["zh": "永久版优惠码需要 iOS 16.3 或更高版本", "en": "Lifetime offer codes require iOS 16.3 or later", "hant": "永久版優惠碼需要 iOS 16.3 或更新版本"],
        "usb_permission_required": [
            "zh": "未获得相机访问权限，请到系统设置允许访问",
            "en": "Camera access was not granted. Allow access in Settings.",
            "hant": "未取得相機存取權限，請到系統設定允許存取",
        ],
        "usb_step_mode": [
            "zh": "相机 USB 设置选择 MTP/PTP",
            "en": "Set the camera USB mode to MTP/PTP",
            "hant": "相機 USB 設定選擇 MTP/PTP",
        ],
    ]
}
