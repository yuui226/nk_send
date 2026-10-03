package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PhotoRatingTest {
    @Test fun objectRatingUsesExactVerifiedMapping() {
        listOf(0, 1, 25, 50, 75, 99).forEachIndexed { stars, raw ->
            assertEquals(stars, parseNikonObjectRating(byteArrayOf(raw.toByte(), 0)))
        }
        for (raw in listOf(2, 20, 40, 60, 80, 100, 255, 65535)) {
            assertNull(parseNikonObjectRating(byteArrayOf(raw.toByte(), (raw shr 8).toByte())))
        }
        assertNull(parseNikonObjectRating(byteArrayOf(25)))
        assertNull(parseNikonObjectRating(byteArrayOf(25, 0, 0, 0)))
    }

    private fun tiff(rating: Int, order: ByteOrder): ByteArray = ByteBuffer.allocate(26).order(order).apply {
        put(if (order == ByteOrder.LITTLE_ENDIAN) byteArrayOf(73,73) else byteArrayOf(77,77))
        putShort(42); putInt(8); putShort(1)
        putShort(0x4746); putShort(3); putInt(1); putShort(rating.toShort()); putShort(0); putInt(0)
    }.array()
    private fun jpeg(payload: ByteArray): ByteArray {
        val length = payload.size + 2
        return byteArrayOf(-1,-40,-1,-31,(length shr 8).toByte(),length.toByte()) + payload + byteArrayOf(-1,-39)
    }
    @Test fun standardTiffAndJpegPreserveExactStarsAndUnknown() {
        for (order in listOf(ByteOrder.LITTLE_ENDIAN, ByteOrder.BIG_ENDIAN)) {
            for (rating in 0..5) {
                val bytes = tiff(rating, order)
                assertEquals(rating, parsePhotoRating(bytes))
                assertEquals(rating, parsePhotoRating(jpeg(byteArrayOf(69,120,105,102,0,0) + bytes)))
                for (n in 0 until 22) assertNull(parsePhotoRating(bytes.copyOf(n)))
            }
            assertNull(parsePhotoRating(tiff(65535, order)))
            assertNull(parsePhotoRating(tiff(99, order)))
        }
    }
    @Test fun xmpSupportsAttributeElementAliasAndRejectedWithoutGuessing() {
        val prefix = "http://ns.adobe.com/xap/1.0/\u0000"
        for (rating in -1..5) {
            val packet = "<rdf:Description xmlns:q='http://ns.adobe.com/xap/1.0/' q:Rating='$rating'/>"
            assertEquals(rating, parsePhotoRating(jpeg((prefix + packet).toByteArray())))
            val element = "<rdf:Description xmlns:q='http://ns.adobe.com/xap/1.0/'><q:Rating>$rating</q:Rating></rdf:Description>"
            assertEquals(rating, parsePhotoRating(jpeg((prefix + element).toByteArray())))
        }
        assertNull(parsePhotoRating(jpeg((prefix + "<xmp:Rating>3</xmp:Rating>").toByteArray())))
        assertNull(parsePhotoRating(byteArrayOf(1,2,3)))
    }
    @Test fun malformedOffsetsCannotEscapeTheBoundedHeader() {
        val bytes = tiff(3, ByteOrder.LITTLE_ENDIAN)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putInt(4, Int.MAX_VALUE)
        assertNull(parsePhotoRating(bytes))
    }
    @Test fun nefXmpIsReadOnlyWhenPacketIsWithinCapturedBytes() {
        val packet = "<r xmlns:xmp='http://ns.adobe.com/xap/1.0/' xmp:Rating='4'/>".toByteArray()
        val bytes = ByteBuffer.allocate(26 + packet.size).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(byteArrayOf(73,73)); putShort(42); putInt(8); putShort(1)
            putShort(700); putShort(1); putInt(packet.size); putInt(26); putInt(0); put(packet)
        }.array()
        assertEquals(4, parsePhotoRating(bytes))
        assertNull(parsePhotoRating(bytes.copyOf(bytes.size - 1)))
    }

}
