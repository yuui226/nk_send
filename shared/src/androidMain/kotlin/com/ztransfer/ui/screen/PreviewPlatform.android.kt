package com.ztransfer.ui.screen

internal actual fun previewRadians(degrees: Double): Double = Math.toRadians(degrees)

internal actual fun previewFloorMod(value: Int, divisor: Int): Int = Math.floorMod(value, divisor)
