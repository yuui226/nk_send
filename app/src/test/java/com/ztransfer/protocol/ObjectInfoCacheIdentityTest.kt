package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ObjectInfoCacheIdentityTest {
    @Test
    fun `complete filename and date are safe for cache reconciliation`() {
        val result = parseObjectCacheIdentity(
            handle = 7,
            extension = ".JPG",
            data = payload("DSC_0007.JPG", "20260812T120000"),
        )

        assertTrue(result.complete)
        assertEquals("DSC_0007.JPG", result.fileName)
        assertEquals("20260812T120000", result.captureDate)
    }

    @Test
    fun `explicitly empty capture date is complete`() {
        val result = parseObjectCacheIdentity(7, ".JPG", payload("DSC_0007.JPG", null))

        assertTrue(result.complete)
        assertNull(result.captureDate)
    }

    @Test
    fun `truncated filename prevents cache reconciliation`() {
        val data = ByteArray(55)
        data[52] = 8

        val result = parseObjectCacheIdentity(7, ".JPG", data)

        assertFalse(result.complete)
        assertEquals("DSC_0007.JPG", result.fileName)
    }

    @Test
    fun `truncated capture date prevents cache reconciliation`() {
        val complete = payload("DSC_0007.JPG", "20260812T120000")
        val result = parseObjectCacheIdentity(7, ".JPG", complete.copyOf(complete.size - 4))

        assertFalse(result.complete)
        assertNull(result.captureDate)
    }

    @Test
    fun `unterminated PTP string prevents cache reconciliation`() {
        val data = payload("DSC_0007.JPG", "20260812T120000")
        data[data.lastIndex] = 'X'.code.toByte()

        val result = parseObjectCacheIdentity(7, ".JPG", data)

        assertFalse(result.complete)
        assertNull(result.captureDate)
    }

    private fun payload(fileName: String, captureDate: String?): ByteArray {
        val encodedName = (fileName + '\u0000').toByteArray(Charsets.UTF_16LE)
        val encodedDate = captureDate?.let { (it + '\u0000').toByteArray(Charsets.UTF_16LE) }
        val result = ByteArray(53 + encodedName.size + 1 + (encodedDate?.size ?: 0))
        result[52] = (fileName.length + 1).toByte()
        encodedName.copyInto(result, 53)
        val dateOffset = 53 + encodedName.size
        result[dateOffset] = if (captureDate == null) 0 else (captureDate.length + 1).toByte()
        encodedDate?.copyInto(result, dateOffset + 1)
        return result
    }
}
