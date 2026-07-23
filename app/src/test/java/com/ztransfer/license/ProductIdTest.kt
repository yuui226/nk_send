package com.ztransfer.license

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProductIdTest {
    @Test
    fun missingProductMeansAnnualForOldServerCompatibility() {
        assertEquals(LicenseManager.ProductId.ANNUAL, LicenseManager.ProductId.fromWire(null))
        assertEquals(LicenseManager.ProductId.ANNUAL, LicenseManager.ProductId.fromWire(""))
    }

    @Test
    fun knownProductsAreParsedCaseInsensitively() {
        assertEquals(
            LicenseManager.ProductId.ANNUAL,
            LicenseManager.ProductId.fromWire("ANNUAL"),
        )
        assertEquals(
            LicenseManager.ProductId.LIFETIME,
            LicenseManager.ProductId.fromWire("lifetime"),
        )
    }

    @Test
    fun unknownProductFailsClosed() {
        assertNull(LicenseManager.ProductId.fromWire("life_time"))
    }
}
