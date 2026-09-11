package com.ztransfer.ui.screen

internal actual fun previewRadians(degrees: Double): Double = degrees * (kotlin.math.PI / 180.0)

internal actual fun previewFloorMod(value: Int, divisor: Int): Int = value.mod(divisor)
