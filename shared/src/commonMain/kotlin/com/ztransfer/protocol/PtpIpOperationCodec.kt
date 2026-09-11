package com.ztransfer.protocol

/** Operation response fields; signed Int preserves all 32 transaction bits across Swift/JVM. */
class PtpIpOperationResponse internal constructor(val code: Int, val transactionId: Int)

class PtpIpDataHeader internal constructor(val transactionId: Int)

/**
 * Small, non-throwing entry points for a native stream owner. Endian rules and datasets stay in
 * shared; platform code owns socket reads, deadlines and synchronization. Existing Android APIs
 * retain their throwing/tolerant behavior unchanged.
 */
object PtpIpOperationCodec {
    const val DATA_PREFIX_SIZE = 4

    /** Native arrays avoid boxed collection casts; preserve empty vs malformed and all ID bits. */
    fun decodeIdentifiers(payload: ByteArray): IntArray? = parsePtpUInt32Array(payload)?.toIntArray()

    /** No duplicate filename/date/unknown-size rules in the Apple transport. */
    fun decodeObjectInfo(handle: Int, payload: ByteArray): PtpObjectInfo? =
        parsePtpObjectInfo(handle, payload)

    fun decodeResponse(payload: ByteArray): PtpIpOperationResponse? {
        if (payload.size < 6) return null
        return PtpIpOperationResponse(
            PtpIpProtocolCodec.decodeResponseCode(payload),
            payload.readInt32LittleEndian(2),
        )
    }

    /** Pass only the four-byte prefix; the file data never needs to cross the native bridge. */
    fun decodeDataHeader(prefix: ByteArray): PtpIpDataHeader? =
        if (prefix.size < DATA_PREFIX_SIZE) null
        else PtpIpDataHeader(prefix.readInt32LittleEndian(0))

    /** Converts malformed wire datasets to null before returning across the Objective-C boundary. */
    fun decodeDeviceInfo(payload: ByteArray): LabDeviceInfo? = try {
        parseDeviceInfo(payload)
    } catch (_: IndexOutOfBoundsException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }
}
