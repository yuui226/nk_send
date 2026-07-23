package com.ztransfer.protocol

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.hardware.usb.UsbRequest
import android.os.Build
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.TimeoutException

/**
 * Raw PTP-over-USB transport.
 *
 * PTP operation codes and datasets are shared with PTP/IP, but their wire containers are not:
 * USB uses a 12-byte container header over bulk endpoints and an optional interrupt endpoint for
 * events. This class owns only the USB wire protocol; Nikon operation semantics stay in
 * [NikonCamera].
 */
internal class UsbPtpConnection private constructor(
    private val connection: UsbDeviceConnection,
    private val ptpInterface: UsbInterface,
    private val bulkIn: UsbEndpoint,
    private val bulkOut: UsbEndpoint,
    private val bulkInRequest: UsbRequest,
    private val bulkOutRequest: UsbRequest
) : Closeable {

    data class StreamResult(
        val responseCode: Int,
        val written: Long,
        val expected: Long,
        val readNanos: Long
    )

    private data class Header(
        val length: Long,
        val type: Int,
        val code: Int,
        val transactionId: Int
    ) {
        val payloadLength: Long get() = length - HEADER_SIZE
    }

    @Volatile
    var readTimeoutMs: Int = NikonCamera.SO_TIMEOUT_MS

    @Volatile
    private var closed = false

    private val ioBuffer = ByteArray(
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) 256 * 1024 else 16 * 1024
    )
    // A bulk endpoint is packet based, not a TCP-style byte stream. Always submit a reasonably
    // sized USB read and retain bytes beyond the caller's request (most importantly, bytes that
    // arrive in the same packet as the 12-byte PTP container header).
    private val usbReadBuffer = ByteArray(ioBuffer.size)
    private var bufferedReadOffset = 0
    private var bufferedReadEnd = 0

    fun sendCommand(code: Int, transactionId: Int, params: IntArray) {
        val count = params.size.coerceAtMost(5)
        val bytes = ByteBuffer.allocate(HEADER_SIZE + count * 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .apply {
                putInt(HEADER_SIZE + count * 4)
                putShort(TYPE_COMMAND.toShort())
                putShort(code.toShort())
                putInt(transactionId)
                repeat(count) { putInt(params[it]) }
            }
            .array()
        writeFully(bytes)
    }

    fun sendData(code: Int, transactionId: Int, data: ByteArray) {
        val container = ByteBuffer.allocate(HEADER_SIZE + data.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .apply {
                putInt(HEADER_SIZE + data.size)
                putShort(TYPE_DATA.toShort())
                putShort(code.toShort())
                putInt(transactionId)
                put(data)
            }
            .array()
        // Keep the header and its first payload bytes in one USB transfer. A short transfer after
        // only the 12-byte header can otherwise be interpreted as the end of an incomplete data
        // container by stricter camera implementations.
        writeFully(container)
    }

    /** Receives an operation response, discarding any data phase. */
    fun receiveResponse(expectedTransactionId: Int): Int {
        while (true) {
            val header = readHeader()
            checkTransaction(header, expectedTransactionId)
            when (header.type) {
                TYPE_DATA -> discardPayload(header.payloadLength)
                TYPE_RESPONSE -> {
                    discardPayload(header.payloadLength)
                    return header.code
                }
                else -> throw IOException("Unexpected PTP/USB container type ${header.type}")
            }
        }
    }

    /** Receives the optional data phase followed by the operation response. */
    fun receiveResponseWithPayload(expectedTransactionId: Int): Pair<Int, ByteArray?> {
        var payload: ByteArray? = null
        while (true) {
            val header = readHeader()
            checkTransaction(header, expectedTransactionId)
            when (header.type) {
                TYPE_DATA -> {
                    if (header.payloadLength > MAX_IN_MEMORY_PAYLOAD) {
                        throw IOException("PTP/USB payload too large: ${header.payloadLength}")
                    }
                    payload = ByteArray(header.payloadLength.toInt()).also { readFully(it, 0, it.size) }
                }
                TYPE_RESPONSE -> {
                    discardPayload(header.payloadLength)
                    return header.code to payload
                }
                else -> throw IOException("Unexpected PTP/USB container type ${header.type}")
            }
        }
    }

    /**
     * Streams one data phase without allocating the complete object, then consumes its response.
     * [onChunk] is invoked before the backing buffer is reused.
     */
    fun receiveDataTo(
        expectedTransactionId: Int,
        onChunk: (ByteArray, Int, Int) -> Unit
    ): StreamResult {
        val first = readHeader()
        checkTransaction(first, expectedTransactionId)
        if (first.type == TYPE_RESPONSE) {
            discardPayload(first.payloadLength)
            return StreamResult(first.code, 0L, -1L, 0L)
        }
        if (first.type != TYPE_DATA) {
            throw IOException("Expected PTP/USB data container, got ${first.type}")
        }

        var remaining = first.payloadLength
        var written = 0L
        var readNanos = 0L
        while (remaining > 0L) {
            val want = minOf(remaining, ioBuffer.size.toLong()).toInt()
            val started = System.nanoTime()
            val count = readSome(ioBuffer, 0, want)
            readNanos += System.nanoTime() - started
            onChunk(ioBuffer, 0, count)
            remaining -= count
            written += count
        }

        val response = readHeader()
        checkTransaction(response, expectedTransactionId)
        if (response.type != TYPE_RESPONSE) {
            throw IOException("Expected PTP/USB response container, got ${response.type}")
        }
        discardPayload(response.payloadLength)
        return StreamResult(response.code, written, first.payloadLength, readNanos)
    }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { bulkInRequest.cancel() }
        runCatching { bulkOutRequest.cancel() }
        runCatching { bulkInRequest.close() }
        runCatching { bulkOutRequest.close() }
        runCatching { connection.releaseInterface(ptpInterface) }
        connection.close()
    }

    private fun readHeader(): Header {
        val bytes = ByteArray(HEADER_SIZE)
        readFully(bytes, 0, bytes.size)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val length = b.int.toLong() and 0xFFFFFFFFL
        if (length < HEADER_SIZE || length > MAX_CONTAINER_SIZE) {
            throw IOException("Invalid PTP/USB container length: $length")
        }
        return Header(
            length = length,
            type = b.short.toInt() and 0xFFFF,
            code = b.short.toInt() and 0xFFFF,
            transactionId = b.int
        )
    }

    private fun checkTransaction(header: Header, expected: Int) {
        if (header.transactionId != expected) {
            throw IOException(
                "PTP/USB transaction mismatch: expected=$expected actual=${header.transactionId}"
            )
        }
    }

    private fun discardPayload(length: Long) {
        var remaining = length
        while (remaining > 0L) {
            val count = readSome(ioBuffer, 0, minOf(remaining, ioBuffer.size.toLong()).toInt())
            remaining -= count
        }
    }

    private fun readFully(target: ByteArray, offset: Int, length: Int) {
        var done = 0
        while (done < length) {
            done += readSome(target, offset + done, length - done)
        }
    }

    private fun readSome(target: ByteArray, offset: Int, length: Int): Int {
        if (closed) throw EOFException("USB camera disconnected")
        if (bufferedReadOffset < bufferedReadEnd) {
            val count = minOf(length, bufferedReadEnd - bufferedReadOffset)
            usbReadBuffer.copyInto(
                destination = target,
                destinationOffset = offset,
                startIndex = bufferedReadOffset,
                endIndex = bufferedReadOffset + count
            )
            bufferedReadOffset += count
            return count
        }

        bufferedReadOffset = 0
        bufferedReadEnd = 0
        var skippedZeroLengthPacket = false
        while (true) {
            val buffer = ByteBuffer.wrap(usbReadBuffer)
            if (!bulkInRequest.queue(buffer)) {
                throw IOException("PTP/USB bulk IN queue failed endpoint=0x${bulkIn.address.toString(16)}")
            }
            val completed = try {
                connection.requestWait(readTimeoutMs.coerceAtLeast(1).toLong())
            } catch (e: TimeoutException) {
                bulkInRequest.cancel()
                throw SocketTimeoutException("PTP/USB bulk read timed out")
            }
            if (completed !== bulkInRequest) {
                throw IOException("PTP/USB unexpected completed request")
            }
            val result = buffer.position()
            if (result > 0) {
                val count = minOf(length, result)
                usbReadBuffer.copyInto(
                    destination = target,
                    destinationOffset = offset,
                    startIndex = 0,
                    endIndex = count
                )
                bufferedReadOffset = count
                bufferedReadEnd = result
                return count
            }
            if (skippedZeroLengthPacket) {
                throw SocketTimeoutException("PTP/USB bulk read timed out or device disconnected")
            }

            // A PTP data phase whose size ends at the endpoint packet boundary may be followed by
            // a USB zero-length packet before the response container. Android's native MTP host
            // explicitly consumes that packet and reads once more.
            skippedZeroLengthPacket = true
        }
    }

    private fun writeFully(source: ByteArray) {
        var offset = 0
        while (offset < source.size) {
            if (closed) throw EOFException("USB camera disconnected")
            val count = minOf(source.size - offset, ioBuffer.size)
            val buffer = ByteBuffer.wrap(source, offset, count)
            val start = buffer.position()
            if (!bulkOutRequest.queue(buffer)) {
                throw IOException(
                    "PTP/USB bulk OUT queue failed endpoint=0x${bulkOut.address.toString(16)}"
                )
            }
            val completed = try {
                connection.requestWait(WRITE_TIMEOUT_MS.toLong())
            } catch (e: TimeoutException) {
                bulkOutRequest.cancel()
                throw SocketTimeoutException("PTP/USB bulk write timed out")
            }
            if (completed !== bulkOutRequest) {
                throw IOException("PTP/USB unexpected completed request")
            }
            val result = buffer.position() - start
            if (result <= 0) {
                throw IOException(
                    "PTP/USB bulk OUT completed without data endpoint=0x${bulkOut.address.toString(16)}"
                )
            }
            offset += result
        }
    }

    companion object {
        private data class BulkEndpoints(
            val input: UsbEndpoint,
            val output: UsbEndpoint
        )

        private const val HEADER_SIZE = 12
        private const val TYPE_COMMAND = 1
        private const val TYPE_DATA = 2
        private const val TYPE_RESPONSE = 3

        private const val WRITE_TIMEOUT_MS = 10_000
        private const val MAX_IN_MEMORY_PAYLOAD = 256L * 1024L * 1024L
        private const val MAX_CONTAINER_SIZE = 0xFFFFFFFFL

        fun findPtpInterface(device: UsbDevice): UsbInterface? {
            for (index in 0 until device.interfaceCount) {
                val candidate = device.getInterface(index)
                if (candidate.interfaceClass != UsbConstants.USB_CLASS_STILL_IMAGE) continue
                if (findBulkEndpoints(candidate) != null) return candidate
            }
            return null
        }

        private fun findBulkEndpoints(intf: UsbInterface): BulkEndpoints? {
            var input: UsbEndpoint? = null
            var output: UsbEndpoint? = null
            for (index in 0 until intf.endpointCount) {
                val endpoint = intf.getEndpoint(index)
                if (endpoint.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (endpoint.direction == UsbConstants.USB_DIR_IN) input = endpoint
                if (endpoint.direction == UsbConstants.USB_DIR_OUT) output = endpoint
            }
            return if (input != null && output != null) BulkEndpoints(input, output) else null
        }

        fun open(manager: UsbManager, device: UsbDevice): Result<UsbPtpConnection> = runCatching {
            val intf = findPtpInterface(device)
                ?: throw IOException("No PTP still-image USB interface found")
            val connection = manager.openDevice(device)
                ?: throw IOException("Unable to open USB camera (permission missing)")
            if (!connection.claimInterface(intf, true)) {
                connection.close()
                throw IOException("Unable to claim PTP USB interface")
            }
            if (intf.alternateSetting != 0 && !connection.setInterface(intf)) {
                connection.releaseInterface(intf)
                connection.close()
                throw IOException("Unable to select PTP USB alternate setting ${intf.alternateSetting}")
            }

            val endpoints = findBulkEndpoints(intf)
            if (endpoints == null) {
                connection.releaseInterface(intf)
                connection.close()
                throw IOException("PTP USB bulk endpoints are incomplete")
            }
            val inRequest = UsbRequest()
            if (!inRequest.initialize(connection, endpoints.input)) {
                connection.releaseInterface(intf)
                connection.close()
                throw IOException("Unable to initialize PTP bulk IN request")
            }
            val outRequest = UsbRequest()
            if (!outRequest.initialize(connection, endpoints.output)) {
                inRequest.close()
                connection.releaseInterface(intf)
                connection.close()
                throw IOException("Unable to initialize PTP bulk OUT request")
            }
            UsbPtpConnection(
                connection,
                intf,
                endpoints.input,
                endpoints.output,
                inRequest,
                outRequest
            )
        }
    }
}
