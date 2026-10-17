package com.ztransfer.storage

import android.os.Build

/**
 * The Harmony document provider has shown intermittent corruption when a
 * reusable protocol buffer is copied directly through SAF.  Keep the
 * compatibility path narrowly scoped: a Huawei device must also positively
 * identify the Harmony system.  If identification is unavailable, the normal
 * Android path remains unchanged.
 */
internal object HarmonyStorageCompatibility {
    private const val HARMONY_BRAND = "Harmony"
    // The affected SLY-AL00 reports osBrand "emui" while running Harmony, and its
    // build changed between field reports (System 104.5.0.001 -> 104.3.5.001).
    // EMUI builds look like "SLY-AL00 13.0.0.xxx(C00E...)"; only the Harmony runtime
    // uses the "System <major>.<minor>.<patch>.<build>" form.
    private val HARMONY_RUNTIME_DISPLAY = Regex("""^System\s+\d+\.\d+\.\d+\.\d+""", RegexOption.IGNORE_CASE)

    data class Detection(
        val enabled: Boolean,
        val huawei: Boolean,
        val manufacturer: String,
        val osBrand: String?,
        val platformVersion: String?,
        val display: String,
        val method: String,
        val error: String? = null,
    )

    fun detect(): Detection = detect(
        manufacturer = Build.MANUFACTURER.orEmpty(),
        display = Build.DISPLAY.orEmpty(),
        readOsBrand = {
            Class.forName("com.huawei.system.BuildEx")
                .getMethod("getOsBrand")
                .invoke(null)
                ?.toString()
        },
        readPlatformVersion = {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java)
                .invoke(null, "hw_sc.build.platform.version")
                ?.toString()
        },
    )

    internal fun detect(
        manufacturer: String,
        display: String,
        readOsBrand: () -> String?,
        readPlatformVersion: () -> String?,
    ): Detection {
        if (!manufacturer.equals("HUAWEI", ignoreCase = true)) {
            return Detection(false, false, manufacturer, null, null, display, "manufacturer")
        }
        var error: String? = null
        val brand = try {
            readOsBrand()
        } catch (failure: Throwable) {
            error = "${failure.javaClass.simpleName}: ${failure.message.orEmpty()}"
            null
        }
        val platformVersion = try {
            readPlatformVersion()?.takeIf { it.isNotBlank() }
        } catch (_: Throwable) {
            null
        }
        val method = when {
            brand?.contains(HARMONY_BRAND, ignoreCase = true) == true -> "BuildEx.getOsBrand"
            HARMONY_RUNTIME_DISPLAY.containsMatchIn(display.trim()) -> "build-display"
            platformVersion != null -> "platform-version"
            else -> "none"
        }
        return Detection(
            enabled = method != "none",
            huawei = true,
            manufacturer = manufacturer,
            osBrand = brand,
            platformVersion = platformVersion,
            display = display,
            method = method,
            error = error,
        )
    }

}
