package com.ztransfer.ui.screen

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class RemoteToolLayoutTest {
    @Test
    fun newInstallPlacesPresetSixthInBothModes() {
        val prefs = preferences()
        for (movie in listOf(false, true)) {
            val layout = RemoteToolLayout(prefs, movie) {}
            assertEquals(RemoteTool.PICTURE_CONTROL, layout.shownTools[5])
            assertEquals(layout.available.filterNot { it == RemoteTool.PICTURE_CONTROL },
                layout.order.filterNot { it == RemoteTool.PICTURE_CONTROL })
        }
    }

    @Test
    fun upgradeInsertsAmongVisibleToolsAndKeepsOtherOrderAndHiddenChoices() {
        val preset = RemoteTool.PICTURE_CONTROL
        val saved = RemoteTool.regular.filter { it.availableIn(false) }.reversed()
        val hidden = setOf(preset.id, RemoteTool.FPS.id, RemoteTool.HISTOGRAM.id)
        val prefs = preferences(mutableMapOf(
            "remote_tool_order_photo" to saved.joinToString(",") { it.id },
            "remote_hidden_tools_photo" to hidden,
        ))
        val layout = RemoteToolLayout(prefs, false) { fail("Migration must not toggle a tool") }
        assertEquals(preset, layout.shownTools[5])
        assertEquals(saved.filterNot { it == preset }, layout.order.filterNot { it == preset })
        assertEquals(hidden - preset.id, layout.hiddenTools.map { it.id }.toSet())
        assertEquals(layout.order, RemoteToolLayout(prefs, false) {}.order)
    }

    @Test
    fun manualMovesAndHidingAfterMigrationSurviveReopening() {
        val prefs = preferences()
        var layout = RemoteToolLayout(prefs, false) {}
        layout.move(RemoteTool.PICTURE_CONTROL, 1)
        layout = RemoteToolLayout(prefs, false) {}
        assertEquals(RemoteTool.PICTURE_CONTROL, layout.shownTools[1])
        layout.setVisible(RemoteTool.PICTURE_CONTROL, false)
        val order = layout.order
        val reopened = RemoteToolLayout(prefs, false) {}
        assertFalse(reopened.visible(RemoteTool.PICTURE_CONTROL))
        assertEquals(order, reopened.order)
        // Migrating the other mode must not reset the first mode's choices.
        assertEquals(RemoteTool.PICTURE_CONTROL, RemoteToolLayout(prefs, true) {}.shownTools[5])
        assertEquals(order, RemoteToolLayout(prefs, false) {}.order)
        assertFalse(RemoteToolLayout(prefs, false) {}.visible(RemoteTool.PICTURE_CONTROL))
    }

    @Test
    fun fewVisibleToolsPlacePresetAtTheEndWithoutDuplicates() {
        val hidden = RemoteTool.regular.filterNot { it == RemoteTool.HD }.map { it.id }.toSet()
        val layout = RemoteToolLayout(preferences(mutableMapOf(
            "remote_hidden_tools_photo" to hidden,
        )), false) {}
        assertEquals(listOf(RemoteTool.HD, RemoteTool.PICTURE_CONTROL), layout.shownTools)
        assertEquals(layout.order.size, layout.order.distinct().size)
    }

    @Test
    fun oldHiddenAndReorderedLockBecomesFixedWithoutChangingOtherTools() {
        val prefs = preferences(mutableMapOf(
            "remote_tool_order_photo" to "grid,lock,hd,rotate,fps",
            "remote_hidden_tools_photo" to setOf("lock", "rotate", "fps"),
        ))
        val hidden = mutableListOf<RemoteTool>()
        val layout = RemoteToolLayout(prefs, false, hidden::add)
        assertEquals(listOf(RemoteTool.GRID, RemoteTool.HD, RemoteTool.FPS), layout.order.take(3))
        assertEquals(listOf(RemoteTool.FPS), layout.hiddenTools)
        val order = layout.order
        RemoteTool.pinned.forEach {
            assertTrue(layout.visible(it))
            layout.move(it, 0)
            layout.setVisible(it, false)
            assertTrue(layout.visible(it))
        }
        assertEquals(order, layout.order)
        assertTrue(hidden.isEmpty())
        layout.move(RemoteTool.HD, 0)
        val restored = RemoteToolLayout(prefs, false) {}
        assertEquals(RemoteTool.HD, restored.order.first())
        assertEquals(listOf(RemoteTool.FPS), restored.hiddenTools)
        assertTrue(RemoteTool.pinned.all(restored::visible))
    }

    @Test
    fun regularToolsStillHideRestoreAndReorderIndependentlyPerMode() {
        val prefs = preferences()
        val photo = RemoteToolLayout(prefs, false) {}
        val movie = RemoteToolLayout(prefs, true) {}
        val movieOrder = movie.order
        photo.setVisible(RemoteTool.GRID, false)
        photo.move(RemoteTool.GRID, 0)
        assertEquals(RemoteTool.GRID, photo.order.last())
        photo.setVisible(RemoteTool.GRID, true)
        assertEquals(RemoteTool.GRID, photo.shownTools.last())
        photo.move(RemoteTool.GRID, 0)
        assertEquals(RemoteTool.GRID, photo.shownTools.first())
        assertEquals(movieOrder, movie.order)
        assertFalse(photo.visible(RemoteTool.AUDIO))
        assertTrue(movie.visible(RemoteTool.AUDIO))
    }

    @Test
    fun drawerPinsBothControlsWithoutLosingOrDuplicatingOtherTools() {
        val tools = RemoteTool.regular + RemoteTool.pinned
        for (columns in 2..8) {
            val rows = monitorToolRows(tools, columns)
            assertEquals(RemoteTool.pinned, rows.first().takeLast(2))
            val flattened = rows.flatten().filterNotNull()
            assertEquals(tools.size, flattened.size)
            assertEquals(tools.toSet(), flattened.toSet())
            assertEquals(RemoteTool.regular, flattened.filterNot { it.fixed })
            assertTrue(rows.all { it.size <= columns })
        }
        assertEquals(listOf(null, RemoteTool.LOCK, RemoteTool.ROTATE),
            monitorToolRows(RemoteTool.pinned, 3).single())
        assertEquals(RemoteTool.pinned, monitorToolRows(RemoteTool.pinned, 1).single())
    }

    /** Only the preferences operations used by the layout; no Android runtime or extra dependency. */
    private fun preferences(values: MutableMap<String, Any> = mutableMapOf()): SharedPreferences {
        val editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
            arrayOf(SharedPreferences.Editor::class.java)) { self, method, args ->
            when (method.name) {
                "putString", "putStringSet", "putBoolean" -> {
                    values[args[0] as String] = args[1]
                    self
                }
                "apply" -> null
                else -> error("Unexpected editor operation: ${method.name}")
            }
        } as SharedPreferences.Editor
        return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getString", "getStringSet", "getBoolean" -> values[args[0]] ?: args[1]
                "edit" -> editor
                else -> error("Unexpected preferences operation: ${method.name}")
            }
        } as SharedPreferences
    }
}
