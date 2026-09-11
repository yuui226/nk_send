import unittest
from check_shared_ui_migration import expected_shared, expected_android_haptics, RESOURCE_ENUM, SHARED_ENUM


class SharedUiMigrationGuardTest(unittest.TestCase):
    def test_only_known_visibility_changes_are_allowed(self):
        self.assertEqual(expected_shared("internal fun test() = 180f\n", "screen/TransferProgressMotion.kt"),
                         "fun test() = 180f\n")
        self.assertEqual(expected_shared("internal fun test() = 180f\n", "theme/Motion.kt"),
                         "internal fun test() = 180f\n")

    def test_enum_removes_only_android_resource_binding(self):
        self.assertEqual(expected_shared("import com.ztransfer.R\n" + RESOURCE_ENUM + "\n}\n", "theme/Color.kt"),
                         SHARED_ENUM + "\n}\n")

    def test_unknown_baseline_requires_review(self):
        with self.assertRaises(ValueError):
            expected_shared("enum class SkinPreset { NEW_STYLE }", "theme/Color.kt")

    def test_numeric_and_geometry_changes_are_not_normalized_away(self):
        self.assertNotEqual(expected_shared("val x = 0.13f", "screen/ZMark.kt"), "val x = 0.14f")

    def test_texture_platform_replacement_preserves_algorithm_parameters(self):
        source = "val x = Math.floorMod(seed, 24)\nval alpha = 0.21f\nsynchronized(tileCacheLock) { tileCache[key] = tile }"
        self.assertEqual(expected_shared(source, "theme/SkinTexture.kt"),
            "val x = textureFloorMod(seed, 24)\nval alpha = 0.21f\ntileCacheLock.withLock { tileCache[key] = tile }")
        self.assertNotEqual(expected_shared(source, "theme/SkinTexture.kt"), source.replace("0.21f", "0.22f"))

    def test_material_visibility_does_not_rewrite_private_helpers(self):
        source = "internal data class Palette(val x: Int)\nprivate fun draw() = 0.12f\ninternal const val RIM = 1.8f"
        self.assertEqual(expected_shared(source, "screen/ConnectionCardMaterial.kt"),
                         "data class Palette(val x: Int)\nprivate fun draw() = 0.12f\nconst val RIM = 1.8f")

    def test_haptics_keeps_enabled_gate_and_failure_timing(self):
        source = "    fun tick() { if (enabled) feedback(65L) }\n\nconst val PROGRESSIVE_HOLD_HAPTIC_DURATION_MS = 800\n"
        self.assertEqual(expected_android_haptics(source), "    override fun tick() { if (enabled) feedback(65L) }\n")
        self.assertNotEqual(expected_android_haptics(source), "    override fun tick() { feedback(50L) }\n")
