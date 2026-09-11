package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RemoteExposurePolicyTest {
    @Test
    fun exposureGridOrderAndLabelsStayStable() {
        assertEquals(
            listOf(
                Lab.PROP_EXP_COMPENSATION,
                Lab.PROP_ISO,
                Lab.PROP_F_NUMBER,
                Lab.PROP_NK_SHUTTER,
            ),
            rcExposureProps(movieMode = false),
        )
        assertEquals(
            listOf(
                Lab.PROP_NK_MOVIE_EXP_COMP,
                Lab.PROP_NK_MOVIE_ISO,
                Lab.PROP_NK_MOVIE_F_NUMBER,
                Lab.PROP_NK_MOVIE_SHUTTER,
            ),
            rcExposureProps(movieMode = true),
        )
        assertEquals(rcExposureProps(false) + rcExposureProps(true), rcAllExposureProps())
        assertEquals("EV", rcParamLabel(Lab.PROP_EXP_COMPENSATION))
        assertEquals("ISO", rcParamLabel(Lab.PROP_NK_MOVIE_ISO))
        assertEquals("f", rcParamLabel(Lab.PROP_F_NUMBER))
        assertEquals("S", rcParamLabel(Lab.PROP_NK_MOVIE_SHUTTER))
        assertEquals("", rcParamLabel(Lab.PROP_EXPOSURE_PROGRAM))
    }

    @Test
    fun descriptorConversionPreservesRequestedPropertyAndCameraEnumOrder() {
        val descriptor = descriptor(
            propertyCode = 0xD033,
            formFlag = 2,
            enumValues = listOf(400L, 100L, 400L),
        )

        assertEquals(
            RcParam(
                prop = Lab.PROP_NK_HI_RES_ZOOM,
                dataType = 0x0006,
                writable = true,
                current = 400L,
                values = listOf(400L, 100L, 400L),
            ),
            rcParamFromDescriptor(Lab.PROP_NK_HI_RES_ZOOM, descriptor),
        )
    }

    @Test
    fun descriptorConversionExpandsOnlyTheStrictBinaryRange() {
        assertEquals(
            listOf(0L, 1L),
            rcParamFromDescriptor(
                Lab.PROP_NK_AUTO_ISO,
                descriptor(formFlag = 1, rangeMin = 0L, rangeMax = 1L, rangeStep = 1L),
            ).values,
        )
        assertTrue(
            rcParamFromDescriptor(
                Lab.PROP_NK_AUTO_ISO,
                descriptor(formFlag = 1, rangeMin = 0L, rangeMax = 2L, rangeStep = 1L),
            ).values.isEmpty(),
        )
        assertTrue(
            rcParamFromDescriptor(
                Lab.PROP_NK_AUTO_ISO,
                descriptor(formFlag = 1, rangeMin = 0L, rangeMax = 1L, rangeStep = 2L),
            ).values.isEmpty(),
        )
        assertTrue(rcParamFromDescriptor(1, descriptor(formFlag = 0)).values.isEmpty())
    }

    @Test
    fun detailedPresentationCoversApertureAndEveryShutterEncoding() {
        assertDecimal(rcDetailedValuePresentation(Lab.PROP_F_NUMBER, 280L), 2.8, 1, prefix = "f/")
        assertDecimal(
            rcDetailedValuePresentation(Lab.PROP_NK_MOVIE_F_NUMBER, 560L),
            5.6,
            1,
            prefix = "f/",
        )
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, 0xFFFFFFFFL), "Bulb")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, 0xFFFFFFFEL), "x200")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, 0xFFFFFFFDL), "Time")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, packed(1, 250)), "1/250s")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, packed(300, 10)), "30s")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, packed(2, 500)), "1/250s")
        assertDecimal(
            rcDetailedValuePresentation(Lab.PROP_NK_MOVIE_SHUTTER, packed(13, 10)),
            1.3,
            1,
            suffix = "s",
        )
        assertText(
            rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, packed(0, 250)),
            packed(0, 250).toString(),
        )
        assertText(
            rcDetailedValuePresentation(Lab.PROP_NK_SHUTTER, packed(1, 0)),
            packed(1, 0).toString(),
        )
        assertDecimal(
            rcDetailedValuePresentation(Lab.PROP_EXPOSURE_TIME_STD, 1250L),
            0.125,
            4,
            suffix = "s",
        )
    }

    @Test
    fun compactPresentationOmitsOnlyTheUnitsAlreadyPrintedByTiles() {
        listOf(
            Lab.PROP_ISO,
            Lab.PROP_NK_ISO_EX,
            Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
            Lab.PROP_NK_MOVIE_ISO,
        ).forEach { prop -> assertText(rcCompactValuePresentation(prop, 640L), "640") }
        listOf(
            Lab.PROP_EXP_COMPENSATION to 667L,
            Lab.PROP_NK_EXP_COMPENSATION to -1333L,
            Lab.PROP_NK_MOVIE_EXP_COMP to 0L,
        ).forEach { (prop, raw) ->
            assertDecimal(
                rcCompactValuePresentation(prop, raw),
                raw / 1000.0,
                fractionDigits = 1,
                alwaysShowSign = true,
            )
        }
        assertDecimal(
            rcDetailedValuePresentation(Lab.PROP_EXP_COMPENSATION, 667L),
            0.667,
            1,
            alwaysShowSign = true,
            suffix = "EV",
        )
    }

    @Test
    fun programAutoIsoAndFocusLabelsPreserveKnownAndRawValues() {
        val programs = mapOf(1L to "M", 2L to "P", 3L to "A", 4L to "S", 0x8010L to "AUTO")
        programs.forEach { (raw, label) ->
            assertText(rcDetailedValuePresentation(Lab.PROP_EXPOSURE_PROGRAM, raw), label)
        }
        assertText(rcDetailedValuePresentation(Lab.PROP_EXPOSURE_PROGRAM, 0x80AFL), "0x80af")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_AUTO_ISO, 0L), "Off")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_AUTO_ISO_ALT, 2L), "On")
        assertText(rcDetailedValuePresentation(Lab.PROP_FOCUS_MODE, 1L), "MF")
        assertText(rcDetailedValuePresentation(Lab.PROP_FOCUS_MODE, 0x8013L), "AF-F")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_AF_MODE, 2L), "AF-A")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_AF_MODE, 4L), "0x4")
        assertText(rcDetailedValuePresentation(Lab.PROP_ISO, 640L), "ISO640")
        assertText(rcDetailedValuePresentation(Lab.PROP_NK_MOVIE_AUTO_ISO, 1L), "1")
        assertText(rcDetailedValuePresentation(0x1234, 567L), "567")
        assertDecimal(
            rcDetailedValuePresentation(Lab.PROP_NK_ANGLE_LEVEL, 23_514_322L),
            23_514_322L / 65_536.0,
            1,
            suffix = "°",
        )
    }

    @Test
    fun canonicalAndCompatiblePropertyOrdersRemainCameraGenerationCompatible() {
        assertEquals(Lab.PROP_EXP_COMPENSATION, rcCanonicalExposureProp(Lab.PROP_NK_EXP_COMPENSATION))
        assertEquals(Lab.PROP_ISO, rcCanonicalExposureProp(Lab.PROP_NK_ISO_EX))
        assertEquals(Lab.PROP_NK_SHUTTER, rcCanonicalExposureProp(Lab.PROP_EXPOSURE_TIME_STD))
        assertEquals(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY, rcCanonicalExposureProp(Lab.PROP_NK_ISO_CONTROL_SENSITIVITY))
        assertEquals(
            listOf(Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION),
            rcCompatibleExposureProps(Lab.PROP_EXP_COMPENSATION).toList(),
        )
        assertEquals(
            listOf(Lab.PROP_ISO, Lab.PROP_NK_ISO_EX),
            rcCompatibleExposureProps(Lab.PROP_ISO).toList(),
        )
        assertEquals(
            listOf(Lab.PROP_NK_SHUTTER, Lab.PROP_EXPOSURE_TIME_STD),
            rcCompatibleExposureProps(Lab.PROP_NK_SHUTTER).toList(),
        )
        assertEquals(listOf(123), rcCompatibleExposureProps(123).toList())
    }

    @Test
    fun autoIsoProbeToggleAndTargetRulesRemainPermissiveOnlyWhereExpected() {
        assertEquals(
            listOf(
                Lab.PROP_NK_MOVIE_AUTO_ISO,
                Lab.PROP_NK_AUTO_ISO_ALT,
                Lab.PROP_NK_AUTO_ISO,
            ),
            rcAutoIsoCandidateProps(movieMode = true),
        )
        assertEquals(
            listOf(Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT),
            rcAutoIsoCandidateProps(movieMode = false),
        )
        assertTrue(param(values = listOf(0L, 2L)).rcIsBinaryToggle())
        assertTrue(param(values = listOf(1L, 0L)).rcIsBinaryToggle())
        assertTrue(param(values = emptyList(), current = 0L, dataType = 0x0001).rcIsBinaryToggle())
        assertTrue(param(values = emptyList(), current = 1L, dataType = 0x0002).rcIsBinaryToggle())
        assertFalse(param(writable = false, values = listOf(0L, 1L)).rcIsBinaryToggle())
        assertFalse(param(values = listOf(0L)).rcIsBinaryToggle())
        assertFalse(param(values = listOf(1L)).rcIsBinaryToggle())
        assertFalse(param(values = emptyList(), current = 1L, dataType = 0x0004).rcIsBinaryToggle())
        assertFalse(param(values = emptyList(), current = 2L).rcIsBinaryToggle())
        assertEquals(2L, rcAutoIsoTarget(param(values = listOf(0L, 2L, 1L)), enabled = true))
        assertEquals(0L, rcAutoIsoTarget(param(values = listOf(1L, 0L)), enabled = false))
        assertEquals(1L, rcAutoIsoTarget(param(values = emptyList()), enabled = true))
        assertEquals(0L, rcAutoIsoTarget(param(values = emptyList()), enabled = false))
        assertEquals(1L, rcAutoIsoTarget(param(values = listOf(0L, 0L)), enabled = true))
        assertEquals(0L, rcAutoIsoTarget(param(values = listOf(2L, 1L)), enabled = false))
    }

    @Test
    fun wheelMetricDirectionAndAnchorPreservePhysicalOrdering() {
        assertEquals(250.0, rcParameterMetric(Lab.PROP_NK_SHUTTER, packed(1, 250)))
        assertEquals(0.0, rcParameterMetric(Lab.PROP_NK_SHUTTER, 0xFFFFFFFFL))
        assertEquals(0.0, rcParameterMetric(Lab.PROP_NK_SHUTTER, packed(0, 250)))
        assertEquals(-280.0, rcParameterMetric(Lab.PROP_F_NUMBER, 280L))
        assertEquals(640.0, rcParameterMetric(Lab.PROP_ISO, 640L))
        assertEquals(667.0, rcParameterMetric(Lab.PROP_EXP_COMPENSATION, 667L))

        assertEquals(1, rcDownStepSign(param(prop = Lab.PROP_ISO, values = listOf(100L, 200L))))
        assertEquals(-1, rcDownStepSign(param(prop = Lab.PROP_ISO, values = listOf(200L, 100L))))
        assertEquals(-1, rcDownStepSign(param(values = listOf(100L))))
        assertEquals(-1, rcDownStepSign(param(values = emptyList())))
        assertEquals(-1, rcDownStepSign(param(prop = Lab.PROP_NK_SHUTTER, values = listOf(0xFFFFFFFFL, 0xFFFFFFFDL))))

        assertEquals(0, rcParamAnchorIndex(Lab.PROP_ISO, listOf(200L, 200L), 200L))
        assertEquals(-1, rcParamAnchorIndex(Lab.PROP_ISO, emptyList(), 200L))
        assertEquals(1, rcParamAnchorIndex(Lab.PROP_ISO, listOf(100L, 200L, 400L), 260L))
        assertEquals(0, rcParamAnchorIndex(Lab.PROP_ISO, listOf(100L, 300L), 200L))
    }

    @Test
    fun steppedValueClampsAndStillSnapsANonEnumCurrentValue() {
        val adjustable = param(prop = Lab.PROP_ISO, current = 200L, values = listOf(100L, 200L, 400L))
        assertEquals(400L, rcSteppedValue(Lab.PROP_ISO, adjustable, delta = 99))
        assertEquals(100L, rcSteppedValue(Lab.PROP_ISO, adjustable, delta = -99))
        assertNull(rcSteppedValue(Lab.PROP_ISO, adjustable.copy(current = 100L), delta = -1))
        assertEquals(
            200L,
            rcSteppedValue(Lab.PROP_ISO, adjustable.copy(current = 260L), delta = 0),
        )
        assertNull(rcSteppedValue(Lab.PROP_ISO, adjustable.copy(writable = false), delta = 1))
        assertNull(rcSteppedValue(Lab.PROP_ISO, adjustable.copy(values = emptyList()), delta = 1))

        val standardShutter = adjustable.copy(
            prop = Lab.PROP_EXPOSURE_TIME_STD,
            current = packed(1, 180),
            values = listOf(packed(1, 125), packed(1, 250)),
        )
        assertEquals(
            packed(1, 250),
            rcSteppedValue(Lab.PROP_NK_SHUTTER, standardShutter, delta = 1),
        )
    }

    @Test
    fun batteryAndAngleRulesMoveWithTheSharedParameterModel() {
        assertEquals(0, rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 0L)))
        assertEquals(67, rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 67L)))
        assertEquals(100, rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 100L)))
        assertNull(rcBatteryPercentage(null))
        assertNull(rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = -1L)))
        assertNull(rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 101L)))
        assertNull(rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 0xFFL)))
        assertNull(rcBatteryPercentage(param(prop = Lab.PROP_BATTERY_LEVEL, current = 50L, dataType = 0x0001)))
        assertNull(rcBatteryPercentage(param(prop = Lab.PROP_ISO, current = 50L)))

        assertTrue(
            kotlin.math.abs(
                rcAngleLevelRoll(param(current = 23_514_322L, dataType = 0x0005))!! + 1.2f,
            ) < 0.01f,
        )
        assertEquals(180f, rcAngleLevelRoll(param(current = 180L, dataType = 0x0003)))
        assertEquals(-179f, rcAngleLevelRoll(param(current = 181L, dataType = 0x0003)))
        assertEquals(180f, rcAngleLevelRoll(param(current = -180L, dataType = 0x0003)))
        assertNull(rcAngleLevelRoll(param(current = 0L, dataType = 0x0008)))
    }

    private fun packed(numerator: Long, denominator: Long): Long =
        (numerator shl 16) or denominator

    private fun param(
        prop: Int = Lab.PROP_NK_AUTO_ISO_ALT,
        dataType: Int = 0x0002,
        writable: Boolean = true,
        current: Long = 0L,
        values: List<Long> = emptyList(),
    ) = RcParam(prop, dataType, writable, current, values)

    private fun descriptor(
        propertyCode: Int = Lab.PROP_NK_AUTO_ISO,
        dataType: Int = 0x0006,
        writable: Boolean = true,
        current: Long = 400L,
        formFlag: Int,
        rangeMin: Long? = null,
        rangeMax: Long? = null,
        rangeStep: Long? = null,
        enumValues: List<Long> = emptyList(),
    ) = PtpDevicePropDescriptor(
        propertyCode = propertyCode,
        dataType = dataType,
        writable = writable,
        defaultValue = current,
        defaultIsScalar = true,
        current = current,
        currentIsScalar = true,
        formFlag = formFlag,
        rangeMin = rangeMin,
        rangeMax = rangeMax,
        rangeStep = rangeStep,
        enumValues = enumValues,
    )

    private fun assertText(presentation: RcValuePresentation, expected: String) {
        assertEquals(RcValuePresentation.Text(expected), presentation)
    }

    private fun assertDecimal(
        presentation: RcValuePresentation,
        value: Double,
        fractionDigits: Int,
        alwaysShowSign: Boolean = false,
        prefix: String = "",
        suffix: String = "",
    ) {
        assertEquals(
            RcValuePresentation.Decimal(
                value = value,
                fractionDigits = fractionDigits,
                alwaysShowSign = alwaysShowSign,
                prefix = prefix,
                suffix = suffix,
            ),
            presentation,
        )
    }
}
