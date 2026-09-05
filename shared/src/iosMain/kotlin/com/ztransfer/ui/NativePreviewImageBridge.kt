package com.ztransfer.ui

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.posix.memcpy

/** One bounded bulk copy; Swift never calls across ObjC once per image byte. */
@OptIn(ExperimentalForeignApi::class)
object NativePreviewImageBridge {
    fun fhdPng(data: NSData): NativeFhdPreviewImage? {
        if (data.length < 33uL || data.length > SINGLE_PHOTO_MAX_BYTES.toULong()) return null
        val source = data.bytes ?: return null
        val bytes = ByteArray(data.length.toInt())
        bytes.usePinned { memcpy(it.addressOf(0), source, data.length) }
        return ownedFhdPreviewPng(bytes)
    }
}
