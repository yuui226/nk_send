package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class CameraFilePublicationPolicyTest {
    @Test
    fun automaticTransferAcceptsKnownPhotosAndVideosButNotUnknownObjects() {
        fun namedFile(name: String) = file(handle = 1, name = name, capturedAt = null)

        assertTrue(isAutoTransferMedia(namedFile("DSC_0001.JPG")))
        assertTrue(isAutoTransferMedia(namedFile("DSC_0002.NEF")))
        assertTrue(isAutoTransferMedia(namedFile("DSC_0003.MOV")))
        assertTrue(isAutoTransferMedia(namedFile("DSC_0004.AVI")))
        assertFalse(isAutoTransferMedia(namedFile("OBJECT.BIN")))
    }

    @Test
    fun latestStillWinsAndNewerVideoIsIgnored() {
        val olderJpeg = file(10, "DSC_0010.JPG", "20260805T100000")
        val latestJpeg = file(11, "DSC_0011.NEF", "20260805T110000")
        val newerVideo = file(12, "DSC_0012.MOV", "20260805T120000")

        assertEquals(latestJpeg, latestEffectPreviewFile(listOf(olderJpeg, newerVideo, latestJpeg)))
    }

    @Test
    fun handleBreaksPreviewTiesWhenCaptureDatesAreAbsent() {
        val lower = file(30, "DSC_0030.JPG", null)
        val higher = file(31, "DSC_0031.JPG", null)

        assertEquals(higher, latestEffectPreviewFile(listOf(higher, lower)))
    }

    @Test
    fun cacheAndPreviewKeysPreserveTheirOriginalIdentityScopes() {
        val first = file(30, "DSC_0030.JPG", "20260805T100000")
        val sameFileNewHandle = first.copy(handle = 31)

        assertEquals("DSC_0030.JPG_1024_20260805T100000", exifKey(first))
        assertEquals(exifKey(first), exifKey(sameFileNewHandle))
        assertEquals("30|DSC_0030.JPG|1024|20260805T100000", effectPreviewKey(first))
        assertFalse(effectPreviewKey(first) == effectPreviewKey(sameFileNewHandle))
    }

    @Test
    fun olderFileBatchesDoNotReplaceTheFirstNewestPreviewCandidate() {
        val newest = file(50, "DSC_0050.JPG", "20260805T150000")
        val older = file(49, "DSC_0049.JPG", "20260805T140000")

        assertEquals(newest, latestEffectPreviewFile(listOf(newest)))
        assertEquals(newest, latestEffectPreviewFile(listOf(newest, older)))
    }

    @Test
    fun backupDuplicateKeepsMembershipOfBothCardsAndStablePrimary() {
        val card1 = file(handle = 1, storageId = 0x00010001)
        val card2 = file(handle = 2, storageId = 0x00020001)
        val merged = mergeStorageMembership(card1, card2)

        assertEquals(setOf(0x00010001, 0x00020001), merged.storageIds)
        assertEquals(card1.handle, merged.handle)
        assertSame(merged, mergeStorageMembership(merged, card2))
    }

    @Test
    fun catalogReconciliationSwitchesDeletedBackupPrimaryToSurvivingAlias() {
        val card1 = file(handle = 10, storageId = 0x00010001)
        val card2 = card1.copy(handle = 20, storageIds = setOf(0x00020001))
        val published = mergeStorageMembership(card1, card2)

        assertEquals(
            listOf(card2),
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = setOf(20),
                indexedFilesByHandle = mapOf(20 to card2),
            ),
        )
        assertEquals(
            listOf(card1),
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = setOf(10),
                indexedFilesByHandle = mapOf(10 to card1),
            ),
        )
        assertTrue(
            reconcilePublishedCameraFiles(
                publishedFiles = listOf(published),
                currentHandles = emptySet(),
                indexedFilesByHandle = emptyMap(),
            ).isEmpty(),
        )
    }

    @Test
    fun photoExifRemainsACompleteNullableValueSnapshot() {
        val exif = PhotoExif(
            aperture = "f/2.8",
            shutterSpeed = "1/250",
            iso = "400",
            focalLength = "50mm",
            latitude = 31.2304,
            longitude = 121.4737,
        )

        assertEquals("f/2.8", exif.aperture)
        assertEquals(31.2304, exif.latitude)
        assertEquals(null, exif.address)
    }

    @Test
    fun exposureCompensationKeepsThresholdAndExplicitPositiveSign() {
        val formatter: (Float) -> String = { value ->
            ((value * 10f).toInt() / 10f).toString()
        }
        assertEquals(null, exposureCompensationText(null, formatter))
        assertEquals(null, exposureCompensationText(Float.NaN, formatter))
        assertEquals(null, exposureCompensationText(0.049f, formatter))
        assertEquals("+0.7 EV", exposureCompensationText(0.7f, formatter))
        assertEquals("-1.3 EV", exposureCompensationText(-1.3f, formatter))
    }

    private fun file(
        handle: Int,
        name: String = "DSC_0001.JPG",
        capturedAt: String? = "20260806T120000",
        storageId: Int? = null,
    ) = CameraFileInfo(
        handle = handle,
        size = 1_024L,
        fileName = name,
        captureDate = capturedAt,
        storageIds = storageId?.let(::setOf).orEmpty(),
    )
}
