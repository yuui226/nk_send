package com.ztransfer.protocol

import kotlin.math.abs

/** Camera-reported remote parameter and its currently valid value order. */
data class RcParam(
    val prop: Int,
    val dataType: Int,
    val writable: Boolean,
    val current: Long,
    val values: List<Long>,
)

/**
 * Platform-neutral presentation rule. Android retains its default-locale `String.format`, while
 * iOS can render [Decimal] with NumberFormatter without duplicating camera-value semantics.
 */
sealed interface RcValuePresentation {
    data class Text(val value: String) : RcValuePresentation

    data class Decimal(
        val value: Double,
        val fractionDigits: Int,
        val alwaysShowSign: Boolean = false,
        val prefix: String = "",
        val suffix: String = "",
    ) : RcValuePresentation
}

private val photoExposureProps = listOf(
    Lab.PROP_EXP_COMPENSATION,
    Lab.PROP_ISO,
    Lab.PROP_F_NUMBER,
    Lab.PROP_NK_SHUTTER,
)

private val movieExposureProps = listOf(
    Lab.PROP_NK_MOVIE_EXP_COMP,
    Lab.PROP_NK_MOVIE_ISO,
    Lab.PROP_NK_MOVIE_F_NUMBER,
    Lab.PROP_NK_MOVIE_SHUTTER,
)

/** The 2x2 remote-control grid order for still or movie mode. */
fun rcExposureProps(movieMode: Boolean): List<Int> =
    if (movieMode) movieExposureProps else photoExposureProps

fun rcAllExposureProps(): List<Int> = photoExposureProps + movieExposureProps

/** Short camera-standard label used by the remote parameter tile. */
fun rcParamLabel(prop: Int): String = when (prop) {
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> "S"
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> "f"
    Lab.PROP_ISO, Lab.PROP_NK_MOVIE_ISO -> "ISO"
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP -> "EV"
    else -> ""
}

/** Converts a parsed descriptor without replacing its camera-provided enum order or duplicates. */
fun rcParamFromDescriptor(
    requestedProp: Int,
    descriptor: PtpDevicePropDescriptor,
): RcParam {
    val values = when (descriptor.formFlag) {
        1 -> if (
            descriptor.rangeMin == 0L &&
            descriptor.rangeMax == 1L &&
            descriptor.rangeStep == 1L
        ) {
            listOf(0L, 1L)
        } else {
            emptyList()
        }
        2 -> descriptor.enumValues
        else -> emptyList()
    }
    return RcParam(
        prop = requestedProp,
        dataType = descriptor.dataType,
        writable = descriptor.writable,
        current = descriptor.current,
        values = values,
    )
}

/** Detailed value used in diagnostics and focus labels. */
fun rcDetailedValuePresentation(prop: Int, raw: Long): RcValuePresentation = when (prop) {
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> RcValuePresentation.Decimal(
        value = raw / 100.0,
        fractionDigits = 1,
        prefix = "f/",
    )
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> shutterPresentation(raw)
    Lab.PROP_EXPOSURE_TIME_STD -> RcValuePresentation.Decimal(
        value = raw / 10_000.0,
        fractionDigits = 4,
        suffix = "s",
    )
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION,
    Lab.PROP_NK_MOVIE_EXP_COMP -> RcValuePresentation.Decimal(
        value = raw / 1_000.0,
        fractionDigits = 1,
        alwaysShowSign = true,
        suffix = "EV",
    )
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
    Lab.PROP_NK_MOVIE_ISO -> RcValuePresentation.Text("ISO$raw")
    Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT ->
        RcValuePresentation.Text(if (raw == 0L) "Off" else "On")
    Lab.PROP_NK_ANGLE_LEVEL -> RcValuePresentation.Decimal(
        value = raw / 65_536.0,
        fractionDigits = 1,
        suffix = "°",
    )
    Lab.PROP_EXPOSURE_PROGRAM -> RcValuePresentation.Text(
        when (raw) {
            1L -> "M"
            2L -> "P"
            3L -> "A"
            4L -> "S"
            0x8010L -> "AUTO"
            else -> "0x${raw.toString(16)}"
        },
    )
    Lab.PROP_FOCUS_MODE -> RcValuePresentation.Text(
        when (raw) {
            1L -> "MF"
            2L -> "AF"
            3L -> "AF Macro"
            0x8010L -> "AF-S"
            0x8011L -> "AF-C"
            0x8012L -> "AF-A"
            0x8013L -> "AF-F"
            else -> "0x${raw.toString(16)}"
        },
    )
    Lab.PROP_NK_AF_MODE -> RcValuePresentation.Text(
        when (raw) {
            0L -> "AF-S"
            1L -> "AF-C"
            2L -> "AF-A"
            else -> "0x${raw.toString(16)}"
        },
    )
    else -> RcValuePresentation.Text(raw.toString())
}

/** Compact tile value; ISO/EV units are already printed by the tile itself. */
fun rcCompactValuePresentation(prop: Int, raw: Long): RcValuePresentation = when (prop) {
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
    Lab.PROP_NK_MOVIE_ISO -> RcValuePresentation.Text(raw.toString())
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION,
    Lab.PROP_NK_MOVIE_EXP_COMP -> RcValuePresentation.Decimal(
        value = raw / 1_000.0,
        fractionDigits = 1,
        alwaysShowSign = true,
    )
    else -> rcDetailedValuePresentation(prop, raw)
}

private fun shutterPresentation(raw: Long): RcValuePresentation = when (raw) {
    0xFFFFFFFFL -> RcValuePresentation.Text("Bulb")
    0xFFFFFFFEL -> RcValuePresentation.Text("x200")
    0xFFFFFFFDL -> RcValuePresentation.Text("Time")
    else -> {
        val numerator = (raw ushr 16) and 0xFFFFL
        val denominator = raw and 0xFFFFL
        when {
            numerator == 0L || denominator == 0L -> RcValuePresentation.Text(raw.toString())
            numerator == 1L -> RcValuePresentation.Text("1/${denominator}s")
            numerator % denominator == 0L ->
                RcValuePresentation.Text("${numerator / denominator}s")
            denominator % numerator == 0L ->
                RcValuePresentation.Text("1/${denominator / numerator}s")
            else -> RcValuePresentation.Decimal(
                value = numerator.toDouble() / denominator,
                fractionDigits = 1,
                suffix = "s",
            )
        }
    }
}

/** Nikon generations expose Auto ISO under different properties, in this probe order. */
fun rcAutoIsoCandidateProps(movieMode: Boolean): List<Int> = if (movieMode) {
    listOf(
        Lab.PROP_NK_MOVIE_AUTO_ISO,
        Lab.PROP_NK_AUTO_ISO_ALT,
        Lab.PROP_NK_AUTO_ISO,
    )
} else {
    listOf(Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT)
}

fun RcParam.rcIsBinaryToggle(): Boolean {
    if (!writable) return false
    val hasExplicitStates = values.any { it == 0L } && values.any { it != 0L }
    val isImplicitByteToggle = values.isEmpty() &&
        dataType in setOf(0x0001, 0x0002) &&
        current in 0L..1L
    return hasExplicitStates || isImplicitByteToggle
}

fun rcAutoIsoTarget(param: RcParam, enabled: Boolean): Long = if (enabled) {
    param.values.firstOrNull { it != 0L } ?: 1L
} else {
    param.values.firstOrNull { it == 0L } ?: 0L
}

/** Maps camera-generation aliases to the logical property used as the Android/iOS state key. */
fun rcCanonicalExposureProp(prop: Int): Int = when (prop) {
    Lab.PROP_NK_EXP_COMPENSATION -> Lab.PROP_EXP_COMPENSATION
    Lab.PROP_NK_ISO_EX -> Lab.PROP_ISO
    Lab.PROP_EXPOSURE_TIME_STD -> Lab.PROP_NK_SHUTTER
    else -> prop
}

/** Probe order for the concrete property behind a logical exposure control. */
fun rcCompatibleExposureProps(logicalProp: Int): IntArray = when (logicalProp) {
    Lab.PROP_EXP_COMPENSATION ->
        intArrayOf(Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION)
    Lab.PROP_ISO -> intArrayOf(Lab.PROP_ISO, Lab.PROP_NK_ISO_EX)
    Lab.PROP_NK_SHUTTER -> intArrayOf(Lab.PROP_NK_SHUTTER, Lab.PROP_EXPOSURE_TIME_STD)
    else -> intArrayOf(logicalProp)
}

/** Parameter metric used only to infer wheel direction and find the nearest camera value. */
fun rcParameterMetric(prop: Int, raw: Long): Double = when (prop) {
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> when (raw) {
        0xFFFFFFFFL, 0xFFFFFFFEL, 0xFFFFFFFDL -> 0.0
        else -> {
            val numerator = ((raw ushr 16) and 0xFFFFL).toDouble()
            val denominator = (raw and 0xFFFFL).toDouble()
            if (numerator > 0.0) denominator / numerator else 0.0
        }
    }
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> -raw.toDouble()
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_MOVIE_ISO -> raw.toDouble()
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP -> raw.toDouble()
    else -> raw.toDouble()
}

fun rcDownStepSign(param: RcParam): Int {
    if (param.values.size < 2) return -1
    return if (
        rcParameterMetric(param.prop, param.values.last()) >
        rcParameterMetric(param.prop, param.values.first())
    ) {
        1
    } else {
        -1
    }
}

fun rcParamAnchorIndex(prop: Int, values: List<Long>, current: Long): Int {
    val exactIndex = values.indexOf(current)
    if (exactIndex >= 0) return exactIndex
    val currentMetric = rcParameterMetric(prop, current)
    return values.indices.minByOrNull { index ->
        abs(rcParameterMetric(prop, values[index]) - currentMetric)
    } ?: -1
}

/** Null means the Android/iOS caller should not send or optimistically publish a new value. */
fun rcSteppedValue(logicalProp: Int, param: RcParam, delta: Int): Long? {
    if (!param.writable || param.values.isEmpty()) return null
    val fromIndex = rcParamAnchorIndex(logicalProp, param.values, param.current)
    val newIndex = (fromIndex + delta).coerceIn(0, param.values.lastIndex)
    if (newIndex == fromIndex && param.values[fromIndex] == param.current) return null
    return param.values[newIndex]
}

/** Standard PTP UINT8 battery percentage; 0xFF and every malformed variant remain unknown. */
fun rcBatteryPercentage(param: RcParam?): Int? = param
    ?.takeIf {
        it.prop == Lab.PROP_BATTERY_LEVEL &&
            it.dataType == 0x0002 &&
            it.current in 0L..100L
    }
    ?.current
    ?.toInt()

/**
 * Converts Nikon AngleLevel to the existing (-180, 180] roll convention. INT32/UINT32 values use
 * Nikon's 16.16 fixed-point degrees; 8/16-bit values are treated as whole degrees. A reported
 * 358.8 degrees therefore wraps to roughly -1.2 degrees, while -180 wraps to positive 180.
 */
fun rcAngleLevelRoll(param: RcParam): Float? {
    val degrees = when (param.dataType) {
        0x0005, 0x0006 -> param.current.toDouble() / 65_536.0
        0x0001, 0x0002, 0x0003, 0x0004 -> param.current.toDouble()
        else -> return null
    }
    if (!degrees.isFinite()) return null
    var roll = degrees % 360.0
    if (roll > 180.0) roll -= 360.0
    if (roll <= -180.0) roll += 360.0
    return roll.toFloat()
}
