package com.ztransfer.ui.theme

import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

/** Golden digests captured before extraction; verifies every pixel of all 80 Android variants. */
class SkinTextureBaselineTest {
    @Test
    fun sharedTexturePixelsMatchAllOriginalVariants() {
        val golden = checkNotNull(javaClass.getResourceAsStream("/ui/texture-baseline-55876fa.sha256"))
            .bufferedReader().use { it.readLines() }.filter { it.isNotBlank() && !it.startsWith("#") }
        val actual = mutableListOf<String>()
        val owner = Class.forName("com.ztransfer.ui.theme.SkinTextureKt")
        val mixer = owner.getDeclaredMethod("mixSeed", Int::class.javaPrimitiveType).apply { isAccessible = true }
        listOf(Triple(SkinPreset.TITANIUM, "titaniumTilePixels", 12),
            Triple(SkinPreset.WOOD, "woodTilePixels", 24),
            Triple(SkinPreset.CAMERA_CONTROLS, "cameraControlTilePixels", 4)).forEach { (skin, name, count) ->
            val method = owner.getDeclaredMethod(name, Boolean::class.javaPrimitiveType, Int::class.javaPrimitiveType)
                .apply { isAccessible = true }
            listOf(false, true).forEach { dark ->
                repeat(count) { variant ->
                    val seed = mixer.invoke(null, 0x5F3759DF xor (skin.ordinal * 0x45D9F3B) xor variant) as Int
                    val pixels = method.invoke(null, dark, seed) as IntArray
                    assertEquals(256 * 256, pixels.size)
                    val digest = MessageDigest.getInstance("SHA-256")
                    pixels.forEach { pixel ->
                        digest.update((pixel ushr 24).toByte())
                        digest.update((pixel ushr 16).toByte())
                        digest.update((pixel ushr 8).toByte())
                        digest.update(pixel.toByte())
                    }
                    actual += "$skin $dark $variant ${digest.digest().joinToString("") { "%02x".format(it) }}"
                }
            }
        }
        assertEquals(80, actual.size)
        assertEquals(golden, actual)
    }
}
