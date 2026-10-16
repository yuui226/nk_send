package com.ztransfer.ui.screen

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class RemoteToolLayoutTest {
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
                "putString", "putStringSet" -> {
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
                "getString", "getStringSet" -> values[args[0]] ?: args[1]
                "edit" -> editor
                else -> error("Unexpected preferences operation: ${method.name}")
            }
        } as SharedPreferences
    }
}
