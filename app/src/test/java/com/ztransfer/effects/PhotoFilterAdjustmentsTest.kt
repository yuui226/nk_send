package com.ztransfer.effects

import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.PhotoNp3Parser
import com.ztransfer.filter.photoFilterCatalogKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFilterAdjustmentsTest {
    @Test fun oldPreferencesAndUneditedFiltersRemainNeutral() {
        assertTrue(decodePhotoFilterAdjustments(null, emptySet()).isEmpty())
        assertTrue(decodePhotoFilterAdjustments("", emptySet()).isEmpty())
        assertEquals(LutAdjustments(), photoFilterAdjustmentsFor(null, emptyMap()))
        assertEquals(LutAdjustments(), photoFilterAdjustmentsFor(BuiltInPhotoFilters.all.first().id, emptyMap()))
    }

    @Test fun everyControlAndBoundarySurvivesDeterministicRoundTrip() {
        val a = "np3:${"a".repeat(64)}"
        val b = "np3:${"b".repeat(64)}"
        val values = linkedMapOf(b to LutAdjustments(-100, 100, -100, 100),
            "builtin" to LutAdjustments(17, -22, 38, -49), a to LutAdjustments())
        val encoded = encodePhotoFilterAdjustments(values)
        assertEquals(encoded, encodePhotoFilterAdjustments(values.toList().reversed().toMap()))
        assertEquals(values, decodePhotoFilterAdjustments(encoded, setOf("builtin")))
    }

    @Test fun malformedEntriesCannotDestroyValidMemoriesOrThrow() {
        val custom = "np3:${"c".repeat(64)}"
        val encoded = "missing,1,2,3,4;np3:bad,1,2,3,4;bad/key,1,2,3,4;" +
            "forest,no,1,2,3;forest,200,-200,11,-12;forest,1,2,3,4;" +
            "$custom,1,2,3;${custom},4,3,2,1;trailing,1,2,3,4,5"
        assertEquals(mapOf("forest" to LutAdjustments(100, -100, 11, -12),
            custom to LutAdjustments(4, 3, 2, 1)), decodePhotoFilterAdjustments(encoded, setOf("forest")))
    }

    @Test fun converterRevisionDoesNotChangeThePresetMemoryKey() {
        val builtin = BuiltInPhotoFilters.all.first()
        val builtinKey = checkNotNull(photoFilterCatalogKey(builtin.id))
        val customKey = "np3:${"d".repeat(64)}"
        val first = LutAdjustments(12, -34, 56, -78)
        val second = LutAdjustments(-11, 22, -33, 44)
        val values = mapOf(builtinKey to first, customKey to second)
        assertEquals(first, photoFilterAdjustmentsFor(builtin.id, values))
        assertEquals(second, photoFilterAdjustmentsFor("$customKey:${PhotoNp3Parser.CONVERTER_VERSION}", values))
        assertEquals(second, photoFilterAdjustmentsFor("$customKey:${PhotoNp3Parser.CLASSIC_CONVERTER_VERSION}", values))
    }

    @Test fun detachedCustomMemorySurvivesButRemovedBuiltInsDoNot() {
        val key = "np3:${"e".repeat(64)}"
        val value = LutAdjustments(1, 2, 3, 4)
        assertEquals(mapOf(key to value), normalizePhotoFilterAdjustments(
            mapOf(key to value, "missing" to value, "np3:bad" to value), emptySet(),
        ))
    }

    @Test fun rememberingAnotherDraftDoesNotMutateAnAppliedSnapshot() {
        val committed = mapOf("forest" to LutAdjustments(11, 22, 33, 44))
        val appliedEncoded = encodePhotoFilterAdjustments(committed)
        val draft = committed + ("forest" to LutAdjustments(-10, -20, -30, -40))
        assertEquals(committed, decodePhotoFilterAdjustments(appliedEncoded, setOf("forest")))
        assertEquals(draft, decodePhotoFilterAdjustments(encodePhotoFilterAdjustments(draft), setOf("forest")))
    }
}
