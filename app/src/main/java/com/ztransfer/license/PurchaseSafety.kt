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
