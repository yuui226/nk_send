package com.ztransfer.viewmodel

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

class RemoteActivityTrackerTest {
    @Test
    fun albumRefreshWaitsForCancelledMonitorToReleaseCameraModes() = runBlocking {
        val events = mutableListOf<String>()
        var pcMode = true
        var applicationMode = true
        val tracker = RemoteActivityTracker { active ->
            if (active) events += "pause" else {
                check(!pcMode && !applicationMode) { "Album queried while the card was hidden" }
                events += "scan"
            }
        }
        val screen = tracker.acquire()
        val reachedCleanup = CompletableDeferred<Unit>()
        val allowRelease = CompletableDeferred<Unit>()
        val session = launch(start = CoroutineStart.UNDISPATCHED) {
            tracker.acquire().use {
                try {
                    awaitCancellation()
                } finally {
                    withContext(NonCancellable) {
                        events += "EndLiveView"
                        reachedCleanup.complete(Unit)
                        allowRelease.await()
                        applicationMode = false
                        events += "ApplicationMode=0"
                        pcMode = false
                        events += "ControlMode=0"
                    }
                }
            }
        }
        // Compose disposal and coroutine cancellation do not finish at the same instant.
        screen.close()
        session.cancel()
        reachedCleanup.await()
        assertEquals(listOf("pause", "EndLiveView"), events)
        allowRelease.complete(Unit)
        session.join()
        assertEquals(listOf("pause", "EndLiveView", "ApplicationMode=0", "ControlMode=0", "scan"), events)
    }

    @Test
    fun oldCleanupCannotResumeBackgroundWorkAfterImmediateReentry() {
        val changes = mutableListOf<Boolean>()
        val tracker = RemoteActivityTracker { changes += it }
        val oldScreen = tracker.acquire()
        val oldSession = tracker.acquire()
        oldScreen.close()
        val newScreen = tracker.acquire()
        val newSession = tracker.acquire()
        oldSession.close()
        assertEquals(listOf(true), changes)
        newScreen.close()
        assertEquals(listOf(true), changes)
        newSession.close()
        assertEquals(listOf(true, false), changes)
    }

    @Test
    fun disconnectedScreenReleasesWithoutAStartedSessionAndCloseIsIdempotent() {
        val changes = mutableListOf<Boolean>()
        val tracker = RemoteActivityTracker { changes += it }
        val first = tracker.acquire()
        first.close()
        val second = tracker.acquire()
        first.close() // A stale duplicate disposal must not release the new screen.
        assertEquals(listOf(true, false, true), changes)
        second.close()
        assertEquals(listOf(true, false, true, false), changes)
    }

    @Test
    fun failedStartupReleasesOnlyItsOwnHold() {
        val changes = mutableListOf<Boolean>()
        val tracker = RemoteActivityTracker { changes += it }
        val screen = tracker.acquire()
        val failure = runCatching {
            tracker.acquire().use { error("connection lost during startup") }
        }
        assertTrue(failure.isFailure)
        assertEquals(listOf(true), changes)
        screen.close()
        assertEquals(listOf(true, false), changes)
    }
}
