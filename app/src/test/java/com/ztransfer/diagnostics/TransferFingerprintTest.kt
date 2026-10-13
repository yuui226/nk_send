package com.ztransfer.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class TransferFingerprintTest {
    @Test
    fun `whole file hash covers every byte including values above 127`() {
        val fingerprint = TransferFingerprint()
        fingerprint.update(byteArrayOf(0x00, 0x7f, 0x80.toByte(), 0xff.toByte()), 0, 4)
        val result = fingerprint.finish()

        assertEquals(4L, result.bytes)
        assertEquals(
            "89273d2f70b93285bb7ddb4bcee86a5347ca7159352e3cbdd20c23e9d1e507d3",
            result.sha256,
        )
    }

    @Test
    fun `split updates match one update of the same bytes`() {
        val bytes = "abc".toByteArray()
        val split = TransferFingerprint().apply {
            update(bytes, 0, 1)
            update(bytes, 1, 2)
        }.finish()
        val whole = TransferFingerprint().apply { update(bytes, 0, bytes.size) }.finish()

        assertEquals(whole, split)
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            whole.sha256,
        )
    }

    @Test
    fun `a changed byte changes the hash`() {
        val original = TransferFingerprint().apply { update(byteArrayOf(1, 2, 3), 0, 3) }.finish()
        val changed = TransferFingerprint().apply { update(byteArrayOf(1, 2, 4), 0, 3) }.finish()
        assertNotEquals(original.sha256, changed.sha256)
    }
}
