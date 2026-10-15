package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** File container only. The camera's Get/SetPicCtrlData dataset is a separate format. */
internal class NikonPictureControlFile private constructor(
    val name: String,
    val version: String,
    private val source: ByteArray,
    private val fields: Map<Int, ByteArray>,
) {
    fun bytes(): ByteArray = source.copyOf()
    fun field(tag: Int): ByteArray? = fields[tag]?.copyOf()
    fun fieldTags(): Set<Int> = fields.keys.toSet()
    val sha256: String get() = pictureControlDigest(source)

    companion object {
        const val MAX_BYTES = 64 * 1024

        fun read(input: InputStream, checkpoint: () -> Unit = {}): NikonPictureControlFile {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                checkpoint()
                val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
                if (count < 0) break
                require(count > 0) { "Picture Control stream made no progress" }
                require(output.size() + count <= MAX_BYTES) { "Picture Control file exceeds size limit" }
                output.write(buffer, 0, count)
            }
            checkpoint()
            return parse(output.toByteArray())
        }

        fun parse(bytes: ByteArray): NikonPictureControlFile {
            require(bytes.size in 44..MAX_BYTES) { "Invalid Picture Control file size" }
            require(bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(78, 67, 80, 0))) {
                "Invalid Picture Control file signature"
            }
            val input = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN).apply { position(4) }
            val fields = linkedMapOf<Int, ByteArray>()
            var terminated = false
            while (input.remaining() >= 4) {
                val tag = input.int
                if (tag == 0) {
                    require(!input.hasRemaining()) { "Trailing Picture Control file data" }
                    terminated = true
                    break
                }
                require(input.remaining() >= 4) { "Truncated Picture Control field header" }
                val length = input.int
                require(length >= 0 && length <= input.remaining()) { "Truncated Picture Control field" }
                require(tag !in fields) { "Duplicate Picture Control field" }
                fields[tag] = ByteArray(length).also(input::get)
            }
            require(terminated) { "Missing Picture Control file terminator" }
            val versionBytes = requireNotNull(fields[0x100]) { "Missing Picture Control version" }
            require(versionBytes.size == 4 && versionBytes.all { it in 48..57 }) {
                "Invalid Picture Control version"
            }
            val version = versionBytes.toString(Charsets.US_ASCII)
            require(version.startsWith("03")) { "Not an NP3 Picture Control file" }
            val nameBytes = requireNotNull(fields[0x200]) { "Missing Picture Control name" }
            require(nameBytes.size == 20) { "Invalid Picture Control name field" }
            val nameEnd = nameBytes.indexOf(0).let { if (it < 0) nameBytes.size else it }
            require(nameEnd > 0 && nameBytes.take(nameEnd).all { it in 32..126 }) {
                "Invalid Picture Control name"
            }
            val name = nameBytes.copyOfRange(0, nameEnd).toString(Charsets.US_ASCII)
            return NikonPictureControlFile(name, version, bytes.copyOf(), fields)
        }
    }
}

internal fun pictureControlDigest(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
