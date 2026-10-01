package com.ztransfer.viewmodel

/** Automatic admission only; manual queueing and already admitted tasks are unaffected. */
enum class AutoTransferMode {
    OFF, ALL, JPG, RAW, VIDEO;

    fun accepts(fileName: String): Boolean {
        val ext = fileName.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        return when (this) {
            OFF -> false
            ALL -> ext in setOf("jpg", "jpeg", "nef", "mov", "mp4")
            JPG -> ext == "jpg" || ext == "jpeg"
            RAW -> ext == "nef"
            VIDEO -> ext == "mov" || ext == "mp4"
        }
    }

    companion object {
        fun restored(value: String?, legacyEnabled: Boolean): AutoTransferMode =
            entries.firstOrNull { it.name == value } ?: if (legacyEnabled) ALL else OFF
    }
}
