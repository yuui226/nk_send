package com.ztransfer.filter

import com.ztransfer.R
import java.security.MessageDigest
import java.util.Base64

/**
 * Built-in presets converted from selected Nikon NCP and NP3 files.
 *
 * Source tone curves, global controls, and NP3 Flexible Color mixer values are preserved. Nikon's
 * unpublished RAW development and color-grading pipeline cannot be reproduced pixel-for-pixel on
 * an already developed sRGB JPEG/FHD preview.
 */
object BuiltInPhotoFilters {
    val all: List<PhotoFilterPreset> by lazy {
        listOf(
            convertedNcpPreset(
                sourceSha256 = "e1a017a73e87672949bfaeba946d70aedcf4b4f06f569ec1ec3097a8fa8705aa",
                sourceName = "Kodak Ektar Green",
                toneCurveBase64 = KODAK_EKTAR_GREEN_CURVE,
            ),
            convertedNcpPreset(
                sourceSha256 = "cdd39d33711a509aafb444d6472dc020a819f3b19edd1086ff06a0ed6f5bc29d",
                sourceName = "Kodak-Sun-Nature-02",
                toneCurveBase64 = KODAK_SUN_NATURE_CURVE,
            ),
            convertedNp3Preset(
                sourceSha256 = "1be54af9be2e0403524d16d1c64d02fe1832c0d4fde6ca30e0c83c4d9f32a301",
                sourceName = "MSLT-Portra400-V1",
                saturation = 0,
                colorMixerBase64 = PORTRA_400_COLOR_MIXER,
                toneCurveBase64 = PORTRA_400_CURVE,
            ),
            convertedNp3Preset(
                sourceSha256 = "c3aa853ed066c5dfca2ac2450e8176442026e42b913014d41183fe9bd37dd1cd",
                sourceName = "cineblue brandon",
                saturation = -5,
                colorMixerBase64 = CINE_BLUE_COLOR_MIXER,
                toneCurveBase64 = CINE_BLUE_CURVE,
            ),
            convertedNp3Preset(
                sourceSha256 = "dee50954ceed7af5bc331141da2693485592109f7c857994f30c0112fd2cd95e",
                sourceName = "britfilm bw",
                contrast = 3,
                highlights = -20,
                shadows = 31,
                whites = -34,
                blacks = -10,
                saturation = -98,
                colorMixerBase64 = SILVER_COLOR_MIXER,
            ),
        )
    }

    fun nameResId(filterId: String): Int? = when (filterId) {
        all[0].id -> R.string.photo_filter_builtin_kodak_ektar_green
        all[1].id -> R.string.photo_filter_builtin_kodak_sun_nature
        all[2].id -> R.string.photo_filter_builtin_portra
        all[3].id -> R.string.photo_filter_builtin_cine_blue
        all[4].id -> R.string.photo_filter_builtin_silver
        else -> null
    }

    private fun convertedNcpPreset(
        sourceSha256: String,
        sourceName: String,
        toneCurveBase64: String,
    ): PhotoFilterPreset = PhotoFilterPreset(
        id = convertedPresetId(sourceSha256, NCP_SRGB_CONVERTER_VERSION),
        name = sourceName,
        parameters = NcpPhotoFilterParameters(
            saturationStep = 1,
            hueStep = 1,
            toneCurve = decodeToneCurve(toneCurveBase64),
        ),
    )

    private fun convertedNp3Preset(
        sourceSha256: String,
        sourceName: String,
        contrast: Int = 0,
        highlights: Int = 0,
        shadows: Int = 0,
        whites: Int = 0,
        blacks: Int = 0,
        saturation: Int,
        colorMixerBase64: String,
        toneCurveBase64: String? = null,
    ): PhotoFilterPreset = PhotoFilterPreset(
        id = convertedPresetId(sourceSha256, NP3_SRGB_CONVERTER_VERSION),
        name = sourceName,
        parameters = Np3PhotoFilterParameters(
            contrast = contrast,
            highlights = highlights,
            shadows = shadows,
            whites = whites,
            blacks = blacks,
            saturation = saturation,
            colorBands = decodeNp3ColorMixer(colorMixerBase64),
            toneCurve = toneCurveBase64?.let(::decodeToneCurve),
        ),
    )

    private fun decodeToneCurve(encoded: String): IntArray {
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size == TONE_CURVE_BYTE_COUNT)
        return IntArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            val offset = index * 2
            ((bytes[offset].toInt() and 0xff) shl 8) or
                (bytes[offset + 1].toInt() and 0xff)
        }
    }

    private fun decodeNp3ColorMixer(encoded: String): List<PhotoFilterColorBand> {
        val bytes = Base64.getDecoder().decode(encoded)
        require(bytes.size == NP3_COLOR_MIXER_BYTE_COUNT)
        return PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
            val offset = index * NP3_COLOR_MIXER_VALUES_PER_BAND
            PhotoFilterColorBand(
                centerDegrees = center,
                hue = (bytes[offset].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
                chroma = (bytes[offset + 1].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
                brightness = (bytes[offset + 2].toInt() and 0xff) - NP3_NEUTRAL_VALUE,
            )
        }
    }

    private fun convertedPresetId(sourceSha256: String, converterVersion: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("$sourceSha256|$converterVersion".toByteArray(Charsets.UTF_8))
            .joinToString("") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }

    private const val TONE_CURVE_BYTE_COUNT = PHOTO_FILTER_TONE_CURVE_POINT_COUNT * 2
    private const val NP3_COLOR_MIXER_VALUES_PER_BAND = 3
    private const val NP3_COLOR_MIXER_BYTE_COUNT = 8 * NP3_COLOR_MIXER_VALUES_PER_BAND
    private const val NP3_NEUTRAL_VALUE = 128
    private const val NCP_SRGB_CONVERTER_VERSION = "ncp-srgb-v1"
    private const val NP3_SRGB_CONVERTER_VERSION = "np3-srgb-v1"

    private const val KODAK_EKTAR_GREEN_CURVE =
        "BQUFogY/Bt0HeggXCLQJUQnuCosLKAvFDGIM/w2cDjkO1g9zEBAQrBFJEeYSghMfE7sUVxT0FZAWLBbIF2QYABicGTgZ0xpvGwobphxBHNwddx4SHq0fSB/jIH0hFyGyIkwi5iOAJBkksyVMJeYmfycYJ7EoSSjiKXoqEyqrK0Mr2ixyLQktoC43Ls4vZS/7MJIxKDG9MlMy6TN+NBM0qDU8NdE2ZTb5N404IDizOUY52TpsOv47kDwiPLQ9RT3WPmc++D+IQBhAqEE3QcZCVULkQ3JEAESORRtFqEY1RsFHTUfZSGRI70l6SgRKjksXS6BMKUyxTTlNwE5HTs5PVE/ZUF5Q41FnUetSblLxU3NT9VR2VPZVd1X2VnVW9FdyV+9YbFjpWWRZ31paWtRbTVvGXD5ctl0tXaNeGV6OXwJfdl/pYFtgzWE+Ya5iHWKMYvpjaGPVZEFkrGUWZYBl6WZRZrlnH2eFZ+poT2iyaRVpd2nZajlqmWr4a1drtWwSbG5sym0lbYBt2m4zboxu5G88b5Nv6XA/cJRw6XE9cZFx5XI3copy3HMtc35zznQedG50vXUMdVt1qXX3dkR2kXbedyp3dnfCeA14WHijeO55OHmCecx6Fnpfeql68ns6e4N7zHwUfFx8pHzsfTR9fH3Efgt+U36afuJ/KX9wf7h//w=="

    private const val KODAK_SUN_NATURE_CURVE =
        "A4MDtQPmBBcESAR6BKwE3gURBUQFeAWsBeEGFwZOBoUGvgb3BzIHbQeqB+gIJwhoCKoI7QkyCXkJwQoLClcKpQr0C0YLmQvvDEcMoQz9DVwNvQ4hDocO7w9aD8gQORCtESMRnRIZEpkTGxOhFCoUtxVHFdoWcRcLF6kYSxjwGZkaRhr3G6scYh0dHdsenB9gICYg7yG7IokjWSQrJQAl1iauJ4coYyk/Kh0q/CvcLL0tny6BL2QwRzErMg4y8jPWNLk1nDZ/N2E4QzkjOgM64Tu/PJs9dT5OPyY/+0DPQaBCcEM9RAdEz0WURldHF0fTSI1JQ0n1SqVLUEv4TJ1NPk3cTndPD0+jUDVQw1FPUdhSXlLhU2JT4FRcVNVVTFXBVjNWpFcSV35X6FhRWLdZHFl/WeFaQVqfWv1bWFuzXAxcZFy8XRJdZ127Xg9eYV60XwVfVl+nX/dgR2CWYOZhNWGEYdNiImJyYsJjEWNiY7JkBGRVZKhk+2VOZaNl+GZOZqVm/GdUZ6xoBmhfaLppFWlxac1qKmqHauVrRGujbANsY2zEbSVthm3pbkturm8Sb3Zv2nA/cKRxCnFwcdZyPXKkcwtzc3PbdEN0rHUVdX516HZRdrt3JneQd/t4ZXjQeTx5p3oTen566ntWe8J8LnybfQd9c33gfkx+uX8mf5J//w=="

    private const val PORTRA_400_COLOR_MIXER = "i3+GiICHgICIhHiAgICAcHmLgICAgICA"
    private const val CINE_BLUE_COLOR_MIXER = "nHKegICAgJ2AgEyAlM6AgOSQgICAgICA"
    private const val SILVER_COLOR_MIXER = "YTtxgGCAgUZwgICAgICAgICAgICAgICA"

    private const val PORTRA_400_CURVE =
        "BAQEOwRxBKgE3wUWBU4FhQW+BfYGLwZpBqMG3gcZB1YHkwfRCBAIUAiRCNMJFglbCaAJ5wowCnkKxQsSC2ALsAwCDFUMqg0BDVoNtA4RDm8Ozg8wD5MP+BBfEMgRMhGeEgwSfBLtE2AT1RRMFMUVPxW7FjkWuRc7F74YQxjKGVMZ3RpqGvgbiBwaHK0dQx3aHnMfDh+qIEkg6SGKIi4i0yN6JCIkyyV2JiMm0SeAKDEo4ymWKksrACu3LG8tKC3iLp0vWTAWMNQxkzJSMxMz1DSWNVg2HDbfN6Q4aTkvOfU6uzuCPEk9ET3ZPqE/aUAyQPtBxEKNQ1ZEH0ToRbFGekdDSAxI1EmdSmVLLUv0TLtNgk5ITw5P01CYUVxSIFLjU6VUZlUnVedWpldlWCJY31maWlVbDlvHXH5dNV3qXp1fUGABYLFhYGINYrljZGQMZLRlWmX+ZqFnQmfhaH5pGmm0akxq4mt3bAlsmW0obbRuPm7Gb0xv0HBRcNFxTXHIckBytnMpc5p0CXR1dN51RXWodgp2aHbEdx53dHfJeBt4ani3eQJ5SnmQedV6F3pWepR60HsKe0J7eXute+B8EXxBfG98m3zGfPB9GH0/fWR9iH2sfc59734Ofi1+S35ofoV+oH67ftV+7n8Hfx9/N39Of2V/fH+Sf6h/vn/Uf+l//w=="

    private const val CINE_BLUE_CURVE =
        "BoYGhgaGBoYGoga+BtoG9gcTBy8HTQdqB4gHpwfHB+cICAgpCEwIcAiUCLoI4QkJCTMJXQmKCbcJ5woYCkoKfwq1Cu0LJwtjC6EL4QwkDGgMrwz5DUUNkw3kDjgOjg7oD0QPoxAFEGoQ0hE9EawSHhKTEwwTiBQHFIsVEhWdFiwWvhdVF+8YjhkxGdcagRsvG+EclR1OHgkexx+IIEshEiHbIqYjcyRCJRQl5ya8J5MoailEKh4q+ivWLLMtkS5wL08wLjENMe0yzDOrNIo1aDZGNyM3/zjaObQ6jTtkPDo9Dz3hPrI/gEBNQRhB4UKoQ21EMETxRbBGbkcpR+JImklQSgNKtUtlTBNMv01pThFOuE9cT/9QoFE+UdtSdlMPU6ZUPFTPVWFV8FZ+VwpXlFgcWKNZJ1mqWipaqVsmW6FcGlySXQdde13tXl1ey184X6JgC2BzYNhhPGGfYf9iX2K8Yxhjc2PMZCNkeWTOZSFlc2XDZhJmYGasZvhnQWeKZ9FoF2hcaKBo42kkaWVppGniah9qXGqXatFrCmtDa3prsWvmbBtsT2yCbLVs5m0XbUdtd22lbdRuAW4ublpuhm6xbtxvBm8vb1lvgW+qb9Fv+XAgcEdwbXCTcLlw33EEcSpxT3F0cZhxvXHhcgZyKnJOcnJycnJycnJycnJycnJycg=="
}
