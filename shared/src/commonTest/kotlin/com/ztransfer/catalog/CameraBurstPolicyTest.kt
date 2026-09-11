package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CameraBurstPolicyTest {
    @Test
    fun detectsOnlyRunsWithAtLeastThreeConsecutiveFrames() {
        val files = listOf(
            file(100, 0),
            file(101, 1),
            file(102, 2),
            file(110, 3),
            file(111, 4),
        )

        assertEquals(
            listOf(100, 101, 102),
            detectCameraBurstGroups(files).single().files.map(File::number),
        )
    }

    @Test
    fun separatesRawAndJpegTracksInFirstExtensionOrder() {
        val files = buildList {
            (200..202).forEachIndexed { index, number ->
                add(file(number, index, "NEF"))
                add(file(number, index, "JPG"))
            }
        }

        val groups = detectCameraBurstGroups(files)

        assertEquals(listOf(".nef", ".jpg"), groups.map { it.files.first().extension })
        assertTrue(groups.all { it.files.size == 3 })
    }

    @Test
    fun collectionIdStaysStableWhenANewerFrameExtendsTheRun() {
        val initial = (300..302).mapIndexed { index, number -> file(number, index) }
        val extended = initial + file(303, 3)

        val initialGroup = detectCameraBurstGroups(initial).single()
        val extendedGroup = detectCameraBurstGroups(extended).single()

        assertEquals(".jpg_20260724_300_3001", initialGroup.id)
        assertEquals(initialGroup.id, extendedGroup.id)
        assertEquals(4, extendedGroup.files.size)
    }

    @Test
    fun backwardsTimeAndTwoSecondGapBothBreakRuns() {
        assertTrue(
            detectCameraBurstGroups(
                listOf(file(400, 5), file(401, 4), file(402, 5)),
            ).isEmpty(),
        )
        assertTrue(
            detectCameraBurstGroups(
                listOf(file(410, 0), file(411, 2), file(412, 3)),
            ).isEmpty(),
        )
        assertEquals(
            3,
            detectCameraBurstGroups(
                listOf(file(420, 0), file(421, 0), file(422, 1)),
            ).single().files.size,
        )
    }

    @Test
    fun unorderedInputIsSortedByDateAndTrailingNumber() {
        val files = listOf(file(502, 2), file(500, 0), file(501, 1))

        assertEquals(
            listOf(500, 501, 502),
            detectCameraBurstGroups(files).single().files.map(File::number),
        )
    }

    @Test
    fun crossDayAndFileNumberRolloverRemainSeparate() {
        assertTrue(
            detectCameraBurstGroups(
                listOf(
                    file(998, 58, day = "20260724"),
                    file(999, 59, day = "20260724"),
                    file(1000, 0, day = "20260725"),
                ),
            ).isEmpty(),
        )
        assertTrue(
            detectCameraBurstGroups(
                listOf(file(9998, 0), file(9999, 1), file(0, 2)),
            ).isEmpty(),
        )
    }

    @Test
    fun legacyParserStillIgnoresMalformedInputsWithoutTighteningTimeFields() {
        val malformed = listOf(
            file(600, 0, captureDateOverride = null),
            file(601, 1, captureDateOverride = "20260724T1200"),
            file(602, 2, captureDateOverride = "20260724T12AA02"),
            file(603, 3, fileNameOverride = "NO_NUMBER.JPG"),
            file(604, 4, fileNameOverride = "1234567890.JPG"),
        )
        assertTrue(detectCameraBurstGroups(malformed).isEmpty())

        val permissive = listOf(
            file(700, 0, captureDateOverride = "not-a-dax990000-extra"),
            file(701, 0, captureDateOverride = "not-a-dax990000-extra"),
            file(702, 1, captureDateOverride = "not-a-dax990001-extra"),
        )
        assertEquals(3, detectCameraBurstGroups(permissive).single().files.size)
    }

    private data class File(
        val number: Int,
        override val handle: Int,
        override val fileName: String,
        override val captureDate: String?,
        override val extension: String,
        override val isProtected: Boolean = false,
        override val storageIds: Set<Int> = emptySet(),
    ) : CameraCatalogFile

    private fun file(
        number: Int,
        second: Int,
        extension: String = "JPG",
        day: String = "20260724",
        fileNameOverride: String? = null,
        captureDateOverride: String? = "${day}T1200${second.toString().padStart(2, '0')}",
    ): File = File(
        number = number,
        handle = number * 10 + if (extension == "NEF") 2 else 1,
        fileName = fileNameOverride ?: "DSC_${number.toString().padStart(4, '0')}.$extension",
        captureDate = captureDateOverride,
        extension = cameraFileExtension(fileNameOverride ?: "x.$extension"),
    )
}
