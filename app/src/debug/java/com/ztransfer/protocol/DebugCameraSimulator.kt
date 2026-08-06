package com.ztransfer.protocol

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.CRC32
import java.util.zip.Deflater

/** Minimal Nikon-like PTP/IP camera compiled and started only in Debug builds. */
internal object DebugCameraSimulator {
    private const val PORT = 15740
    private const val STORAGE_ID_1 = 0x00010001
    private const val STORAGE_ID_2 = 0x00020001
    private const val PHOTO_COUNT = 36

    private const val INIT_CMD_REQ = 1
    private const val INIT_CMD_ACK = 2
    private const val INIT_EVT_REQ = 3
    private const val INIT_EVT_ACK = 4
    private const val CMD_REQUEST = 6
    private const val CMD_RESPONSE = 7
    private const val START_DATA_PACKET = 9
    private const val END_DATA_PACKET = 12
    private const val PING = 13
    private const val PONG = 14

    private const val GET_DEVICE_INFO = 0x1001
    private const val OPEN_SESSION = 0x1002
    private const val CLOSE_SESSION = 0x1003
    private const val GET_STORAGE_IDS = 0x1004
    private const val GET_OBJECT_HANDLES = 0x1007
    private const val GET_OBJECT_INFO = 0x1008
    private const val GET_OBJECT = 0x1009
    private const val GET_THUMB = 0x100A
    private const val NK_GET_EVENT = 0x90C7
    private const val NK_GET_FHD_PICTURE = 0x920F
    private const val NK_GET_OBJECT_SIZE = 0x9421
    private const val NK_GET_PARTIAL_OBJECT_EX = 0x9431

    private const val RESPONSE_OK = 0x2001
    private const val OPERATION_NOT_SUPPORTED = 0x2005
    private const val INVALID_OBJECT_HANDLE = 0x2009
    private const val FORMAT_JPEG = 0x3801
    private const val FORMAT_PNG = 0x3804

    private val connectionNumbers = AtomicInteger(0)
    @Volatile private var started = false

    @Synchronized
    fun start(featuredImage: FeaturedImage? = null) {
        if (started) return
        started = true
        Thread({ serve(featuredImage) }, "Debug-Camera-Simulator").apply {
            isDaemon = true
            start()
        }
    }

    private fun serve(featuredImage: FeaturedImage?) {
        try {
            ServerSocket().use { server ->
                server.reuseAddress = true
                // Android may resolve getLoopbackAddress() to IPv6 ::1 while the production
                // client is intentionally pointed at IPv4 127.0.0.1. Bind the exact same
                // address so the in-process client and server cannot land on different stacks.
                server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT))
                // Bind before generating sample images. A connection arriving during generation
                // waits in the listen backlog instead of failing with Connection refused.
                val objects = buildObjects(featuredImage)
                println("DebugCameraSimulator listening on 127.0.0.1:$PORT")
                while (true) {
                    val socket = server.accept()
                    Thread(
                        { handleConnection(socket, objects) },
                        "Debug-Camera-Client"
                    ).apply {
                        isDaemon = true
                        start()
                    }
                }
            }
        } catch (error: Exception) {
            started = false
            System.err.println("DebugCameraSimulator stopped: ${error.stackTraceToString()}")
        }
    }

    private fun handleConnection(socket: Socket, objects: Map<Int, SimObject>) {
        socket.use {
            it.soTimeout = 70_000
            try {
                val first = readPacket(it.getInputStream())
                when (first.type) {
                    INIT_CMD_REQ -> handleCommandChannel(it, objects)
                    INIT_EVT_REQ -> handleEventChannel(it, first.payload)
                    else -> Unit
                }
            } catch (_: EOFException) {
                // Client closed normally.
            } catch (error: Exception) {
                println("DebugCameraSimulator client ended: ${error.message}")
            }
        }
    }

    private fun handleCommandChannel(socket: Socket, objects: Map<Int, SimObject>) {
        val output = socket.getOutputStream()
        val connectionNumber = connectionNumbers.incrementAndGet()
        val ack = littleEndian(4) { putInt(connectionNumber) } +
            "ZTRANSFERSIM0001".toByteArray(Charsets.US_ASCII) +
            "Z SIM\u0000".toByteArray(Charsets.UTF_16LE)
        writePacket(output, INIT_CMD_ACK, ack)

        val input = socket.getInputStream()
        while (true) {
            val incoming = readPacket(input)
            if (incoming.type == PING) {
                writePacket(output, PONG)
                continue
            }
            if (incoming.type != CMD_REQUEST || incoming.payload.size < 10) continue

            val operation = incoming.payload.u16Le(4)
            val transactionId = incoming.payload.i32Le(6)
            val params = buildList {
                var offset = 10
                while (offset + 4 <= incoming.payload.size) {
                    add(incoming.payload.i32Le(offset))
                    offset += 4
                }
            }
            if (dispatch(output, operation, transactionId, params, objects)) return
        }
    }

    private fun handleEventChannel(socket: Socket, payload: ByteArray) {
        payload.i32LeOrZero(0) // Parse the connection number for protocol completeness.
        val output = socket.getOutputStream()
        writePacket(output, INIT_EVT_ACK)
        socket.soTimeout = 0
        val input = socket.getInputStream()
        while (true) {
            val incoming = readPacket(input)
            if (incoming.type == PING) writePacket(output, PONG)
        }
    }

    private fun dispatch(
        output: java.io.OutputStream,
        operation: Int,
        transactionId: Int,
        params: List<Int>,
        objects: Map<Int, SimObject>
    ): Boolean {
        when (operation) {
            OPEN_SESSION -> sendResponse(output, transactionId)
            CLOSE_SESSION -> {
                sendResponse(output, transactionId)
                return true
            }
            GET_DEVICE_INFO -> sendData(output, transactionId, deviceInfo())
            GET_STORAGE_IDS -> sendData(
                output,
                transactionId,
                littleEndian(12) {
                    putInt(2)
                    putInt(STORAGE_ID_1)
                    putInt(STORAGE_ID_2)
                }
            )
            GET_OBJECT_HANDLES -> {
                val requestedStorageId = params.firstOrNull() ?: -1
                val handles = objects.values.asSequence()
                    .filter { requestedStorageId == -1 || it.storageId == requestedStorageId }
                    .map { it.handle }
                    .sortedDescending()
                    .toList()
                sendData(output, transactionId, littleEndian(4 + handles.size * 4) {
                    putInt(handles.size)
                    handles.forEach(::putInt)
                })
            }
            else -> {
                val obj = params.firstOrNull()?.let(objects::get)
                if (operation in objectOperations && obj == null) {
                    sendResponse(output, transactionId, INVALID_OBJECT_HANDLE)
                    return false
                }
                when (operation) {
                    GET_OBJECT_INFO -> sendData(output, transactionId, obj!!.objectInfo())
                    GET_OBJECT -> sendData(output, transactionId, obj!!.image)
                    NK_GET_FHD_PICTURE -> sendData(output, transactionId, obj!!.fhdPreview)
                    GET_THUMB -> sendData(output, transactionId, obj!!.thumbnail)
                    NK_GET_OBJECT_SIZE -> sendData(
                        output,
                        transactionId,
                        littleEndian(8) { putLong(obj!!.image.size.toLong()) }
                    )
                    NK_GET_PARTIAL_OBJECT_EX -> {
                        val offset = params.unsignedLong(1) or (params.unsignedLong(2) shl 32)
                        val requested = if (params.size > 3) {
                            params.unsignedLong(3) or (params.unsignedLong(4) shl 32)
                        } else {
                            obj!!.image.size.toLong()
                        }
                        val start = offset.coerceIn(0, obj!!.image.size.toLong()).toInt()
                        val end = (offset + requested)
                            .coerceIn(start.toLong(), obj.image.size.toLong()).toInt()
                        sendData(output, transactionId, obj.image.copyOfRange(start, end))
                    }
                    NK_GET_EVENT -> sendData(output, transactionId, byteArrayOf())
                    else -> sendResponse(output, transactionId, OPERATION_NOT_SUPPORTED)
                }
            }
        }
        return false
    }

    private fun sendResponse(
        output: java.io.OutputStream,
        transactionId: Int,
        responseCode: Int = RESPONSE_OK
    ) {
        writePacket(output, CMD_RESPONSE, littleEndian(6) {
            putShort(responseCode.toShort())
            putInt(transactionId)
        })
    }

    private fun sendData(
        output: java.io.OutputStream,
        transactionId: Int,
        data: ByteArray
    ) {
        writePacket(output, START_DATA_PACKET, littleEndian(12) {
            putInt(transactionId)
            putLong(data.size.toLong())
        })
        writePacket(
            output,
            END_DATA_PACKET,
            littleEndian(4) { putInt(transactionId) } + data
        )
        sendResponse(output, transactionId)
    }

    private data class Packet(val type: Int, val payload: ByteArray)

    private fun readPacket(input: InputStream): Packet {
        val header = input.readExact(8)
        val length = header.i32Le(0)
        require(length in 8..(256 * 1024 * 1024)) { "invalid packet length $length" }
        return Packet(header.i32Le(4), input.readExact(length - 8))
    }

    private fun writePacket(
        output: java.io.OutputStream,
        type: Int,
        payload: ByteArray = byteArrayOf()
    ) {
        output.write(littleEndian(8) {
            putInt(8 + payload.size)
            putInt(type)
        })
        output.write(payload)
        output.flush()
    }

    private data class SimObject(
        val handle: Int,
        val storageId: Int,
        val fileName: String,
        val captureDate: String,
        val protected: Boolean,
        val format: Int,
        val image: ByteArray,
        val fhdPreview: ByteArray,
        val thumbnail: ByteArray,
        val width: Int,
        val height: Int,
        val thumbnailWidth: Int,
        val thumbnailHeight: Int,
    ) {
        fun objectInfo(): ByteArray {
            val fixed = littleEndian(52) {
                putInt(storageId)
                putShort(format.toShort())
                putShort(if (protected) 1 else 0)
                putInt(image.size)
                putShort(format.toShort())
                putInt(thumbnail.size)
                putInt(thumbnailWidth)
                putInt(thumbnailHeight)
                putInt(width)
                putInt(height)
                putInt(24)
                putInt(0)
                putShort(0)
                putInt(0)
                putInt(handle)
            }
            return fixed + ptpString(fileName) + ptpString(captureDate) +
                ptpString(captureDate) + ptpString("")
        }
    }

    private fun buildObjects(featured: FeaturedImage?): Map<Int, SimObject> {
        val variants = Array(12) { variant ->
            val portrait = variant == 3 || variant == 9
            val width = if (portrait) 320 else 480
            val height = if (portrait) 480 else 320
            Triple(width, height, makeImage(width, height, variant))
        }
        val formatter = SimpleDateFormat("yyyyMMdd'T'HHmmss", Locale.US)
        val now = System.currentTimeMillis()
        return (0 until PHOTO_COUNT).associate { index ->
            val handle = 0x1001 + index
            val generated = variants[index % variants.size]
            val featuredItem = featured.takeIf { index == 0 }
            val isFeatured = featuredItem != null
            val width = featuredItem?.width ?: generated.first
            val height = featuredItem?.height ?: generated.second
            val image = featuredItem?.image ?: generated.third
            val thumbnail = featuredItem?.thumbnail ?: image
            handle to SimObject(
                handle = handle,
                storageId = if (index % 2 == 0) STORAGE_ID_1 else STORAGE_ID_2,
                fileName = "ZSIM_%04d.%s".format(
                    Locale.US,
                    index + 1,
                    if (isFeatured) "JPG" else "PNG",
                ),
                captureDate = formatter.format(Date(now - index * 5L * 60L * 60L * 1000L)),
                protected = index % 11 == 1,
                format = if (isFeatured) FORMAT_JPEG else FORMAT_PNG,
                image = image,
                fhdPreview = featuredItem?.fhdPreview ?: image,
                thumbnail = thumbnail,
                width = width,
                height = height,
                thumbnailWidth = featuredItem?.thumbnailWidth ?: width,
                thumbnailHeight = featuredItem?.thumbnailHeight ?: height,
            )
        }
    }

    internal data class FeaturedImage(
        val image: ByteArray,
        val fhdPreview: ByteArray,
        val thumbnail: ByteArray,
        val width: Int,
        val height: Int,
        val thumbnailWidth: Int,
        val thumbnailHeight: Int,
    )

    private fun makeImage(width: Int, height: Int, variant: Int): ByteArray {
        val rows = ByteArray(height * (1 + width * 3))
        var cursor = 0
        val seed = variant + 1
        val horizon = height * (35 + seed * 4) / 100
        val centerX = width * (22 + seed * 11) / 100
        val centerY = height * (52 + (seed % 2) * 9) / 100
        val radius = minOf(width, height) * (10 + seed % 3) / 100
        for (y in 0 until height) {
            rows[cursor++] = 0 // PNG scanline filter: none
            for (x in 0 until width) {
                var red: Int
                var green: Int
                var blue: Int
                if (y < horizon) {
                    red = 28 + x * 75 / width + seed * 9
                    green = 75 + y * 95 / maxOf(1, horizon) + seed * 5
                    blue = 145 + x * 60 / width
                } else {
                    val depth = (y - horizon) * 120 / maxOf(1, height - horizon)
                    red = 42 + depth + seed * 11
                    green = 92 - depth / 3 + x * 35 / width
                    blue = 48 + seed * 7
                }
                if ((x - centerX) * (x - centerX) + (y - centerY) * (y - centerY) <
                    radius * radius
                ) {
                    red = 235
                    green = 178 + seed * 7
                    blue = 70 + seed * 13
                }
                if (kotlin.math.abs((x + seed * 31) - (y * width / maxOf(1, height))) < 3) {
                    red = 225
                    green = 232
                    blue = 220
                }
                rows[cursor++] = red.toByte()
                rows[cursor++] = green.toByte()
                rows[cursor++] = blue.toByte()
            }
        }

        val header = ByteBuffer.allocate(13).order(ByteOrder.BIG_ENDIAN).apply {
            putInt(width)
            putInt(height)
            put(8.toByte()) // bit depth
            put(2.toByte()) // truecolour
            put(0.toByte()) // compression
            put(0.toByte()) // filter
            put(0.toByte()) // interlace
        }.array()
        return PNG_SIGNATURE + pngChunk("IHDR", header) +
            pngChunk("IDAT", deflate(rows)) + pngChunk("IEND", byteArrayOf())
    }

    private fun pngChunk(kind: String, data: ByteArray): ByteArray {
        val kindBytes = kind.toByteArray(Charsets.US_ASCII)
        val checksum = CRC32().apply {
            update(kindBytes)
            update(data)
        }.value
        return bigEndian(4) { putInt(data.size) } + kindBytes + data +
            bigEndian(4) { putInt(checksum.toInt()) }
    }

    private fun deflate(data: ByteArray): ByteArray {
        val deflater = Deflater(7)
        return try {
            deflater.setInput(data)
            deflater.finish()
            ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(8 * 1024)
                while (!deflater.finished()) {
                    val count = deflater.deflate(buffer)
                    if (count > 0) output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            deflater.end()
        }
    }

    private fun deviceInfo(): ByteArray = ByteArrayOutputStream().use { output ->
        output.write(littleEndian(8) { putShort(100); putInt(10); putShort(100) })
        output.write(ptpString("ZTransfer Camera Simulator"))
        output.write(littleEndian(2) { putShort(0) })
        output.write(u16Array(listOf(
            GET_DEVICE_INFO,
            OPEN_SESSION,
            CLOSE_SESSION,
            GET_STORAGE_IDS,
            GET_OBJECT_HANDLES,
            GET_OBJECT_INFO,
            GET_OBJECT,
            GET_THUMB
        )))
        repeat(3) { output.write(u16Array(emptyList())) }
        output.write(u16Array(listOf(FORMAT_JPEG, FORMAT_PNG)))
        output.write(ptpString("Nikon Simulator"))
        output.write(ptpString("Z SIM"))
        output.write(ptpString("1.0"))
        output.write(ptpString("ZSIM0001"))
        output.toByteArray()
    }

    private val objectOperations = setOf(
        GET_OBJECT_INFO,
        GET_OBJECT,
        GET_THUMB,
        NK_GET_FHD_PICTURE,
        NK_GET_OBJECT_SIZE,
        NK_GET_PARTIAL_OBJECT_EX
    )

    private fun ptpString(value: String): ByteArray {
        if (value.isEmpty()) return byteArrayOf(0)
        val encoded = "$value\u0000".toByteArray(Charsets.UTF_16LE)
        return byteArrayOf((encoded.size / 2).toByte()) + encoded
    }

    private fun u16Array(values: List<Int>): ByteArray = littleEndian(4 + values.size * 2) {
        putInt(values.size)
        values.forEach { putShort(it.toShort()) }
    }

    private fun littleEndian(size: Int, fill: ByteBuffer.() -> Unit): ByteArray =
        ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN).apply(fill).array()

    private fun bigEndian(size: Int, fill: ByteBuffer.() -> Unit): ByteArray =
        ByteBuffer.allocate(size).order(ByteOrder.BIG_ENDIAN).apply(fill).array()

    private val PNG_SIGNATURE = byteArrayOf(
        0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
    )

    private fun InputStream.readExact(size: Int): ByteArray {
        val result = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = read(result, offset, size - offset)
            if (count < 0) throw EOFException("peer closed")
            offset += count
        }
        return result
    }

    private fun ByteArray.i32Le(offset: Int): Int =
        ByteBuffer.wrap(this, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int

    private fun ByteArray.i32LeOrZero(offset: Int): Int =
        if (size >= offset + 4) i32Le(offset) else 0

    private fun ByteArray.u16Le(offset: Int): Int =
        ByteBuffer.wrap(this, offset, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF

    private fun List<Int>.unsignedLong(index: Int): Long =
        (getOrNull(index)?.toLong() ?: 0L) and 0xFFFF_FFFFL
}
