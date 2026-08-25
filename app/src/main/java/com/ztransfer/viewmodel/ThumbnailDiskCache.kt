package com.ztransfer.viewmodel

import java.io.File
import java.security.MessageDigest

internal const val THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS = 90L * 24 * 60 * 60 * 1_000
private val LEGACY_FILE_NAME_UNSAFE_CHARS = Regex("[^A-Za-z0-9._-]")
private val SHA_256 = object : ThreadLocal<MessageDigest>() {
    override fun initialValue(): MessageDigest = MessageDigest.getInstance("SHA-256")
}
private val HEX_DIGITS = "0123456789abcdef".toCharArray()

private fun thumbnailCameraDirectoryName(cameraIdentity: String): String =
    "camera_${sha256(cameraIdentity)}"

internal fun thumbnailCacheFileName(
    fileName: String,
    size: Long,
    captureDate: String?,
): String = sha256("$fileName\u0000$size\u0000${captureDate.orEmpty()}") + ".jpg"

/** STA metadata is discovered progressively, so its cache identity must not change with names/dates. */
internal fun staThumbnailCacheFileName(handle: Int, size: Long): String =
    sha256("sta\u0000${handle.toLong() and 0xFFFFFFFFL}\u0000$size") + ".jpg"

internal fun legacyThumbnailCacheFileName(
    fileName: String,
    size: Long,
    captureDate: String?,
): String = "${fileName}_${size}_${captureDate ?: "0"}"
    .replace(LEGACY_FILE_NAME_UNSAFE_CHARS, "_") + ".jpg"

private fun sha256(value: String): String {
    val digest = checkNotNull(SHA_256.get()).digest(value.toByteArray(Charsets.UTF_8))
    return CharArray(digest.size * 2).also { hex ->
        digest.forEachIndexed { index, byte ->
            val unsigned = byte.toInt() and 0xFF
            hex[index * 2] = HEX_DIGITS[unsigned ushr 4]
            hex[index * 2 + 1] = HEX_DIGITS[unsigned and 0x0F]
        }
    }.concatToString()
}

/**
 * 无容量上限的按相机缩略图缓存。根目录只保存相机子目录和旧版扁平缓存；每次启动仅
 * 删除超过 90 天未连接的相机目录，当前图库内容同步由 [CameraCache.reconcile] 完成。
 */
internal class ThumbnailDiskCache(
    private val rootDirectory: File,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val rootLock = Any()
    private val cameraCaches = HashMap<String, CameraCache>()

    data class CleanupResult(
        val expiredCameraDirectories: Int,
        val staleTemporaryFiles: Int,
        val expiredLegacyFiles: Int,
    )

    fun openCamera(cameraIdentity: String): CameraCache = synchronized(rootLock) {
        val directoryName = thumbnailCameraDirectoryName(cameraIdentity)
        val directory = File(rootDirectory, directoryName)
        val directoryAlreadyExisted = directory.isDirectory
        directory.mkdirs()
        val now = nowMs()
        val marker = File(directory, LAST_CONNECTED_FILE)
        // 即使磁盘满到无法重写 marker，目录/现有 marker 的 mtime 仍尽量记录本次成功连接。
        runCatching { marker.writeText(now.toString()) }
        runCatching { marker.setLastModified(now) }
        // 创建/重写 marker 会同步改变父目录 mtime，因此最后再校准目录时间。
        runCatching { directory.setLastModified(now) }
        val existingCache = cameraCaches[directoryName]
        if (existingCache == null) {
            CameraCache(rootDirectory, directory).also { cameraCaches[directoryName] = it }
        } else {
            // 系统设置可在不杀进程的情况下清空 cacheDir；同一机身再次打开时不能保留
            // 旧 CameraCache 对象中的内存索引。
            if (!directoryAlreadyExisted) existingCache.resetIndexAfterDirectoryRecreated()
            existingCache
        }
    }

    fun cleanupExpiredCameraCaches(): CleanupResult = synchronized(rootLock) {
        rootDirectory.mkdirs()
        val cutoff = nowMs() - THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS
        var expiredDirectories = 0
        var temporaryFiles = 0
        var legacyFiles = 0

        rootDirectory.listFiles().orEmpty().forEach { entry ->
            when {
                entry.isDirectory && entry.name.startsWith(CAMERA_DIRECTORY_PREFIX) -> {
                    val openCache = cameraCaches[entry.name]
                    temporaryFiles += openCache?.cleanupTemporaryFiles()
                        ?: deleteTemporaryFiles(entry)
                    val lastConnected = readLastConnected(entry)
                    if (lastConnected < cutoff && deleteDirectChildDirectory(entry)) {
                        expiredDirectories++
                    }
                }

                entry.isFile && entry.name.endsWith(TEMP_FILE_SUFFIX) -> {
                    if (entry.delete()) temporaryFiles++
                }

                // 旧版本的缩略图没有相机归属；保留近期文件供当前相机命中时懒迁移，
                // 超过相同 90 天窗口后自然清理。
                entry.isFile && entry.extension.equals("jpg", ignoreCase = true) &&
                    entry.lastModified() < cutoff -> {
                    if (entry.delete()) legacyFiles++
                }
            }
        }
        CleanupResult(expiredDirectories, temporaryFiles, legacyFiles)
    }

    private fun readLastConnected(directory: File): Long {
        val marker = File(directory, LAST_CONNECTED_FILE)
        if (marker.isFile) {
            val recorded = runCatching { marker.readText().trim().toLong() }.getOrNull() ?: 0L
            // marker 内容是主记录；mtime 可在磁盘满导致内容无法改写时作为无分配兜底。
            return maxOf(recorded, marker.lastModified())
        }
        return directory.lastModified()
    }

    private fun deleteTemporaryFiles(directory: File): Int = directory.listFiles().orEmpty()
        .count { file ->
            (file.name.endsWith(TEMP_FILE_SUFFIX) || file.length() == 0L) && file.delete()
        }

    private fun deleteDirectChildDirectory(directory: File): Boolean = runCatching {
        val canonicalRoot = rootDirectory.canonicalFile
        val canonicalTarget = directory.canonicalFile
        if (canonicalTarget.parentFile != canonicalRoot ||
            !canonicalTarget.name.startsWith(CAMERA_DIRECTORY_PREFIX)
        ) {
            false
        } else {
            canonicalTarget.deleteRecursively()
        }
    }.getOrDefault(false)

    internal class CameraCache(
        private val legacyRoot: File,
        val directory: File,
    ) {
        private val lock = Any()
        private val index = HashSet<String>()

        init {
            directory.listFiles().orEmpty().forEach { file ->
                when {
                    file.name.endsWith(TEMP_FILE_SUFFIX) || file.length() == 0L -> file.delete()
                    file.isFile && file.extension.equals("jpg", ignoreCase = true) ->
                        index += file.name
                }
            }
        }

        fun targetFile(cacheFileName: String): File = File(directory, cacheFileName)

        /** 返回真实存在的缓存；旧版扁平文件命中时尽量无损迁入当前相机目录。 */
        fun findCachedFile(
            cacheFileName: String,
            legacyFileName: String,
            alternateCameraFileName: String? = null,
        ): File? =
            synchronized(lock) {
                ensureDirectoryLocked()
                val target = targetFile(cacheFileName)
                if (cacheFileName in index && target.isFile && target.length() > 0L) {
                    return@synchronized target
                }
                index.remove(cacheFileName)
                if (target.exists()) target.delete()

                // STA used to key entries by display name/date. Migrate that same-camera entry
                // to the stable handle+size key before considering the much older flat cache.
                alternateCameraFileName?.takeIf { it != cacheFileName }?.let { alternateName ->
                    val alternate = targetFile(alternateName)
                    if (alternateName in index && alternate.isFile && alternate.length() > 0L) {
                        if (alternate.renameTo(target) && target.isFile && target.length() > 0L) {
                            index.remove(alternateName)
                            index += cacheFileName
                            return@synchronized target
                        }
                        return@synchronized alternate
                    }
                    index.remove(alternateName)
                    if (alternate.exists()) alternate.delete()
                }

                val legacy = File(legacyRoot, legacyFileName)
                if (!legacy.isFile || legacy.length() <= 0L) return@synchronized null
                if (legacy.renameTo(target) && target.isFile && target.length() > 0L) {
                    index += cacheFileName
                    target
                } else {
                    // 迁移失败不影响旧缓存继续使用，也不把不存在的新文件写进索引。
                    legacy.takeIf { it.isFile && it.length() > 0L }
                }
            }

        /** 只有完整写入并原子改名成功才更新索引。磁盘满或任何 IO 失败均返回 false。 */
        fun write(cacheFileName: String, bytes: ByteArray): Boolean = synchronized(lock) {
            if (bytes.isEmpty()) return@synchronized false
            ensureDirectoryLocked()
            val target = targetFile(cacheFileName)
            if (target.isFile && target.length() > 0L) {
                index += cacheFileName
                return@synchronized true
            }
            if (target.exists()) target.delete()
            val temporary = File(directory, cacheFileName + TEMP_FILE_SUFFIX)
            try {
                temporary.delete()
                temporary.writeBytes(bytes)
                if (temporary.length() != bytes.size.toLong() || !temporary.renameTo(target) ||
                    !target.isFile || target.length() != bytes.size.toLong()
                ) {
                    temporary.delete()
                    target.delete()
                    index.remove(cacheFileName)
                    false
                } else {
                    index += cacheFileName
                    true
                }
            } catch (_: Exception) {
                temporary.delete()
                index.remove(cacheFileName)
                false
            }
        }

        fun remove(cacheFileName: String, actualFile: File? = null): Boolean = synchronized(lock) {
            index.remove(cacheFileName)
            val target = actualFile ?: targetFile(cacheFileName)
            runCatching {
                val canonicalTarget = target.canonicalFile
                val allowedParent = canonicalTarget.parentFile == directory.canonicalFile ||
                    canonicalTarget.parentFile == legacyRoot.canonicalFile
                allowedParent && (!canonicalTarget.exists() || canonicalTarget.delete())
            }.getOrDefault(false)
        }

        /** 完整扫描成功后调用；只删除当前相机目录内已明确不在存储卡上的缩略图。 */
        fun reconcile(validCacheFileNames: Set<String>): Int = synchronized(lock) {
            ensureDirectoryLocked()
            var removed = 0
            directory.listFiles().orEmpty().forEach { file ->
                if (file.isFile && file.extension.equals("jpg", ignoreCase = true) &&
                    file.name !in validCacheFileNames && file.delete()
                ) {
                    index.remove(file.name)
                    removed++
                }
            }
            removed
        }

        internal fun cachedNames(): Set<String> = synchronized(lock) { index.toSet() }

        internal fun cleanupTemporaryFiles(): Int = synchronized(lock) {
            directory.listFiles().orEmpty().count { file ->
                (file.name.endsWith(TEMP_FILE_SUFFIX) || file.length() == 0L) && file.delete()
            }
        }

        internal fun resetIndexAfterDirectoryRecreated() = synchronized(lock) {
            index.clear()
            directory.listFiles().orEmpty().forEach { file ->
                if (file.isFile && file.extension.equals("jpg", ignoreCase = true) &&
                    file.length() > 0L
                ) {
                    index += file.name
                }
            }
        }

        private fun ensureDirectoryLocked() {
            if (!directory.isDirectory) {
                index.clear()
                directory.mkdirs()
            }
        }
    }

    private companion object {
        const val CAMERA_DIRECTORY_PREFIX = "camera_"
        const val LAST_CONNECTED_FILE = ".last_connected"
        const val TEMP_FILE_SUFFIX = ".tmp"
    }
}
