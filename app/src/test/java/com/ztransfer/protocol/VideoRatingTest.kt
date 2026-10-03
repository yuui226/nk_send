package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class VideoRatingTest {
    private fun box(type: String, data: ByteArray, extended: Boolean = false): ByteArray =
        ByteBuffer.allocate(data.size + if (extended) 16 else 8).order(ByteOrder.BIG_ENDIAN).apply {
            putInt(if (extended) 1 else capacity()); put(type.toByteArray())
            if (extended) putLong(capacity().toLong())
            put(data)
        }.array()
    private fun tag(stars: Int, type: Int = 8, count: Int = 1) = ByteBuffer.allocate(10).apply {
        putInt(0x1001); putShort(type.toShort()); putShort(count.toShort()); putShort(stars.toShort())
    }.array()
    private fun movie(stars: Int, padding: Int = 0, extended: Boolean = false): ByteArray {
        val preceding = ByteBuffer.allocate(8 + padding).apply { putInt(1); putShort(2); putShort(padding.toShort()); put(ByteArray(padding)) }.array()
        return box("ftyp", ByteArray(20)) + box("moov", box("udta", box("NCDT", box("NCTG", preceding+tag(stars)))), extended)
    }
    @Test fun parsesExactPathAndSignedShortNotFixedOffset() {
        for (stars in -1..5) for (padding in listOf(0,18,400,6000)) {
            val bytes = movie(stars,padding)
            assertEquals(stars,parseNikonVideoRating(bytes,bytes.size.toLong()))
        }
        assertEquals(5,parseNikonVideoRating(movie(5,10,true)))
        assertNull(parseNikonVideoRating(movie(6)))
        assertNull(parseNikonVideoRating(box("mdat",tag(3))))
        assertNull(parseNikonVideoRating(box("moov",box("NCTG",tag(3)))))
        for (bad in listOf(tag(3,3),tag(3,8,2))) {
            assertNull(parseNikonVideoRating(box("moov",box("udta",box("NCDT",box("NCTG",bad))))))
        }
    }
    @Test fun boundedPrefixAndOneSmallRemoteRead() = runBlocking {
        val bytes = movie(5,5800) + box("mdat",ByteArray(30000))
        var requests = 0
        val rating = readNikonVideoRating(bytes.size.toLong()) { offset,count ->
            requests++; assertTrue(count<=8192)
            bytes.copyOfRange(offset.toInt(),offset.toInt()+count)
        }
        assertEquals(5,rating); assertEquals(1,requests)
        assertEquals(5,readNikonVideoRating(bytes.size.toLong(),bytes.copyOf(8192)) { _,_ -> fail("cached prefix must suffice"); null })
        for (length in listOf(0,7,28,60,100)) assertNull(parseNikonVideoRating(bytes.copyOf(length),bytes.size.toLong()))
    }
    @Test fun skipsLargeVideoPayloadToTailMetadata() = runBlocking {
        val bytes = box("ftyp",ByteArray(20)) + box("mdat",ByteArray(200000)) + movie(2)
        val offsets = ArrayList<Long>()
        assertEquals(2,readNikonVideoRating(bytes.size.toLong()) { offset,count ->
            offsets += offset; bytes.copyOfRange(offset.toInt(),offset.toInt()+count)
        })
        assertEquals(2,offsets.size)
        assertTrue(offsets[1] > 200000)
    }
    @Test fun malformedOrTruncatedInputRemainsUnknown() = runBlocking {
        assertNull(parseNikonVideoRating(byteArrayOf(0,0,0,4,109,111,111,118)))
        val overflow = ByteBuffer.allocate(16).putInt(1).put("moov".toByteArray()).putLong(-1).array()
        assertNull(parseNikonVideoRating(overflow))
        assertNull(readNikonVideoRating(100) { _,_ -> byteArrayOf(0) })
        assertNull(readNikonVideoRating(100) { _,count -> ByteArray(count+1) })
        assertNull(readNikonVideoRating(0xffffffffL) { _,_ -> fail("unknown size"); null })
    }
    @Test fun remoteBudgetStopsWithoutDownloadingWholeFile() = runBlocking {
        val bytes = (1..40).fold(ByteArray(0)) { data,_ -> data+box("free",ByteArray(8184)) }+movie(4)
        var calls = 0
        var total = 0
        assertNull(readNikonVideoRating(bytes.size.toLong()) { offset,count ->
            calls++; total += count
            bytes.copyOfRange(offset.toInt(),offset.toInt()+count)
        })
        assertEquals(32,calls)
        assertEquals(262144,total)
    }

}
