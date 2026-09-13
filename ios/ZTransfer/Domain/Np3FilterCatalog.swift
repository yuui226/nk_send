import Foundation

/// Exact catalog metadata converted from Android CuratedNp3Filters.kt. The
/// source NP3 identity survives converter revisions; the render ID deliberately
/// includes Android's converter version so derived-output/cache keys stay valid.
struct Np3FilterPreset: Equatable, Identifiable, Sendable {
    let id: String
    let catalogKey: String
    let legacyID: String
    let name: String
    let fallbackName: String
    let parameters: Np3FilterParameters
}

/// The existing iOS slugs map one-to-one to Android's string-resource suffixes.
/// They are retained solely to migrate saved iOS selections; rendering uses the
/// canonical SHA256(sourceSha256 + "|np3-srgb-v1") ID.
enum Np3FilterCatalog {
    static func preset(id: String) -> Np3FilterPreset? {
        presets.first { $0.id == id || $0.catalogKey == id || $0.legacyID == id }
    }

    static let presets: [Np3FilterPreset] = [
        Np3FilterPreset(
            id: "1ecd940d47f9572952b54c2f1e2dcabf5ea9570eca99439bfef3caa13803dba3",
            catalogKey: "0d277cf79b6f91dbb70849a34a61d8fbc3a471838731267c3874d2c50061602d",
            legacyID: "forest_verdure", name: "森屿青", fallbackName: "Forest Verdure",
            parameters: Np3FilterParameters(
                saturation: 75,
                colorMixerBase64: "snGKgHGGXoh2wUlOgLddTmxYdliAimCA",
                toneCurveBase64: "AAAAbADXAUMBsAIeAowC+wNsA94EUQTHBT4FuAY0BrIHNAe4CD8IyQlXCegKfQsWC7MMVAz4DZ8OSg74D6kQXBESEcoShRNCFAEUwhWEFkgXDRfUGJwZZBotGvcbwhyMHVceIx7vH7sghyFUIiEi7iO7JIglViYjJvEnvyiNKVoqKCr2K8QskS1eLiwu+S/GMJIxXzIrMvczwjSONVg2IzbtN7c4gDlJOhE62TugPGc9LT3zPrg/fEBAQQNBxkKIQ0lECUTJRYhGR0cER8FIfUk4SfJKq0tjTBtM0U2HTjtO7k+gUFFRAVGwUl1TClO1VF5VBlWtVlNW91eZWDpY2ll4WhRar1tIW99cdV0JXZteK166X0Zf0WBaYOFhZmHpYmli6GNlY99kWGTOZUJls2YiZo9m+mdiZ8hoLGiNaOtpR2mhafhqTWqgavFrQGuNa9hsImxpbK9s8201bXZttm30bjBubG6mbt9vF29Ob4RvuW/ucCFwVHCGcLhw6XEZcUpxeXGpcdhyCHI3cmZylXLEcvRzJHNTc4RztXPmdBh0SnR9dLF05XUadVB1h3W+dfZ2LnZndqF223cVd1F3jHfIeAV4QniAeL54/Xk8eXt5u3n7ejt6fHq9ev57QHuCe8R8B3xKfIx80H0TfVZ9mn3efiJ+Zn6qfu5/Mn92f7t//w=="
            )
        ),
        Np3FilterPreset(
            id: "3bddb358170ba310997a5793b2324370bbd79a2e90809af99dbc31d6dab7522a",
            catalogKey: "b08c70e745d56244c22e9fca35a8aa6abf0671ff906fcb1c7caead60e1c5eeb8",
            legacyID: "dusk_ember", name: "暮色余温", fallbackName: "Dusk Ember",
            parameters: Np3FilterParameters(
                contrast: 34,
                highlights: -50,
                shadows: -40,
                blacks: -7,
                saturation: 19,
                colorMixerBase64: "RICAVICAPYCAtYCAgICAd3ZqpICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "6474c84688e3b0d921ef2ee127efb046650c2ccec6035e8ce2eac823a4b83b7a",
            catalogKey: "bec5204ff213c929a0d8f4aaf3cbef535d3178f7f106ab879ce3f4c02f593646",
            legacyID: "bleached_silver", name: "漂白银盐", fallbackName: "Bleached Silver",
            parameters: Np3FilterParameters(
                contrast: 40,
                highlights: -20,
                shadows: -55,
                blacks: -10,
                saturation: -50,
                colorMixerBase64: "gn5xjH53hH56iHFkgntxdHR2fm+AiHR2"
            )
        ),
        Np3FilterPreset(
            id: "00445b841a13f49d36f2a9e5ea6587c7742bde8ad16484ef3f2d82ef48b722fd",
            catalogKey: "76aa1920d0f4569431d541dc02a3559c03aa588a55262a40459d5bb0036e45ef",
            legacyID: "blue_hour", name: "蓝调时刻", fallbackName: "Blue Hour",
            parameters: Np3FilterParameters(
                contrast: 10,
                highlights: -10,
                shadows: -20,
                saturation: 20,
                colorMixerBase64: "gICAgICAno+KgICAgICAgICAgI+AgICA"
            )
        ),
        Np3FilterPreset(
            id: "495fc069dab31064babc96d319e09ad3d02de6d4303fb04c58127158a17921d2",
            catalogKey: "33c925bdda847ecfd77e2aecb4765fb7a9ded77e67b77477ffb310335ed2ac92",
            legacyID: "blue_memory", name: "蓝色记忆", fallbackName: "Blue Memory",
            parameters: Np3FilterParameters(
                colorMixerBase64: "fpyAgICAYYCALYCAsF2AeqaAgICAgICA",
                toneCurveBase64: "CooKqgrKCuoLCgsqC0oLawuMC60LzwvxDBQMNwxbDH8MpAzKDPENGA1BDWoNlA2/DewOGQ5HDncOqA7aDw0PQg95D7AP6RAkEGEQnxDeESARYxGoEe8SNxKCEs8THRNuE8EUFhRuFMgVJBWCFeMWRhasFxQXfxfsGFwYzxlEGbsaNRqxGzAbsBwyHLcdPR3FHk8e2x9oH/cghyEZIawiQCLWI20kBSSdJTcl0iZuJwonpyhFKOMpgSogKsArXyv/LJ8tPy3fLn8vHy+/MF4w/TGcMjoy2DN1NBE0rDVHNeE2ejcSN6g4PjjSOWU59zqHOxY7ozwvPLo9Qz3LPlI+1z9cP99AYUDiQWJB4EJeQttDV0PSRExExUU+RbZGLUajRxhHjUgCSHVI6UlbSc1KP0qwSyFLkkwCTHJM4k1RTcBOL06eTw1PfE/rUFlQyFE3UaZSFVKEUvNTY1PTVENUs1UkVZVWB1Z5VutXXlfSWEZYu1kwWaZaHVqVWw1bhlwAXHtc9l1zXfBebl7tX21f7mBvYPFhdGH4Yn1jAmOIZA5klWUdZaZmL2a5Z0NnzmhaaOZpc2oAao5rHGurbDpsym1abetufG8Ob59wMnDEcVdx63J+cxJzp3Q7dNB1ZXX7dpB3Jne8eFJ46XmAehZ6rXtEe9t8cn0KfaF+OX7Qf2d//w=="
            )
        ),
        Np3FilterPreset(
            id: "644e9710e38197be33257f0562f89dc3882642e36be6d2b295f82f813597a6d7",
            catalogKey: "dee50954ceed7af5bc331141da2693485592109f7c857994f30c0112fd2cd95e",
            legacyID: "british_mono", name: "英伦黑白", fallbackName: "British Mono",
            parameters: Np3FilterParameters(
                contrast: 3,
                highlights: -20,
                shadows: 31,
                whites: -34,
                blacks: -10,
                saturation: -98,
                colorMixerBase64: "YTtxgGCAgUZwgICAgICAgICAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "62044540049c1837111d295630731828c37eaa87d2d939589884097187292a2b",
            catalogKey: "c58ef768566c295700edf11daf9dec02c237e4ae0be874bbe32403256082fa20",
            legacyID: "love_glow", name: "恋爱柔光", fallbackName: "Love Glow",
            parameters: Np3FilterParameters(
                saturation: 30,
                colorMixerBase64: "gICAgHuPinmElZWUgICAZoCJgICAioSA",
                toneCurveBase64: "AAABCwISAxgEHAUfBiAHIQggCR0KGQsUDAwNAw34DusP2xDKEbUSnhOFFGgVSRYmFwEX2hivGYIaUxshG+0cth18HkEfAx/DIIAhPCH1IqwjYSQUJMYldSYjJs4neCggKMcpbCoPKrArUCvvLIwtKC3DLlwu9C+KMCAwtDFHMdoyazL7M4o0GTSmNTM1vzZLNtU3XzfpOHE4+jmCOgk6kDsXO508IjynPSw9sD4zPrY/OT+7QDxAvUE9QbxCO0K6QzdDtUQxRK1FKEWjRh1GlkcPR4dH/kh0SOpJX0nUSkdKukssS55MDkx+TO1NW03ITjVOoU8MT3ZP31BHUK9RFVF7UeBSRFKnUwlTalPKVCpUiFTlVUJVnVX3VlFWqVcAV1dXrFgAWFNYplj3WUdZllnjWjBafFrGWw9bWFufW+RcKVxtXK9c8F0wXW9drF3pXiReXl6WXs5fBV86X29fo1/XYAlgPGBuYJ9g0GEBYTJhYmGTYcRh9WImYldiiWK7Yu5jIWNVY4pjwGP2ZC5kZmSgZNtlF2VVZZRl1GYWZlpmn2bnZzBne2fIaBdoaWi9aRNpa2nGaiRqhGrna01rtWwhbI9tAW12be5uam7ob2tv8XB6cQdxmHItcsZzYnQCdKZ1THX2dqJ3UHgBeLV5anogetl7k3xOfQp9xn6Ef0F//w=="
            )
        ),
        Np3FilterPreset(
            id: "00ad1a38d1b031eb321b680f66230da175a40a0e6161a6f34a02a7e83c8c88a6",
            catalogKey: "6dbdc3cad35d785215359e452a0e192cafd3c6693cbb98bc640d76c772837981",
            legacyID: "calm_breeze", name: "静谧微风", fallbackName: "Calm Breeze",
            parameters: Np3FilterParameters(
                contrast: 18,
                highlights: 31,
                shadows: -20,
                whites: -27,
                blacks: 5,
                saturation: 7,
                colorMixerBase64: "gICAgICAfIGAgICAgICAgICAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "079ca263bcef213f804aa4f49b3d3a4570828647c4d8563860f147d2128ee778",
            catalogKey: "c3aa853ed066c5dfca2ac2450e8176442026e42b913014d41183fe9bd37dd1cd",
            legacyID: "cinema_blue", name: "电影蓝", fallbackName: "Cinema Blue",
            parameters: Np3FilterParameters(
                saturation: -5,
                colorMixerBase64: "nHKegICAgJ2AgEyAlM6AgOSQgICAgICA",
                toneCurveBase64: "BoYGhgaGBoYGoga+BtoG9gcTBy8HTQdqB4gHpwfHB+cICAgpCEwIcAiUCLoI4QkJCTMJXQmKCbcJ5woYCkoKfwq1Cu0LJwtjC6EL4QwkDGgMrwz5DUUNkw3kDjgOjg7oD0QPoxAFEGoQ0hE9EawSHhKTEwwTiBQHFIsVEhWdFiwWvhdVF+8YjhkxGdcagRsvG+EclR1OHgkexx+IIEshEiHbIqYjcyRCJRQl5ya8J5MoailEKh4q+ivWLLMtkS5wL08wLjENMe0yzDOrNIo1aDZGNyM3/zjaObQ6jTtkPDo9Dz3hPrI/gEBNQRhB4UKoQ21EMETxRbBGbkcpR+JImklQSgNKtUtlTBNMv01pThFOuE9cT/9QoFE+UdtSdlMPU6ZUPFTPVWFV8FZ+VwpXlFgcWKNZJ1mqWipaqVsmW6FcGlySXQdde13tXl1ey184X6JgC2BzYNhhPGGfYf9iX2K8Yxhjc2PMZCNkeWTOZSFlc2XDZhJmYGasZvhnQWeKZ9FoF2hcaKBo42kkaWVppGniah9qXGqXatFrCmtDa3prsWvmbBtsT2yCbLVs5m0XbUdtd22lbdRuAW4ublpuhm6xbtxvBm8vb1lvgW+qb9Fv+XAgcEdwbXCTcLlw33EEcSpxT3F0cZhxvXHhcgZyKnJOcnJycnJycnJycnJycnJycg=="
            )
        ),
        Np3FilterPreset(
            id: "ac3b61a07850c50ba38821937ce84867b290f3f88ac241b631dabe1d8ac2b114",
            catalogKey: "6586bf9e061a9db3104da36dab3a659ed255f3227cf2b8b32a897f3ca842d46d",
            legacyID: "cinematic_dusk", name: "电影暮影", fallbackName: "Cinematic Dusk",
            parameters: Np3FilterParameters(
                colorMixerBase64: "gICAgICAgICAgICAgICAgICAgICAgICA",
                toneCurveBase64: "CYkJugnqChsKSwp8Cq0K3gsQC0ELcwulC9gMCww/DHMMpwzcDRINSA1/DbYN7w4oDmEOnA7YDxQPUQ+PD84QDxBQEJIQ1hEaEWARpxHvEjkShBLQEx4TbRO9FA8UYxS4FQ8VZxXBFh0WehbZFzoXnRgCGGgY0Rk7GacaFRqEGvYbaRvdHFQcyx1FHcAePB66HzkfuSA7IL4hQiHIIk8i1yNgI+okdSUBJY4mHCarJzsnzChdKO8pgioWKqorPyvVLGstAS2YLjAuyC9gL/kwkjErMcUyXzL4M5M0LTTHNWE1+zaWNzA3yjhkOP45lzowOsk7Yjv6PJI9Kj3BPlg+7j+DQBhArEFAQdNCZUL3Q4dEF0SmRTRFwkZPRttHZkfwSHpJA0mMShRKm0siS6hMLUyyTTZNuk49TsBPQk/EUEVQxlFGUcZSRlLFU0NTwlRAVL1VO1W4VjVWsVctV6lYJVigWRxZl1oSWo1bB1uCW/xcd1zxXWtd5V5fXtlfU1/NYEdgwWE7YbZiMGKqYyVjn2QaZJVlEGWLZgdmg2b+Z3tn92h0aPBpbWnramhq5mtka+JsYGzfbV1t3G5bbtpvWW/ZcFlw2HFYcdhyWHLZc1lz2nRbdNt1XHXddl524Hdhd+J4ZHjleWd56Hpqeux7bnvvfHF88311ffd+eX77f31//w=="
            )
        ),
        Np3FilterPreset(
            id: "f367e8de6e48c3ce3ac7a12e0d286747a23adf5a476d11d7f91a3a02bdacf633",
            catalogKey: "45bec08a572f5da2383b87dc33ced39b92a6c66652a7ea9f2e51a91e7ca7adc0",
            legacyID: "clear_portrait", name: "清透人像", fallbackName: "Clear Portrait",
            parameters: Np3FilterParameters(
                saturation: 13,
                colorMixerBase64: "hoCAhYCQgICIgG6AgICAgICAgICAgICA",
                toneCurveBase64: "AYEBuwHxAiYCWgKOAsIC9wMsA2EDmAPPBAcEQQR7BLgE9gU1BXcFugYABkgGkgbeBy4HgAfVCCwIhwjmCUcJrAoUCoEK8QtlC90MWAzXDVoN4Q5qDvcPiBAbELERShHmEoUTJhPKFHAVGRXDFnAXHxfQGIIZNhnsGqMbXBwWHNEdjh5LHwkfySCIIUkiCiLLI40kTyURJdQmlydaKB4o4SmlKmkrLSvxLLUteS49LwEvxTCJMUwyEDLTM5Y0WTUcNd42oDdiOCM45DmkOmQ7IzviPKE9Xj4cPtg/lEBPQQpBw0J8QzRD7ESiRVhGDEbAR3NIJUjVSYVKNErhS41MOEziTYtOM07ZT35QIVDDUWRSA1KhUz5T2VRyVQpVoFY1VshXWlfqWHlZB1mTWh1aplsuW7RcOVy9XT9dwF5AXr5fO1+3YDJgq2EjYZpiD2KDYvdjaWPaZElkuGUlZZJl/WZnZtBnOGefaAVoamjOaTFpk2n0alRqs2sSa29ry2wnbIJs3G01bY1t5G47bpBu5W86b41v4HAycINw1HEkcXNxwnIPcl1yqnL2c0FzjHPWdCB0anSydPt1QnWKddB2F3ZddqJ253csd3B3tHf4eDt4fXjAeQJ5RHmGecd6CHpJeol6ynsKe0p7invJfAl8SHyHfMZ9BX1EfYN9wn4Afj9+fg=="
            )
        ),
        Np3FilterPreset(
            id: "c4927d2645d780756daf181cbb189196faa1d0064a6ddd94ce29bc05f46476ae",
            catalogKey: "3dd20e9529471c8c1e5e51e8284e2d7ded0b99d72b700b82eab7bfbb3972e017",
            legacyID: "cozy_autumn", name: "暖秋", fallbackName: "Cozy Autumn",
            parameters: Np3FilterParameters(
                contrast: -15,
                highlights: -48,
                shadows: 48,
                whites: -31,
                blacks: -17,
                saturation: -2,
                colorMixerBase64: "gIiAgICAgICAgICAgICAgICAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "af4bab0c0ffea25ea32e89ccfd29570b28c56e3cfdbd1918342f4785592fc3b1",
            catalogKey: "e3b23a2ec3225d3bc85703b6530890b27c8ee62085e7802898bf67b4d4eeeb44",
            legacyID: "dawn_hues", name: "晨曦", fallbackName: "Dawn Hues",
            parameters: Np3FilterParameters(
                contrast: -23,
                highlights: -29,
                shadows: 19,
                whites: 29,
                blacks: -17,
                saturation: 8,
                colorMixerBase64: "gJSJdpSKhZSKhWx2qFh2gFh2gFiAgFiA"
            )
        ),
        Np3FilterPreset(
            id: "d3d207ab4b366f0c14a226fa005f99c668e704823b1c198e5273b4566f957627",
            catalogKey: "e4d8bc83e450d25d54db2aaa36b4067d03441fa1440a77829570efee7a3d6504",
            legacyID: "darkroom_film", name: "暗房胶片", fallbackName: "Darkroom Film",
            parameters: Np3FilterParameters(
                highlights: -50,
                shadows: -57,
                blacks: 8,
                saturation: -5,
                colorMixerBase64: "gIBqgHZ7e2x2gXZ0g2xtgGxfe3BfgHRi"
            )
        ),
        Np3FilterPreset(
            id: "016fe02c15f824000594d6a219181453fbbdf276d1eed502536e6a46434a9df8",
            catalogKey: "e6f26d84a5ba02fd21efd1e5238808325dfb6aba9e2606e3a55c6068a4594a12",
            legacyID: "fern_shade", name: "蕨影", fallbackName: "Fern Shade",
            parameters: Np3FilterParameters(
                colorMixerBase64: "gICAgHqAgGt2i2dufICAeIlxgGKAgGKA",
                toneCurveBase64: "AAAAJABHAGsAjwCzANgA/QEjAUkBcAGXAb8B6QITAj4CagKXAsUC9QMmA1kDjQPCA/kEMgRtBKkE6AUoBWsFrwX2Bj8GigbYBygHewfRCCkIgwjhCUAJowoHCm8K2AtEC7MMJAyXDQ0NhA3/DnsO+g97D/4QgxEKEZQSHxKtEz0TzhRiFPgVjxYpFsUXYhgBGKIZRRnqGpAbOBviHI4dOh3pHpkfSh/8ILAhZSIbItIjiiRDJP0ltyZzJy8n7CipKWcqJSrkK6MsYi0hLeEuoS9gMCAw4DGfMl4zHTPcNJo1WDYVNtI3jjhKOQQ5vjp3Oy875jycPVE+BT63P2hAGEDGQXNCH0LKQ3NEGkTARWVGCUasR01H7EiLSShJxEpfSvlLkUwoTL5NUk3mTnhPCU+ZUChQtVFCUc1SV1LgU2hT71R0VPlVfVX/VoFXAVeAV/5YfFj4WXNZ7VpnWt9bVlvMXEJctl0pXZxeDl5+Xu5fXV/LYDhgpGEQYXph5GJNYrVjHGODY+lkTmSyZRZleWXbZj1mnmb+Z11nvGgaaHho1WkyaY5p6WpEap5q+GtRa6psAmxabLFtCG1ebbRuCm5fbrRvCG9cb7BwA3BWcKlw+3FNcZ9x8HJCcpNy43M0c4Rz1HQkdHR0xHUTdWN1snYBdlB2n3budz13i3faeCl4eA=="
            )
        ),
        Np3FilterPreset(
            id: "d2c32ed51bebac9379200d4bb575cac7c8be7341bf26bdeccbca7c9f137b1f7b",
            catalogKey: "a5842375eec8f432b6992dd0d52b42d279b6fecfc27ce1a29772b46cb5cce0a1",
            legacyID: "classic_film", name: "经典胶片", fallbackName: "Classic Film",
            parameters: Np3FilterParameters(
                saturation: 20,
                colorMixerBase64: "in6OinuPZYWecViAfE6KU2JngFiPlF2F",
                toneCurveBase64: "AoICggKCAoICggKCAoICggKCAoICggKCAoIC8gNNA6AD7QQ2BH0EwwUGBUkFiwXMBg4GTwaRBtMHFQdYB50H4ggoCHAIuQkECVAJnwnvCkEKlgrtC0YLogwADGIMxg0sDZUOAQ5vDuAPUg/IED8QuRE0EbISMhK0EzcTvRREFM0VWBXkFnIXAReSGCQYuBlMGeIaeRsSG6scRhzhHX4eHB67H1sf+yCdIUAh4yKIIy0j0yR6JSIlyiZ0Jx0nyChzKR8pzCp5KyYr1CyDLTIt4i6SL0Iv8zCkMVYyBzK6M2w0HjTRNYQ2NzbqN504UTkEObc6azseO9E8hD03Peo+nT9QQAJAtEFmQhdCyUN6RCpE2kWKRjlG6EeWSENI8UmdSklK9EufTElM8k2aTkJO6U+PUDRQ2VF8Uh9SwFNhVABUn1U8VdlWdFcOV6dYP1jVWWtZ/1qRWyNbs1xCXM9dW13lXm5e9V97X/9ggmEDYYNiAGJ8Yvdjb2PmZFtkzmU/Za9mHGaIZvJnWWe/aCJohGjjaUBpnGn1ak1qomr2a0hrmGvnbDRsf2zIbRBtVm2bbd9uIW5hbqFu328bb1dvkW/KcAJwOXBvcKRw2HELcT1xbnGfcc5x/XIrcllyhnKyct5zCXM0c15ziHOyc9t0BHQtdFZ0fnSndM901nTWdNZ01g=="
            )
        ),
        Np3FilterPreset(
            id: "cc88bf89b1ac0e5489cd753988bbc2a2ae3fb952d072533f96bc482a3ede2645",
            catalogKey: "9baef65946f0abc5df742526278ba70f18d0892323e725528c12c273d54e69b5",
            legacyID: "golden_dusk", name: "金色黄昏", fallbackName: "Golden Dusk",
            parameters: Np3FilterParameters(
                saturation: 12,
                colorMixerBase64: "gICAgJBtT4eEHHudgICAgH9zgICAgICA",
                toneCurveBase64: "AAAAeQDxAWoB4wJcAtQDTQPGBEAEuQUzBawGJgagBxoHlQgQCIsJBgmCCf4Kegr2C3ML8QxuDOwNaw3qDmkO6Q9qD+sQbBDuEXAR8xJ3EvsTgBQFFIsVEhWaFiIWqhc0F74YSRjVGWEZ7xp9GwwbmxwsHL0dTx3iHnYfCh+fIDUgyyFiIfoikiMrI8UkXyT5JZQmMCbMJ2goBiijKUEp3yp+Kx0rvSxdLP0tnS4+Lt8vgTAiMMQxZjIIMqszTTPwNJM1NjXZNnw3IDfDOGY5CjmtOlE69DuXPDo83T2BPiM+xj9pQAtArkFQQfJCk0M1Q9ZEd0UXRbdGV0b3R5ZINUjTSXFKD0qsS0lL5UyATRxNtk5QTupPg1AbULNRSlHgUnZTC1OfVDNUxlVYVepWelcKV5lYJ1i1WUFZzVpYWuFbalvyXHlc/12EXghei18NX45gDmCMYQphhmICYnxi9WNtY+RkWmTPZUNltmYoZplnCWd4Z+ZoU2i/aStplWn/amhq0Gs3a51sA2xnbMttLm2RbfJuU260bxNvcm/QcC5wi3DncUJxnXH4clJyq3MEc1xzs3QLdGF0t3UNdWJ1t3YLdl92s3cGd1l3q3f9eE94oHjxeUJ5knniejJ6gnrReyB7b3u+fAx8W3ypfPd9RX2TfeF+Ln58fsl/F39kf7J//w=="
            )
        ),
        Np3FilterPreset(
            id: "b7cfc1b1d5bc74a1ce464fe86c86a7abdb025914ff28aadb7cf3a3b6e355c22d",
            catalogKey: "34a35f27c7d7f51d97852c9cc2cc57cc68f4543ac0c2f302901e844979347631",
            legacyID: "soft_harmony", name: "和煦", fallbackName: "Soft Harmony",
            parameters: Np3FilterParameters(
                contrast: 8,
                highlights: -27,
                shadows: 13,
                whites: 9,
                blacks: -10,
                saturation: 10,
                colorMixerBase64: "tIuQaJB6W4aIYIB7LYBtJoCAe4CAgICA"
            )
        ),
        Np3FilterPreset(
            id: "be6632886a8f33612fcb59b29652bb49c9f3d40a9bcdf0ad65309204e04a9deb",
            catalogKey: "f4fd3141b1642e2ec734860d50e1a5cd5c9f52b881d9e33149ec7afa656a6991",
            legacyID: "urban_green", name: "城市绿意", fallbackName: "Urban Green",
            parameters: Np3FilterParameters(
                contrast: -12,
                highlights: -25,
                shadows: 26,
                whites: -29,
                blacks: -4,
                saturation: 9,
                colorMixerBase64: "h4B2d3CAjGyFuXqJfICAfXiAgHOFgICA"
            )
        ),
        Np3FilterPreset(
            id: "695554fe4282ff574b7457ad7eca70e6ea50a87aaca387af4b8266843dd44dd0",
            catalogKey: "7c7fdcfe871c66e27166bb366bcde9aa29dc2e8fb803a15bf7ffc8c858f27c66",
            legacyID: "matte_blue", name: "雾蓝哑光", fallbackName: "Matte Blue",
            parameters: Np3FilterParameters(
                saturation: -6,
                colorMixerBase64: "h3GEfXuUgXiJd3SYhXGAdHB8iX2Fg3yF",
                toneCurveBase64: "FCsUKxQrFCsUQRRYFG8UhhSeFLUUzRTlFP0VFRUuFUcVYRV7FZYVsRXNFekWBhYjFkIWYRaBFqEWwxblFwgXLBdSF3gXnxfIF/EYHBhIGHUYoxjTGQQZNhlqGZ8Z1hoOGkgagxrAGv8bPxuBG8UcChxSHJsc5h0zHYMd1B4nHnwe0x8tH4kf5iBHIKkhDiF1Id4iSiK5IyojnSQTJIwlByWFJgYmiScPJ5goJCiyKUIp1SpqKwIrmyw2LNQtcy4ULrYvWi//MKYxTTH2MqAzSzP3NKQ1UTX/Nq03XDgLOLo5aToZOsg7dzwmPNQ9gj4vPtw/iEAzQN1Bh0IvQtZDe0QfRMJFZEYERqNHQUfdSHhJEkmrSkJK2EttTAFMlE0lTbVORE7ST19P6lB1UP5RhlINUpNTGFOcVB9UoVUiVaFWIFaeVxtXllgRWItZBFl8WfNaaVreW1Nbxlw5XKpdG12LXfpeaV7WX0Nfr2AaYIVg7mFXYb9iJ2KNYvNjWWO9ZCFkhGTnZUllqmYLZmtmymcpZ4hn5WhCaJ9o+2lXabJqDGpmasBrGWtxa8lsIWx4bM9tJm18bdFuJm57btBvJG93b8twHnBxcMNxFXFncblyCnJccqxy/XNOc55z7nQ+dI103XUsdXt1ynYZdmh2t3cGd1R3o3fxeD94jnjceSp5eQ=="
            )
        ),
        Np3FilterPreset(
            id: "1ca70dc3e1202048b2fc612edd073ecbf9c56de6f649d5bd3fde26c7eaec08a5",
            catalogKey: "71ca9fe9d7afe6eab33094a521c3135bf4bf6d9ff66b2f2a1797517e17a0843f",
            legacyID: "moss_mood", name: "苔绿情绪", fallbackName: "Moss Mood",
            parameters: Np3FilterParameters(
                contrast: 6,
                highlights: 9,
                shadows: 12,
                whites: 8,
                blacks: -17,
                colorMixerBase64: "gICAgYiBgJ3R32B9ppmAYliAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "927a6c72628727ca41e43700f0bc33968391b66a8b8939335f6a01ad83cd1c66",
            catalogKey: "cd4001092f8f2d77c7e7f10ecaf79970eb79272fbbef6bd98bec98219e9504a6",
            legacyID: "green_shadows", name: "墨绿暗影", fallbackName: "Green Shadows",
            parameters: Np3FilterParameters(
                contrast: 50,
                highlights: -30,
                shadows: -30,
                whites: -40,
                blacks: 10,
                saturation: -5,
                colorMixerBase64: "gHZogIB2hahsgIVtgIqAgKNTgI+AgICA"
            )
        ),
        Np3FilterPreset(
            id: "a247d4033b0c11acb864dcf03c7355d213e39e81c4030bedb71067e7ca5f14f7",
            catalogKey: "1be54af9be2e0403524d16d1c64d02fe1832c0d4fde6ca30e0c83c4d9f32a301",
            legacyID: "soft_portrait", name: "柔暖人像", fallbackName: "Soft Portrait",
            parameters: Np3FilterParameters(
                colorMixerBase64: "i3+GiICHgICIhHiAgICAcHmLgICAgICA",
                toneCurveBase64: "BAQEOwRxBKgE3wUWBU4FhQW+BfYGLwZpBqMG3gcZB1YHkwfRCBAIUAiRCNMJFglbCaAJ5wowCnkKxQsSC2ALsAwCDFUMqg0BDVoNtA4RDm8Ozg8wD5MP+BBfEMgRMhGeEgwSfBLtE2AT1RRMFMUVPxW7FjkWuRc7F74YQxjKGVMZ3RpqGvgbiBwaHK0dQx3aHnMfDh+qIEkg6SGKIi4i0yN6JCIkyyV2JiMm0SeAKDEo4ymWKksrACu3LG8tKC3iLp0vWTAWMNQxkzJSMxMz1DSWNVg2HDbfN6Q4aTkvOfU6uzuCPEk9ET3ZPqE/aUAyQPtBxEKNQ1ZEH0ToRbFGekdDSAxI1EmdSmVLLUv0TLtNgk5ITw5P01CYUVxSIFLjU6VUZlUnVedWpldlWCJY31maWlVbDlvHXH5dNV3qXp1fUGABYLFhYGINYrljZGQMZLRlWmX+ZqFnQmfhaH5pGmm0akxq4mt3bAlsmW0obbRuPm7Gb0xv0HBRcNFxTXHIckBytnMpc5p0CXR1dN51RXWodgp2aHbEdx53dHfJeBt4ani3eQJ5SnmQedV6F3pWepR60HsKe0J7eXute+B8EXxBfG98m3zGfPB9GH0/fWR9iH2sfc59734Ofi1+S35ofoV+oH67ftV+7n8Hfx9/N39Of2V/fH+Sf6h/vn/Uf+l//w=="
            )
        ),
        Np3FilterPreset(
            id: "ad0bdf98b12ddb765f93711dc05845417602ebd005bef2b6186e0b75aef65a60",
            catalogKey: "e427f04afb57c5fa8301a596874d7fb8ac3af434a7c0b0d52c6ff3055ae2b992",
            legacyID: "natural_link", name: "自然联结", fallbackName: "Natural Link",
            parameters: Np3FilterParameters(
                saturation: 18,
                colorMixerBase64: "gICAgICAgICAgICAgICAdJOAgICAgICA",
                toneCurveBase64: "AwMDPQN4A7MD7gQpBGUEogTfBR0FWwWbBdwGHQZhBqUG6wcyB3sHxggSCGAIsQkDCVgJrwoICmMKwgsiC4YL7AxWDMINMg2kDhoOkg8OD4wQDhCSERgRohIuErwTTRPgFHYVDhWpFkYW5BeFGCkYzhl1Gh4ayBt1HCMc0x2FHjge7R+kIFshFCHPIoojRyQFJMUlhSZGJwgnyyiPKVQqGirgK6Ysbi02Lf4uxy+QMFkxIzHtMrczgTRLNRU13zapN3M4PDkGOc86lztfPCc87j20Pno/P0AEQMdBikJMQwxDzESLRUhGBUbAR3lIMkjpSZ9KU0sFS7ZMZU0TTb9OaU8RT7hQXlEBUaNSRFLjU4BUHFS2VU9V5lZ8VxBXo1g0WMRZUlngWmta9Vt+XAZcjF0RXZReFl6XXxdflWASYI1hCGGBYflicGLmY1pjzmRAZLFlIWWPZf1mambVZ0BnqWgRaHlo32lFaalqDGpvatBrMWuQa+9sTWyqbQZtYW27bhVubm7Gbx1vc2/JcB1wcnDFcRdxaXG7cgtyW3KqcvlzR3OUc+F0LXR5dMR1DnVYdaJ163Yzdnt2wncJd1B3lnfceCF4ZniqeO55Mnl2ebl5+3o+eoB6wnsDe0V7hnvHfAh8SHyIfMh9CH1IfYh9x34HfkZ+hX7EfwN/Qn+Bf8B//w=="
            )
        ),
        Np3FilterPreset(
            id: "4c72e375c36d9b0f589087b761261ba6c03a42ebb507f667368f2c706675ac7e",
            catalogKey: "6589fe70d5362bb0e2b5f21c7d82610d07f087b4600fd772efdf2329146ddef6",
            legacyID: "cyan_negative", name: "青色负片", fallbackName: "Cyan Negative",
            parameters: Np3FilterParameters(
                shadows: -70,
                blacks: -15,
                colorMixerBase64: "lICFioB7dnt+o2JgqJlYdnF7hU6FvHGK"
            )
        ),
        Np3FilterPreset(
            id: "3c65e00ec2b4b541af30facc3ac79646935fb42341551d393442e3a404398f29",
            catalogKey: "c35e458aa2673b8d1968497d5c18a03351f1d4cc1635b0b7d5fad7f54805ad42",
            legacyID: "red_cyan", name: "红青负片", fallbackName: "Red Cyan",
            parameters: Np3FilterParameters(
                whites: 10,
                blacks: -15,
                saturation: 10,
                colorMixerBase64: "YnF2j3t7ipmFWICFj3aPhXaZZ3uAdoCA"
            )
        ),
        Np3FilterPreset(
            id: "e0bda99f7778d9455be8a15f49c070b581b41cbf3e45f6a2a8d18c4ba4a46127",
            catalogKey: "e5b262787ebfece2b216b5de95a5504cd771a1de57fe681531f3232fa9de4af3",
            legacyID: "teal_negative", name: "茶青负片", fallbackName: "Teal Negative",
            parameters: Np3FilterParameters(
                contrast: -25,
                highlights: -10,
                shadows: -30,
                whites: -5,
                saturation: 20,
                colorMixerBase64: "SXFsnnGUipSPXXueqHGjinFngIVinmd7"
            )
        ),
        Np3FilterPreset(
            id: "668aa70a384c92346584ba9b8a0e3ab328de88bca2bad8e3c490c0bc9a5dad91",
            catalogKey: "32184d99df35adeccb63d06d504c4e76a7830acf86710cbd0f1c108f3e3d35ab",
            legacyID: "lemon_negative", name: "柠黄负片", fallbackName: "Lemon Negative",
            parameters: Np3FilterParameters(
                highlights: -10,
                shadows: -5,
                whites: 10,
                blacks: -15,
                saturation: 10,
                colorMixerBase64: "cWx7lHaUiqiUWICPmWyAinGKe4CAXXGA"
            )
        ),
        Np3FilterPreset(
            id: "8ec888c5e6461303c261757f01f52a2ba8625530a2aa9208e6366f6369a0b0a4",
            catalogKey: "c750bd30a6b411504251e687aef473fdcc664c9db638633fe9d9eb3ff4a341a3",
            legacyID: "amber_negative", name: "琥珀负片", fallbackName: "Amber Negative",
            parameters: Np3FilterParameters(
                contrast: -15,
                highlights: -10,
                shadows: -15,
                whites: 10,
                blacks: -15,
                saturation: 10,
                colorMixerBase64: "lF2Po3uUj62PTnt7lGeFimx7Z3GPcWd7"
            )
        ),
        Np3FilterPreset(
            id: "8185217a39749c4efdb85cfa9329fe527771fea3b88d58ccaf3cfe849dcc9c1b",
            catalogKey: "ec02d8e5c7df424e08bab9372750e6ed57a9461e85a62aaafbd92047079af42f",
            legacyID: "lime_negative", name: "黄绿负片", fallbackName: "Lime Negative",
            parameters: Np3FilterParameters(
                contrast: 5,
                whites: 10,
                blacks: -10,
                saturation: 10,
                colorMixerBase64: "WGxirYWKireUXZmKgE57j3txcYWFcWd7"
            )
        ),
        Np3FilterPreset(
            id: "8d9e839715153b3da1691604133cd24de74336eb817ea6f4cad4be1718516c2d",
            catalogKey: "bd36bef9d4cea13ad0430b0ba39a98567622d1ae8e81b5b381f3855d0bbd0978",
            legacyID: "pastel_pink", name: "粉彩柔光", fallbackName: "Pastel Pink",
            parameters: Np3FilterParameters(
                saturation: 5,
                colorMixerBase64: "jHZ2gH+AinuAgHaAhYCAe3uAdnZidnZh",
                toneCurveBase64: "BoYGtQbjBxEHQAdvB54HzQf8CCwIXAiNCL4I8AkiCVUJiQm9CfIKKApeCpYKzgsIC0ILfgu6C/gMNwx3DLkM/A1ADYUNzA4VDl8Oqw74D0cPmA/qED4QlBDsEUYRohIAEmASwxMnE40T9RRfFMsVOBWoFhkWjBcBF3cX7xhpGOQZYBneGl4a3xthG+UcahzwHXgeAR6KHxUfoiAvIL0hTCHcIm0i/yOSJCYkuiVPJeUmeycSJ6ooQijbKXQqDiqoK0Mr3Sx5LRQtsC5MLugvhDAgML0xWTH1MpIzLjPKNGY1AjWdNjk21DduOAk4ozk8OdU6bjsGO508NDzKPV899D6IPxs/rkA/QNBBYEHwQn9DDUOaRCdEs0U+RclGU0bcR2VH7Uh1SPxJgkoISo1LEkuWTBpMnU0fTaFOI06kTyRPpFAkUKNRIVGgUh1Sm1MYU5RUEFSMVQdVglX9VndW8VdrV+RYXVjWWU9Zx1o/WrZbLlulXBxckl0JXX9d9V5rXuBfVl/LYEFgtmEqYZ9iFGKJYv1jcmPmZFpkzmVDZbdmK2afZxNnh2f7aG9o42lYacxqQGq0ayhrnGwRbIVs+W1ubeJuVm7Kbz9vs3AncJxxEHGFcflybXLic1Zzy3Q/dLN1KHWcdhF2hXb6d25343hXeMx5QHm1eil6nnsSe4d7+w=="
            )
        ),
        Np3FilterPreset(
            id: "4a4e50fb981a5e933bec407018f9f42070807a7ed07ecd3afce891193b377c2c",
            catalogKey: "2a00641ffda460ae5184bef8fd0f34b8d0f1d5ce2d890a6a1de6fbfb56532dce",
            legacyID: "rose_vintage", name: "玫瑰旧片", fallbackName: "Rose Vintage",
            parameters: Np3FilterParameters(
                saturation: -5,
                colorMixerBase64: "gICAj26rgF13iGA4gICAj4OAgICAk3Kb",
                toneCurveBase64: "B08HTwdPB08HTweUB9sIIwhqCLEI+Ak/CYcJzgoWCl4KpgruCzYLfgvHDBAMWQyiDOwNNg2ADcoOFQ5gDqwO9w9ED5AP3RAqEHgQxhEVEWQRsxIDElQSpRL2E0gTmxPuFEIUlhTrFUEVlxXuFkYWnhb3F1AXqxgGGGEYvhkbGXkZ1xo2GpYa9htXG7kcGxx9HOAdRB2oHgwecR7XHzwfoyAJIHAg2CE/IaciDyJ4IuEjSiOzJBwkhiTwJVolxCYvJpknAyduJ9koQyiuKRkphCnuKlkqxCsuK5ksAyxtLNgtQS2rLhUufi7nL1AvuTAiMIow8TFZMcAyJzKNMvMzWTO+NCM0iDTsNVA1szYXNno23TdAN6I4BThnOMo5LDmOOfE6Uzq1Oxg7ejvdPEA8oz0GPWo9zj4yPpY++z9gP8ZALECSQPlBYEHIQjFCmkMDQ25D2ERERLBFHUWLRflGaUbZR0pHvEgvSKJJF0mNSgNKe0r0S25L6UxlTOJNYU3gTmFO4k9lT+lQblD0UXtSAlKLUxVToFQrVLhVRVXTVmNW8leDWBVYp1k6Wc5aY1r4W45cJFy8XVRd7F6FXx9fumBVYPBhjGIoYsVjY2QBZJ9lPmXdZn1nHWe9aF5o/2mgakFq42uFbChsym1tbhBus29Wb/lwnXFBceRyiHMsc9B0dA=="
            )
        ),
        Np3FilterPreset(
            id: "2d32524b88137c650aa818556159a3fdacb21d1e317d532fe76b1427d0376926",
            catalogKey: "8cb0fba31ff25f7434d7f1c753f5d3e1e1ed41784539770a6ec4adc6bdd0bad3",
            legacyID: "setouchi_blue", name: "濑户蓝", fallbackName: "Setouchi Blue",
            parameters: Np3FilterParameters(
                highlights: -35,
                whites: 9,
                saturation: -13,
                colorMixerBase64: "gICAgICAgICAgICAgICAgICAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "8874654165387b2eb7e3b241be6ca119ca8c9b0c1f91646d5dc3c6730ee319a1",
            catalogKey: "b2d9b01ed879a45eec531d0228fb02a850ad7b823a2860214b95404ced6da01a",
            legacyID: "sky_mist", name: "天空薄雾", fallbackName: "Sky Mist",
            parameters: Np3FilterParameters(
                saturation: 5,
                colorMixerBase64: "gHmAh26rgF13jFI6gICAVodugICAk1+J",
                toneCurveBase64: "CzMLMwszCzMLMwtEC1YLaAt6C4wLnguxC8ML1wvqC/4MEwwoDD0MVAxrDIIMmwy0DM4M6A0EDSENPw1dDX0Nng3ADeQOCA4uDlUOfg6oDtQPAQ8wD2APkg/GD/sQMhBsEKYQ4xEiEWMRphHrEjISexLHExQTZBO2FAkUXxS2FRAVaxXIFicWhxbpF00XshgZGIIY6xlXGcMaMRqgGxAbghv1HGkc3h1UHcoeQh67HzUfryArIKchIyGhIh8inSMcI5wkHCScJR0lniYfJqEnIyelKCcoqSkrKa0qLyqxKzMrtSw2LLgtOS25LjkuuS84L7cwNTCzMTExrjIqMqczIzOeNBo0lTUQNYo2BTZ/Nvk3czftOGc44TlbOdQ6TjrIO0I7uzw1PK89KT2kPh4+mT8UP49ACkCGQQJBfkH7QnhC9UNzQ/FEcETvRW9F70ZwRvFHc0f1SHlI/EmBSgZKjEsTS5pMIkyrTTVNv05LTtdPZU/zUIJRElGjUjZSyVNdU/FUh1UeVbVWTVbmV4BYG1i3WVNZ8FqOWyxbzFxsXQxdrl5QXvJflmA6YN5hg2IpYs9jdmQdZMVlbmYXZsBnamgUaL9pamoWasJrbmwbbMhtdm4jbtJvgHAvcN5xjXI8cuxznHRMdP11rXZedw93wHhxeSJ51HqFezd76HyafUt9/Q=="
            )
        ),
        Np3FilterPreset(
            id: "d86b7309d531e178dfcb6fdf37045da23294f17c6f8a38ec414de049c91401d7",
            catalogKey: "b93eade0b6468c28d94659a92601752151a6150cb648d5edb6cbfa1eba059754",
            legacyID: "soft_film", name: "轻柔胶片", fallbackName: "Soft Film",
            parameters: Np3FilterParameters(
                contrast: -38,
                highlights: -64,
                shadows: 52,
                whites: -33,
                blacks: -40,
                saturation: -10,
                colorMixerBase64: "gICAgICAgICAgICAgICAgICAgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "4a9fb71aefd13f78b5c76ed36b1299b163c7fbd3f429923860f451ca4e474d52",
            catalogKey: "386409e289a1665487902351685a45eb17d5f283aec88339f7227d2c26917526",
            legacyID: "soft_glow", name: "柔光", fallbackName: "Soft Glow",
            parameters: Np3FilterParameters(
                saturation: 3,
                colorMixerBase64: "gIWDgYR2an2AW4xpgICAgICAgICAi4CA",
                toneCurveBase64: "AAAAbgDdAUsBugIoApYDBQN0A+IEUQTABS8FnwYOBn4G7QddB80IPgiuCR8JkAoBCnMK5AtWC8kMOwyuDSINlQ4JDn4O8g9nD90QUxDJEUARtxIvEqcTIBOZFBIUjRUHFYIV/hZ6FvcXdRfzGHEY8BlvGe8acBrxG3Ib9Bx3HPodfR4BHoUfCh+PIBQgmiEgIaciLiK2Iz0jxiROJNclYCXqJnQm/ieIKBMonikpKbUqQSrNK1kr5ixzLQAtjS4bLqkvNy/FMFMw4jFwMf8yjjMdM600PDTMNVs16zZ7Nws3mzgrOLs5SznbOmw6/DuMPB08rT0+Pc4+Xz7vP39AEECgQTBBwEJQQuBDcEQARJBFIEWvRj9GzkddR+xIe0kKSZlKJ0q1S0NL0UxfTOxNeU4GTpNPIE+sUDhQxFFPUdpSZVLwU3pUBFSOVRdVoFYpVrFXOVfBWEhYz1lVWdtaYVrmW2tb71xzXPddel39Xn9fAF+CYAJgg2ECYYJiAGJ/Yv1jemP3ZHRk8GVrZedmYWbcZ1Zn0GhJaMJpOmmzaipqomsZa5BsB2x9bPNtaG3dblJux288b7BwJHCXcQtxfnHxcmRy1nNJc7t0LXSedRB1gXXydmN21HdFd7V4JniWeQZ5dnnmelZ6xns2e6V8FXyEfPR9Y33TfkJ+sX8hf5B//w=="
            )
        ),
        Np3FilterPreset(
            id: "abfc5c299eb848856499192cef7f839821000e4abb8829b6f020e048727688a8",
            catalogKey: "1b0b37b884574266b7fbb2cf3565a7011da48551a80e1146fdded0ddc11335fb",
            legacyID: "cool_sun_kiss", name: "冷调日吻", fallbackName: "Cool Sun Kiss",
            parameters: Np3FilterParameters(
                contrast: -10,
                highlights: -76,
                shadows: -79,
                whites: -83,
                blacks: 17,
                colorMixerBase64: "ioCAZYCAdXCAcmaAhI6AgJ6AgGp0gICA"
            )
        ),
        Np3FilterPreset(
            id: "4e306b38eaa4ecf3231af3245e67ee2d757428a25cc0a086a0cd6785fb75a0c0",
            catalogKey: "f7575f53f0b0d86f98dda815ba8d04a81baebfec34444aed2fc3ce33f3ad1739",
            legacyID: "warm_sun_kiss", name: "暖阳亲吻", fallbackName: "Warm Sun Kiss",
            parameters: Np3FilterParameters(
                contrast: -10,
                highlights: -76,
                shadows: -79,
                whites: -83,
                blacks: -18,
                colorMixerBase64: "ioCAZYCAdXCAcmaAhI6AgJ6AgGp0gICA"
            )
        ),
        Np3FilterPreset(
            id: "fd2c5ba404398127ab9520b4fe1a2ba0d4f9bc2f87a9be5b95745fae37a11a3e",
            catalogKey: "bd2cf970979bfdf15f125ef46fd0ff233fd576029d41effdeec4708af1e083bd",
            legacyID: "sunset_film", name: "落日胶片", fallbackName: "Sunset Film",
            parameters: Np3FilterParameters(
                contrast: 50,
                shadows: 45,
                whites: 5,
                blacks: -20,
                saturation: -25,
                colorMixerBase64: "gIGPiIiUbICPgICAgDQ2gB8cgICAgICA"
            )
        ),
        Np3FilterPreset(
            id: "82aed616e1cc841e6faaaa5061e2b2fa6ff1587e1fe133bb5d5f0e25233ae23d",
            catalogKey: "877a7c1d0051c3cf06eef1ebe66e2d33da87bd628d999f68eb9036f20a343e3d",
            legacyID: "sunset_glow", name: "夕照柔光", fallbackName: "Sunset Glow",
            parameters: Np3FilterParameters(
                colorMixerBase64: "mYpshaiVbGyeYmxYYmKAYmeUwU6AnliK",
                toneCurveBase64: "B4cHowe/B9sH9wgTCC8ITAhpCIYIpAjDCOIJAQkhCUIJZAmGCakJzgnzChkKQApoCpIKvAroCxULQwtzC6UL1wwMDEIMeQyyDO0NKg1pDakN6w4wDnYOvw8JD1YPpQ/3EEoQoBD4EVIRrhINEm4S0RM3E54UCBR1FOQVVRXIFj4WthcwF60YLBiuGTIZuBpBGswbWhvqHHwdER2pHkMe3x9+IB8gwyFpIhIiviNsJBwkzyWFJjwm9yezKHEpMin0KrgrfSxFLQ0t1y6iL24wPDEKMdkyqDN5NEk1GjXsNr03jzhhOTI6AzrUO6Q8dD1DPhI+3z+sQHdBQUIKQtJDmERdRSBF4kajR2JIIEjdSZhKUksKS8FMd00rTd5Oj09AT+5Qm1FHUfJSm1NDU+lUjlUxVdNWdFcTV7BYTVjoWYFaGVqvW0Vb2FxqXPtdil4YXqVfMF+5YEFgyGFNYdFiU2LVY1Vj02RQZM1lR2XBZjlmsGcmZ5toD2iBaPJpY2nSakBqrWsZa4Rr7mxXbL9tJm2MbfFuVW64bxtvfG/dcD1wnHD7cVhxtXIRcmxyx3Mhc3pz03QrdIJ02XUvdYR12XYudoJ21Xcod3t3zHgeeG94wHkQeWB5r3n/ek56nHrqezh7hnvTfCF8bny6fQd9VH2gfex+OH6EftB/HH9of7N//w=="
            )
        ),
        Np3FilterPreset(
            id: "0bdf6b54bedf0a5a2d9603e05de06d4b688ef29201e91dec31b514be130dfebb",
            catalogKey: "1b4e7591203a4326dc91835945553aee5df39094c16565467b97628ecec0a33b",
            legacyID: "teal_and_orange", name: "青橙电影", fallbackName: "Teal and Orange",
            parameters: Np3FilterParameters(
                contrast: 25,
                highlights: 10,
                shadows: -25,
                whites: 4,
                colorMixerBase64: "jZmed62AgIiAgICAgMaAU6OUgICArYCA"
            )
        ),
        Np3FilterPreset(
            id: "50595b5eb80e05a9e2d5d101d0c77b68e5be7bda3392e627d27380a5f7fe8078",
            catalogKey: "4a4665eca8d71848bc09c1279e8e7412e4c16c3076b4d5aa09608cebfba00e33",
            legacyID: "gentle_clarity", name: "清柔", fallbackName: "Gentle Clarity",
            parameters: Np3FilterParameters(
                saturation: 15,
                colorMixerBase64: "jnaDjIWNeHuKjXaSgICAbImHkn2EkYCD",
                toneCurveBase64: "BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBCsEYQSdBN0FIQVoBbEF/QZLBpsG7gdCB5gH8QhLCKcJBglmCcgKLAqTCvsLZQvSDEEMsg0lDZoOEg6LDwcPhhAGEIkRDhGVEh8SqxM5E8oUXRTyFYoWJRbCF2EYAxioGU8Z+RqlG1UcBhy7HXIeLB7pH6ggayEwIfciwSONJFwlLCX+JtInpyh+KVYqLysJK+Qsvy2bLngvVDAxMQ4x6zLHM6M0fjVZNjI3CzfiOLk5jTpgOzI8ATzPPZo+ZD8qP+5AsEFuQipC40OZRExE/EWpRlRG/EeiSEVI5kmESh9KuEtPS+NMdU0FTZNOH06oTy9PtVA4ULlROVG2UjJSrFMkU5tUD1SDVPRVZFXTVkBWrFcWV39X51hNWLNZF1l6WdxaPVqdWvtbWlu3XBNcb1zJXSNdfV3WXi5ehl7dXzNfiV/fYDRgiWDeYTJhhWHZYixifmLRYyNjdGPGZBdkaWS6ZQplW2WsZfxmTGadZu1nPWeNZ95oLmh+aM9pH2lwacFqEWpiarRrBWtXa6lr+2xNbKBs821HbZtt725Dbphu7W9Db5lv73BFcJxw83FLcaJx+nJScqtzBHNcc7Z0D3RpdMN1HXV3ddJ2LHaHduJ3PneZd/V4UHiseQh5ZHnBeh16eg=="
            )
        ),
        Np3FilterPreset(
            id: "417e4f7cc6dbe52afd7423b894adf0e1149d701f47f85c7227c0424b2080aa44",
            catalogKey: "b125d4cf8ad4ad26580b9e1f1cdde75dd90c878f33aac9bc575b409bf05e7b72",
            legacyID: "turquoise_blue", name: "松石蓝", fallbackName: "Turquoise Blue",
            parameters: Np3FilterParameters(
                saturation: 5,
                colorMixerBase64: "gHt3gHuAinuAgHaAgICAYoCAgGxidnZh",
                toneCurveBase64: "B4cHhwejB78H2gf2CBMILwhMCGoIiAinCMYI5wkICSoJTQlxCZYJvQnlCg4KOQplCpIKwgrzCyULWguRC8kMBAxBDIAMwQ0FDUsNlA3fDi0OfQ7RDycPgA/cEDsQnRECEWoR1BJCErITJBOZFBAUihUHFYUWBhaJFw8XlhgfGKsZOBnIGlka7BuBHBccrx1JHeQegR8fH74gXyEBIaUiSSLvI5UkPSTlJY8mOSbkJ5AoPCjpKZcqRSr0K6IsUi0BLbEuYS8QL8AwcDEgMdAygDMvM940jDU7Neg2ljdCN+44mjlEOe46lzs/O+Y8jD0xPdU+dz8YP7hAV0D0QZBCKkLDQ1pD8ESERRhFqUY6RslHV0fkSG9I+UmCSgpKkUsXS5xMIEyiTSRNpU4lTqRPIk+gUBxQmFETUY1SB1J/UvhTb1PmVF1U01VIVb1WMValVxlXjFf+WHFY41lVWcZaOFqpWxpbi1v7XGxc3V1NXb1eLl6eXw9fgF/wYGFg0mFEYbViJ2KZYwtjfmPxZGRk12VLZcBmNGapZx5nlGgKaIBo9mltaeNqW2rSa0prwWw6bLJtK22jbhxulm8Pb4lwA3B9cPdxcXHscmdy4XNcc9h0U3TOdUp1xnZCdr53One2eDJ4rnkread6JHqhex17mnwXfJR9EX2Ofgt+iH8Ff4J//w=="
            )
        ),
        Np3FilterPreset(
            id: "1c85b1478cd2e00f07ddce17e8f832419d2e903ac2cdbe807d431a5821b0c828",
            catalogKey: "a9888e7ba4dafdee202cda8dcb3fedaabc85cafa65f2f888fa7ecc820fbdea6c",
            legacyID: "vintage_color", name: "旧日色彩", fallbackName: "Vintage Color",
            parameters: Np3FilterParameters(
                saturation: 13,
                colorMixerBase64: "gICAgICAgICAgG2AdYCAdoCAgICAgICA",
                toneCurveBase64: "BwcHIQc7B1YHcAeKB6UHwAfbB/YIEggtCEkIZgiDCKAIvQjbCPoJGQk5CVkJeQmbCb0J4AoDCicKTApyCpgKwAroCxELOwtmC5ILwAvuDB0MTQx/DLEM5Q0aDVENiA3BDfsONw50DrIO8g80D3YPuxABEEgQkRDcESkRdxHHEhgSbBLBExgTcBPLFCcUhBTjFUQVphYKFm8W1hc+F6gYExh/GO0ZXBnNGj8ashsmG5wcExyLHQQdfx36Hnce9R90H/QgdSD3IXoh/SKCIwgjjyQWJJ8lKCWyJj0mySdVJ+IocCj+KY4qHSquKz8r0CxiLPUtiC4cLrAvRS/ZMG8xBTGbMjEyyDNfM/Y0jjUlNb02VTbuN4Y4Hzi3OVA56TqBOxo7szxMPOQ9fT4VPq0/Rj/eQHVBDUGkQjtC0kNpQ/9ElUUqRb9GVEboR3xID0iiSTRJxkpXSuhLeEwHTJZNJU2yTkBOzU9ZT+RQcFD6UYVSDlKXUyBTqFQwVLhVP1XFVktW0VdWV9tYX1jjWWZZ6lpsWu9bcVvyXHRc9V11XfZedl71X3Vf9GByYPFhb2HtYmpi6GNlY+FkXmTaZVZl0mZOZslnRGe/aDpotWkvaalqI2qdaxdrkWwKbIRs/W12be9uaG7hb1lv0nBKcMNxO3GzcixypHMcc5R0DHSEdPx1dQ=="
            )
        ),
        Np3FilterPreset(
            id: "07e8d5426fd04d27680d2b2226eba9687c23ecfb2c59e0bc2592ea17eda942f9",
            catalogKey: "80d9bd7f210f3f55480b4fbb928763b94c3c26a4364ff20d896ab37d75c1cce3",
            legacyID: "vintage_vibe", name: "复古活力", fallbackName: "Vintage Vibe",
            parameters: Np3FilterParameters(
                contrast: 50,
                highlights: -21,
                shadows: -15,
                whites: 29,
                blacks: -7,
                saturation: 20,
                colorMixerBase64: "hW9xhHBnbmeAgW2AlzGAfIBqmWeAZ2eA"
            )
        ),
        Np3FilterPreset(
            id: "56370ca816dea661e56477b6df4a4f3d01375340c9d64e04881999145b9a7dc3",
            catalogKey: "980ff2d2de250f347009d61079be1ee889bb3b925e49b0b35c5e9aa143ab14c1",
            legacyID: "vital_film", name: "鲜活胶片", fallbackName: "Vital Film",
            parameters: Np3FilterParameters(
                contrast: -4,
                highlights: 54,
                shadows: -17,
                blacks: -3,
                colorMixerBase64: "eIh6hYmCc2p31VRLsaVrYqtZfI6Ah491"
            )
        ),
        Np3FilterPreset(
            id: "8d861e5b7860d2067c83bef88f83fc35c01a084eb8d63a8110e15ed79621fc2e",
            catalogKey: "5dcf969ef130443ea2fae42027db15800eb2c58d96b4ce8ca2cf69bda6c26429",
            legacyID: "warm_street", name: "暖街", fallbackName: "Warm Street",
            parameters: Np3FilterParameters(
                contrast: 36,
                highlights: -51,
                shadows: 64,
                whites: 33,
                blacks: -10,
                saturation: 7,
                colorMixerBase64: "kJq2ebyXUbuMgaGbu0+Afn2AOFNvgICA"
            )
        ),
        Np3FilterPreset(
            id: "327960a47cc9b3a437ac977a98947683fb8ee7ce54899dc735e47a77bc96d6ac",
            catalogKey: "3b3a55d016485725f311dbc20eb9417606362186143559c4814ab376469efb81",
            legacyID: "warm_lowlight", name: "暖夜微光", fallbackName: "Warm Lowlight",
            parameters: Np3FilterParameters(
                contrast: 5,
                highlights: 30,
                shadows: 10,
                whites: 25,
                saturation: 15,
                colorMixerBase64: "gICAgICAgICAmYCAioCAj4CAioCAgICA"
            )
        ),
        Np3FilterPreset(
            id: "6006680426e79b96114fe05a3dacc349b214f9af64f51a819c7de3ebb0deeed0",
            catalogKey: "c3ed7d80ab4b91f56b32f591454c0298c332cf4eaf8dea2b4b4e415e9153d5a7",
            legacyID: "warm_portrait", name: "暖调人像", fallbackName: "Warm Portrait",
            parameters: Np3FilterParameters(
                saturation: 8,
                colorMixerBase64: "gICAgICAgICAhXaAgICAgICAgICAgICQ",
                toneCurveBase64: "AAAAZwDPATYBngIGAm0C1QM9A6UEDgR2BN8FSAWxBhsGhAbvB1kHxAgvCJsJBwlzCeAKTQq7CykLmAwIDHgM6A1aDcwOPg6xDyUPmhAPEIUQ/BF0EewSZRLfE1oT1hRTFNEVTxXPFlAW0RdUF9gYXBjiGWkZ8Rp6GwUbkBwdHKsdOh3KHloe7B9/IBMgqCE9IdQiayMDI5wkNiTRJWwmCCakJ0En3yh+KRwpvCpcKvwrnSw/LOEtgy4lLsgvazAPMLIxVjH6Mp8zQzPoNI01MTXWNns3IDfFOGk5DjmzOlc6/DugPEQ85z2LPi4+0T90QBZAuEFZQfpCm0M7Q9tEekUZRbdGVUbyR49IK0jHSWJJ/UqXSzBLyUxhTPlNkE4mTrxPUU/lUHlRC1GdUi9Sv1NPU95UbFT6VYZWEladVydXsFg4WL9ZRVnLWk9a01tWW9dcWFzXXVZd015QXstfRl+/YDdgrmEkYZliDGJ/YvBjYGPPZD1kqWUUZX5l52ZOZrVnGWd9Z99oQGifaP1pWmm1ag9qaGrAaxZra2u/bBFsY2yzbQJtUG2dbeluNG5+bsdvD29Wb51v4nAncGpwrXDvcTFxcXGxcfFyL3Jucqty6HMkc2Bzm3PWdBB0SnSEdL109XUudWZ1nnXVdg12RHZ6drF26Hced1V3i3fBd/d39w=="
            )
        ),
        Np3FilterPreset(
            id: "cda442a8526dc994ab1051783744f12b5806c3932a800161befb4dfe393d5288",
            catalogKey: "5039ec776c133ceeab61fbd3f7ec62b8df454ec42817cdba880c4f375d4abc22",
            legacyID: "honey_warm", name: "蜜糖暖调", fallbackName: "Honey Warm",
            parameters: Np3FilterParameters(
                contrast: 29,
                highlights: -22,
                shadows: 14,
                whites: 22,
                saturation: 20,
                colorMixerBase64: "eqWQg4mTUptggICAgICAgICAgICAgICA"
            )
        ),
    ]
}
