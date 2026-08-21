package com.ztransfer.license

internal enum class OrderFailureAction {
    PRODUCT_MISMATCH,
    TERMINAL,
    RETRY,
}

internal enum class PaymentQrSource {
    ENCODE_PAY_URL,
    DOWNLOAD_PAY_QR,
    NONE,
}

internal fun hasUsableLockedPrice(priceFen: Int): Boolean = priceFen > 0

/**
 * 是否应跳过本地旧订单，按用户当前选中的商品创建新订单。
 *
 * 重要：年费和永久版是两个可独立购买的商品。用户切换商品后，即使旧商品仍有可支付
 * 二维码，也必须尊重当前选择并创建对应的新订单；旧二维码由服务端继续独立维护。
 * 这是刻意的产品规则，不能简化成“只要旧订单可支付就一律恢复”，否则切换方案会错误地
 * 恢复另一个商品并中止当前购买。只有商品相同且支付入口仍有效时才恢复旧订单。
 */
internal fun shouldCreateSelectedOrder(
    selectedProduct: LicenseManager.ProductId,
    recoveredProduct: LicenseManager.ProductId,
    hasPaymentSource: Boolean,
): Boolean = recoveredProduct != selectedProduct || !hasPaymentSource

internal fun paymentQrSource(payUrl: String?, payQr: String?): PaymentQrSource =
    when {
        !payUrl.isNullOrBlank() -> PaymentQrSource.ENCODE_PAY_URL
        !payQr.isNullOrBlank() -> PaymentQrSource.DOWNLOAD_PAY_QR
        else -> PaymentQrSource.NONE
    }

internal fun orderFailureAction(error: String): OrderFailureAction =
    when (error) {
        "PENDING_OTHER_PRODUCT", "BAD_PRODUCT" -> OrderFailureAction.PRODUCT_MISMATCH
        "NOT_FOUND", "BAD_RESPONSE" -> OrderFailureAction.TERMINAL
        else -> OrderFailureAction.RETRY
    }

internal fun nextOrderRetryDelay(currentMs: Long): Long =
    (currentMs * 2).coerceAtMost(15_000L)
