package com.ztransfer.viewmodel

import com.ztransfer.catalog.THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailDiskCacheTest {
    private val temporaryRoots = mutableListOf<File>()

    @After
    fun cleanUp() {
        temporaryRoots.forEach(File::deleteRecursively)
    }

    @Test
    fun `different cameras use isolated directories`() {
        val root = newRoot()
        val cache = ThumbnailDiskCache(root) { 1_000L }

        val first = cache.openCamera("nikon-z6iii-serial-a")
        val second = cache.openCamera("nikon-z6iii-serial-b")

        assertNotEquals(first.directory, second.directory)
        assertTrue(first.write("same-photo.jpg", jpegBytes(1)))
        assertNull(second.findCachedFile("same-photo.jpg", "missing-legacy.jpg"))
    }

    @Test
    fun `startup removes only cameras idle for more than ninety days`() {
        var now = 1_700_000_000_000L
        val root = newRoot()
        val cache = ThumbnailDiskCache(root) { now }
        val expired = cache.openCamera("expired-camera")
        assertTrue(expired.write("old.jpg", jpegBytes(1)))

        now += THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS + 1
        val recent = cache.openCamera("recent-camera")
        assertTrue(recent.write("new.jpg", jpegBytes(2)))

        val result = cache.cleanupExpiredCameraCaches()

        assertEquals(1, result.expiredCameraDirectories)
        assertFalse(expired.directory.exists())
        assertTrue(recent.directory.isDirectory)
    }

    @Test
    fun `camera connected exactly ninety days ago is retained`() {
        var now = 1_700_000_000_000L
        val root = newRoot()
        val cache = ThumbnailDiskCache(root) { now }
        val camera = cache.openCamera("boundary-camera")

        now += THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS
        val result = cache.cleanupExpiredCameraCaches()

        assertEquals(0, result.expiredCameraDirectories)
        assertTrue(camera.directory.isDirectory)
    }

    @Test
    fun `successful reconnect refreshes camera retention time`() {
        var now = 1_700_000_000_000L
        val root = newRoot()
        val cache = ThumbnailDiskCache(root) { now }
        val firstOpen = cache.openCamera("returning-camera")
        assertTrue(firstOpen.write("keep.jpg", jpegBytes(1)))

        now += THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS - 1
        val secondOpen = cache.openCamera("returning-camera")
        now += THUMBNAIL_CAMERA_CACHE_MAX_IDLE_MS - 1
        val result = cache.cleanupExpiredCameraCaches()

        assertTrue(firstOpen === secondOpen)
        assertEquals(0, result.expiredCameraDirectories)
        assertTrue(secondOpen.targetFile("keep.jpg").isFile)
    }

    @Test
    fun `successful catalog reconciliation removes only absent photos`() {
        val root = newRoot()
        val camera = ThumbnailDiskCache(root).openCamera("current-camera")
        assertTrue(camera.write("keep.jpg", jpegBytes(1)))
        assertTrue(camera.write("deleted-on-camera.jpg", jpegBytes(2)))

        val removed = camera.reconcile(setOf("keep.jpg"))

        assertEquals(1, removed)
        assertEquals(setOf("keep.jpg"), camera.cachedNames())
        assertTrue(camera.targetFile("keep.jpg").isFile)
        assertFalse(camera.targetFile("deleted-on-camera.jpg").exists())
    }

    @Test
    fun `legacy flat cache is moved into the connected camera directory`() {
        val root = newRoot()
        val legacyName = "legacy-photo.jpg"
        val legacy = File(root, legacyName).apply {
            parentFile?.mkdirs()
            writeBytes(jpegBytes(3))
        }
        val camera = ThumbnailDiskCache(root).openCamera("current-camera")

        val resolved = camera.findCachedFile("hashed-photo.jpg", legacyName)

        assertEquals(camera.targetFile("hashed-photo.jpg"), resolved)
        assertTrue(resolved?.isFile == true)
        assertFalse(legacy.exists())
        assertEquals(setOf("hashed-photo.jpg"), camera.cachedNames())
    }

    @Test
    fun `sta display-name cache is moved to stable object identity`() {
        val root = newRoot()
        val camera = ThumbnailDiskCache(root).openCamera("current-camera")
        val displayNameKey = thumbnailCacheFileName("DSC_8693.JPG", 123L, "20260824T204540")
        val stableKey = staThumbnailCacheFileName(0x291961F5, 123L)
        assertTrue(camera.write(displayNameKey, jpegBytes(7)))

        val resolved = camera.findCachedFile(
            stableKey,
            "missing-legacy.jpg",
            displayNameKey,
        )

        assertEquals(camera.targetFile(stableKey), resolved)
        assertTrue(resolved?.isFile == true)
        assertFalse(camera.targetFile(displayNameKey).exists())
        assertEquals(setOf(stableKey), camera.cachedNames())
    }

    @Test
    fun `failed write never creates a cached index entry`() {
        val root = newRoot()
        val camera = ThumbnailDiskCache(root).openCamera("current-camera")
        camera.directory.deleteRecursively()
        camera.directory.writeText("blocks directory recreation")

        assertFalse(camera.write("photo.jpg", jpegBytes(4)))
        assertFalse("photo.jpg" in camera.cachedNames())
        assertNull(camera.findCachedFile("photo.jpg", "missing-legacy.jpg"))
    }

    @Test
    fun `reopening after external cache clear resets the in-memory index`() {
        val root = newRoot()
        val cache = ThumbnailDiskCache(root)
        val firstOpen = cache.openCamera("current-camera")
        assertTrue(firstOpen.write("removed-by-system.jpg", jpegBytes(4)))
        firstOpen.directory.deleteRecursively()

        val secondOpen = cache.openCamera("current-camera")

        assertTrue(firstOpen === secondOpen)
        assertFalse("removed-by-system.jpg" in secondOpen.cachedNames())
        assertTrue(secondOpen.write("new.jpg", jpegBytes(5)))
    }

    @Test
    fun `startup cleanup keeps valid cached files in an open camera directory`() {
        val root = newRoot()
        val cache = ThumbnailDiskCache(root)
        val camera = cache.openCamera("current-camera")
        assertTrue(camera.write("keep.jpg", jpegBytes(6)))
        File(camera.directory, "orphan.tmp").writeBytes(byteArrayOf(1))

        val result = cache.cleanupExpiredCameraCaches()

        assertEquals(1, result.staleTemporaryFiles)
        assertTrue(camera.targetFile("keep.jpg").isFile)
        assertFalse(File(camera.directory, "orphan.tmp").exists())
    }

    @Test
    fun `photo keys are stable and do not collide after filename sanitization`() {
        val first = thumbnailCacheFileName("照片 1.JPG", 123L, "20260812T120000")
        val same = thumbnailCacheFileName("照片 1.JPG", 123L, "20260812T120000")
        val emptyDate = thumbnailCacheFileName("照片 1.JPG", 123L, "")
        val nullDate = thumbnailCacheFileName("照片 1.JPG", 123L, null)
        val different = thumbnailCacheFileName("照片-1.JPG", 123L, "20260812T120000")

        assertEquals(first, same)
        assertEquals(
            "55766806312b959f9c99f618580f66c5a12d635a9d777f6792191173da0c160e.jpg",
            first,
        )
        assertEquals(emptyDate, nullDate)
        assertNotEquals(first, different)
        assertTrue(first.matches(Regex("[0-9a-f]{64}\\.jpg")))
    }

    @Test
    fun `sta keys ignore progressive filename and date discovery`() {
        val beforeMetadata = staThumbnailCacheFileName(0x291961F5, 12_345L)
        val afterMetadata = staThumbnailCacheFileName(0x291961F5, 12_345L)
        val differentObject = staThumbnailCacheFileName(0x291961F4, 12_345L)

        assertEquals(beforeMetadata, afterMetadata)
        assertEquals(
            "f533c5ce2cb31ff9cd9a0d3a4573830eda5ae72a15affcc4ee12ce8f8b39ceda.jpg",
            beforeMetadata,
        )
        assertEquals(
            "2a1f8c3cda06810cad52b38e205d45bb845c101725ee300277c640699fd392f1.jpg",
            staThumbnailCacheFileName(-1, 12_345L),
        )
        assertNotEquals(beforeMetadata, differentObject)
        assertTrue(beforeMetadata.matches(Regex("[0-9a-f]{64}\\.jpg")))
    }

    @Test
    fun `camera directory identity remains byte compatible`() {
        val camera = ThumbnailDiskCache(newRoot()).openCamera("nikon-z6iii-serial-a")

        assertEquals(
            "camera_e8031fc6623b0f70dce48b7ed6c87367fa88bd3cbaf9faeee7c950bf7ee73957",
            camera.directory.name,
        )
    }

    private fun newRoot(): File = Files.createTempDirectory("thumbnail-cache-test").toFile()
        .also(temporaryRoots::add)

    private fun jpegBytes(marker: Int): ByteArray = byteArrayOf(
        0xFF.toByte(),
        0xD8.toByte(),
        marker.toByte(),
        0xFF.toByte(),
        0xD9.toByte(),
    )
}
