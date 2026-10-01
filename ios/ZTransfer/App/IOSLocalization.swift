import Foundation

/// iOS-only copy that must not be written into AndroidLocalization.swift,
/// which is regenerated from Android resources. Platform-specific permission
/// guidance and setup steps live here so regeneration cannot remove them.
enum IOSLocalization {
    static let byResource: [String: [String: String]] = [
        "iap_confirming": ["zh": "正在确认购买权益，请稍后重试", "en": "Confirming purchases. Please try again shortly.", "hant": "正在確認購買權益，請稍後重試"],
        "iap_pending": ["zh": "购买待批准，批准后将自动解锁", "en": "Purchase awaiting approval. Pro will unlock when approved.", "hant": "購買待批准，批准後將自動解鎖"],
        "iap_purchase_failed": ["zh": "购买未完成，请稍后重试", "en": "Purchase could not be completed. Please try again.", "hant": "購買未完成，請稍後重試"],
        "iap_confirmation_failed": ["zh": "暂时无法确认购买权益，请稍后重试", "en": "Unable to confirm purchases right now. Please try again.", "hant": "暫時無法確認購買權益，請稍後重試"],
        "iap_verification_failed": ["zh": "购买验证未通过，请恢复购买或稍后重试", "en": "Purchase verification failed. Restore purchases or try again.", "hant": "購買驗證未通過，請恢復購買或稍後重試"],
        "iap_restored": ["zh": "已恢复高级版", "en": "Pro restored", "hant": "已恢復高級版"],
        "iap_restore_empty": ["zh": "未找到有效的高级版购买记录", "en": "No active Pro purchase found", "hant": "未找到有效的高級版購買記錄"],
        "iap_restore_failed": ["zh": "恢复购买失败，请稍后重试", "en": "Could not restore purchases. Please try again.", "hant": "恢復購買失敗，請稍後重試"],
        "iap_manage_failed": ["zh": "暂时无法打开订阅管理，请稍后重试", "en": "Could not open subscription management. Please try again.", "hant": "暫時無法開啟訂閱管理，請稍後重試"],
        "iap_redeem_failed": ["zh": "暂时无法打开优惠码兑换，请稍后重试", "en": "Could not open offer code redemption. Please try again.", "hant": "暫時無法開啟優惠碼兌換，請稍後重試"],
        "iap_purchased": ["zh": "已解锁高级版", "en": "Pro unlocked", "hant": "已解鎖高級版"],
        "iap_restore": ["zh": "恢复购买", "en": "Restore purchases", "hant": "恢復購買"],
        "iap_redeem": ["zh": "兑换优惠码", "en": "Redeem offer code", "hant": "兌換優惠碼"],
        "iap_manage": ["zh": "管理订阅", "en": "Manage subscription", "hant": "管理訂閱"],
        "iap_prices_failed": ["zh": "暂时无法加载价格，请确认网络后重试", "en": "Unable to load prices. Check your connection and retry.", "hant": "暫時無法載入價格，請確認網路後重試"],
        "iap_retry": ["zh": "重试", "en": "Retry", "hant": "重試"],
        "iap_loading": ["zh": "加载中…", "en": "Loading…", "hant": "載入中…"],
        "iap_annual_period": ["zh": "1 年", "en": "1 year", "hant": "1 年"],
        "iap_annual_cta": ["zh": "购买一年高级版 · %1$s／年", "en": "Buy Annual Pro · %1$s/year", "hant": "購買一年高級版 · %1$s／年"],
        "iap_renewal_terms": ["zh": "年费每年扣费一次，自动续订，可随时在苹果订阅管理中取消续订。月均价仅供参考，不是按月扣费。", "en": "Annual Pro is billed once a year and renews automatically. Cancel renewal anytime in Apple subscription settings. The monthly equivalent is for reference; billing is annual.", "hant": "年費每年扣費一次，自動續訂，可隨時在蘋果訂閱管理中取消續訂。月均價僅供參考，不是按月扣費。"],
        "iap_account_hint": ["zh": "购买绑定所用的 Apple 账户，同一账户可恢复购买。", "en": "Purchases belong to the Apple Account used to buy them and can be restored with that account.", "hant": "購買綁定所用的 Apple 帳號，同一帳號可恢復購買。"],
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
        "usb_step_cable": [
            "zh": "使用 USB 数据线连接；Lightning iPhone 需相机转接器",
            "en": "Connect with a USB data cable; Lightning iPhones require a camera adapter",
            "hant": "使用 USB 資料線連接；Lightning iPhone 需相機轉接器",
        ],
    ]
}
