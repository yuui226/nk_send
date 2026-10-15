package com.ztransfer.protocol

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** An empty slot is an explicit snapshot, never inferred from a failed read. */
internal class PictureControlSlotSnapshot(
    val cameraIdentity: String,
    val slot: Int,
    data: ByteArray?,
    val selection: Long? = null,
) {
    private val original = data?.copyOf()
    fun data(): ByteArray? = original?.copyOf()
    init {
        require(cameraIdentity.isNotBlank())
        require(slot in 201..209)
        require(data == null || data.size in 1..NikonPictureControlFile.MAX_BYTES)
        require(selection == null || selection in 1..65535)
    }
    fun matches(data: ByteArray?): Boolean =
        if (original == null) data == null else data != null && original.contentEquals(data)
}

/**
 * App-private, body-specific original-slot backup. The first backup is immutable across
 * preset replacements and reconnects; a corrupt backup must never be silently replaced.
 */
internal class PictureControlBackupStore(private val directory: File) {
    fun saveOriginal(snapshot: PictureControlSlotSnapshot): PictureControlSlotSnapshot = synchronized(lock) {
        load(snapshot.cameraIdentity, snapshot.slot)?.let { return it }
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create Picture Control backup directory")
        val target = path(snapshot.cameraIdentity, snapshot.slot)
        val encoded = encode(snapshot)
        val temporary = File.createTempFile("picture-control-", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { output ->
                output.write(encoded)
                output.fd.sync()
            }
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
            return requireNotNull(load(snapshot.cameraIdentity, snapshot.slot))
        } finally {
            temporary.delete()
        }
    }

    fun load(identity: String, slot: Int): PictureControlSlotSnapshot? = synchronized(lock) {
        val file = path(identity, slot)
        if (!file.exists()) return null
        require(file.length() in 1..(NikonPictureControlFile.MAX_BYTES + 2048).toLong()) {
            "Invalid Picture Control backup size"
        }
        val encoded = file.readBytes()
        val stream = DataInputStream(ByteArrayInputStream(encoded))
        require(stream.readInt() == MAGIC) { "Invalid Picture Control backup header" }
        val version = stream.readInt()
        require(version in 1..2) { "Invalid Picture Control backup version" }
        val savedIdentity = stream.readUTF()
        val savedSlot = stream.readInt()
        require(savedIdentity == identity && savedSlot == slot) { "Picture Control backup belongs to another camera or slot" }
        val selection = if (version == 2) stream.readLong().takeUnless { it == -1L } else null
        val length = stream.readInt()
        require(length in -1..NikonPictureControlFile.MAX_BYTES && length != 0)
        val expectedDigest = stream.readUTF()
        val data = if (length == -1) null else ByteArray(length).also(stream::readFully)
        val actualDigest = if (version == 1) pictureControlDigest(data ?: byteArrayOf()) else snapshotDigest(data, selection)
        require(stream.available() == 0 && actualDigest == expectedDigest) {
            "Picture Control backup integrity check failed"
        }
        return PictureControlSlotSnapshot(savedIdentity, savedSlot, data, selection)
    }

    private fun path(identity: String, slot: Int): File {
        require(identity.isNotBlank() && slot in 201..209)
        return File(directory, "${pictureControlDigest(identity.toByteArray(Charsets.UTF_8))}-$slot.pcb")
    }

    private fun encode(snapshot: PictureControlSlotSnapshot): ByteArray {
        val data = snapshot.data()
        return ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(MAGIC)
                output.writeInt(2)
                output.writeUTF(snapshot.cameraIdentity)
                output.writeInt(snapshot.slot)
                output.writeLong(snapshot.selection ?: -1)
                output.writeInt(data?.size ?: -1)
                output.writeUTF(snapshotDigest(data, snapshot.selection))
                if (data != null) output.write(data)
            }
        }.toByteArray()
    }

    private companion object {
        const val MAGIC = 0x5A545043
        // The app uses one process; separate store instances share the immutable-backup lock.
        val lock = Any()
        fun snapshotDigest(data: ByteArray?, selection: Long?): String = pictureControlDigest(
            java.nio.ByteBuffer.allocate(8 + (data?.size ?: 0)).putLong(selection ?: -1)
                .put(data ?: byteArrayOf()).array())
    }
}
