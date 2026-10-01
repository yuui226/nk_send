package com.ztransfer.lut

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class PhotoLutSnapshotCodecTest {
    private fun original() = CubeLutParser.parse(("DOMAIN_MIN -0.5 0.1 0\nDOMAIN_MAX 1.5 0.9 1\nLUT_3D_SIZE 2\n" +
        (0..7).joinToString("\n") { "${it*.1234567f} -0.01234567 1.234567" }).byteInputStream())
    @Test fun snapshotsRetainAllFloatBitsAndContentIdentity() {
        val table=original()
        val bytes=ByteArrayOutputStream().also { PhotoLutSnapshotCodec.write(table,it) }.toByteArray()
        val restored=PhotoLutSnapshotCodec.read(bytes.inputStream(),table.digest)
        assertEquals(table.digest,restored.digest)
        assertEquals(table.size,restored.size)
        assertArrayEquals(table.domainMin,restored.domainMin,0f)
        assertArrayEquals(table.domainMax,restored.domainMax,0f)
        assertArrayEquals(table.rgb,restored.rgb,0f)
    }
    @Test fun brokenSnapshotsNeverBecomePartialOrBlackTables() {
        val bytes=ByteArrayOutputStream().also { PhotoLutSnapshotCodec.write(original(),it) }.toByteArray()
        for (bad in listOf(bytes.copyOf(bytes.size-1),bytes+byteArrayOf(0),bytes.copyOf().apply { this[7]=127 })) {
            try { PhotoLutSnapshotCodec.read(bad.inputStream(),"test"); fail("Accepted broken snapshot") }
            catch (_: Exception) { }
        }
    }
}
