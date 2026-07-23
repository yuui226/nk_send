package com.ztransfer.license

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PurchaseSafetyTest {
    @Test
    fun lockedPriceMustBePositive() {
        assertFalse(hasUsableLockedPrice(0))
        assertFalse(hasUsableLockedPrice(-1))
        assertTrue(hasUsableLockedPrice(1))
    }

    @Test
    fun paymentQrUsesUrlFirstAndSupportsQrImageOnlyResponses() {
        assertEquals(
            PaymentQrSource.ENCODE_PAY_URL,
            paymentQrSource("https://pay.example/order", "https://pay.example/qr.png"),
        )
        assertEquals(
            PaymentQrSource.DOWNLOAD_PAY_QR,
            paymentQrSource(null, "https://pay.example/qr.png"),
        )
        assertEquals(PaymentQrSource.NONE, paymentQrSource(null, null))
        assertEquals(PaymentQrSource.NONE, paymentQrSource(" ", ""))
    }

    @Test
    fun orderErrorsAreClassifiedConservatively() {
        assertEquals(
            OrderFailureAction.PRODUCT_MISMATCH,
            orderFailureAction("PENDING_OTHER_PRODUCT"),
        )
        assertEquals(OrderFailureAction.PRODUCT_MISMATCH, orderFailureAction("BAD_PRODUCT"))
        assertEquals(OrderFailureAction.TERMINAL, orderFailureAction("NOT_FOUND"))
        assertEquals(OrderFailureAction.TERMINAL, orderFailureAction("BAD_RESPONSE"))
        assertEquals(OrderFailureAction.RETRY, orderFailureAction("HTTP_503"))
    }

    @Test
    fun retryDelayDoublesAndCapsAtFifteenSeconds() {
        assertEquals(4_000L, nextOrderRetryDelay(2_000L))
        assertEquals(8_000L, nextOrderRetryDelay(4_000L))
        assertEquals(15_000L, nextOrderRetryDelay(8_000L))
        assertEquals(15_000L, nextOrderRetryDelay(15_000L))
    }
}
