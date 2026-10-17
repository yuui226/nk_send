package com.ztransfer.presets

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class SerialPresetQueueTest {
    private class Fixture : AutoCloseable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val delivery = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val failures = ConcurrentLinkedQueue<Exception>()
        val queue = SerialPresetQueue(scope, delivery, scope, ::AtomicBoolean,
            { it.set(true) }, { failures.add(it) })
        override fun close() { scope.cancel(); delivery.close() }
    }

    @Test fun lutAndPictureControlRequestsAreBothKeptAndRunSerially() = runBlocking {
        Fixture().use { fixture ->
            val started = CompletableDeferred<Unit>()
            val unblock = CompletableDeferred<Unit>()
            val completed = CompletableDeferred<Unit>()
            val events = ConcurrentLinkedQueue<String>()
            fixture.queue.submit({
                events.add("lut start"); started.complete(Unit); unblock.await(); "lut"
            }) { events.add(it.getOrThrow()) }
            withTimeout(5_000) { started.await() }
            fixture.queue.submit({ events.add("np3 start"); "np3" }) {
                events.add(it.getOrThrow()); completed.complete(Unit)
            }
            assertEquals(listOf("lut start"), events.toList())
            unblock.complete(Unit)
            withTimeout(5_000) { completed.await() }
            assertEquals(listOf("lut start", "lut", "np3 start", "np3"), events.toList())
            assertTrue(fixture.failures.isEmpty())
        }
    }

    @Test fun cancellingPendingWorkDoesNotCancelAnotherFeature() = runBlocking {
        Fixture().use { fixture ->
            val started = CompletableDeferred<Unit>()
            val unblock = CompletableDeferred<Unit>()
            val completed = CompletableDeferred<String>()
            val obsoleteRan = AtomicBoolean()
            fixture.queue.submit({ started.complete(Unit); unblock.await() }) {}
            withTimeout(5_000) { started.await() }
            val obsolete = fixture.queue.submit({ obsoleteRan.set(true) }) { obsoleteRan.set(true) }
            fixture.queue.submit({ "np3" }) { completed.complete(it.getOrThrow()) }
            obsolete.cancel()
            unblock.complete(Unit)
            assertEquals("np3", withTimeout(5_000) { completed.await() })
            assertFalse(obsoleteRan.get())
        }
    }

    @Test fun lateCancelledResultReleasesItsGrantBeforeTheNextScan() = runBlocking {
        Fixture().use { fixture ->
            val acquired = CompletableDeferred<Unit>()
            val unblock = CompletableDeferred<Unit>()
            val completed = CompletableDeferred<Boolean>()
            val grantHeld = AtomicBoolean()
            val delivered = AtomicBoolean()
            val ticket = fixture.queue.submit({
                grantHeld.set(true); acquired.complete(Unit); unblock.await(); true
            }, discard = { if (it.getOrThrow()) grantHeld.set(false) }) { delivered.set(true) }
            withTimeout(5_000) { acquired.await() }
            ticket.cancel()
            fixture.queue.submit({ grantHeld.get() }) { completed.complete(it.getOrThrow()) }
            unblock.complete(Unit)
            assertFalse(withTimeout(5_000) { completed.await() })
            assertFalse(delivered.get())
        }
    }

    @Test fun deliveryAndCleanupFailuresDoNotKillTheSharedReaderOrRevokeCommittedResults() = runBlocking {
        Fixture().use { fixture ->
            val completed = CompletableDeferred<Boolean>()
            val cleaned = AtomicBoolean()
            val discarded = AtomicBoolean()
            fixture.queue.submit({ "new folder" }, discard = { discarded.set(true) }) {
                fixture.queue.cleanup { throw IllegalStateException("cleanup failed") }
                fixture.queue.cleanup { cleaned.set(true) }
                throw IllegalStateException("UI callback failed after commit")
            }
            fixture.queue.submit({ cleaned.get() }) { completed.complete(it.getOrThrow()) }
            assertTrue(withTimeout(5_000) { completed.await() })
            assertFalse(discarded.get())
            assertEquals(listOf("UI callback failed after commit", "cleanup failed"),
                fixture.failures.map { it.message })
        }
    }

    @Test fun failedDiscardDoesNotStrandAnotherRequest() = runBlocking {
        Fixture().use { fixture ->
            val started = CompletableDeferred<Unit>()
            val unblock = CompletableDeferred<Unit>()
            val completed = CompletableDeferred<String>()
            val ticket = fixture.queue.submit({ started.complete(Unit); unblock.await() },
                discard = { throw IllegalStateException("discard failed") }) {}
            withTimeout(5_000) { started.await() }
            ticket.cancel()
            fixture.queue.submit({ "next" }) { completed.complete(it.getOrThrow()) }
            unblock.complete(Unit)
            assertEquals("next", withTimeout(5_000) { completed.await() })
            assertEquals("discard failed", fixture.failures.single().message)
        }
    }

    @Test fun providerFailureIsReportedAndLaterReadsStillRun() = runBlocking {
        Fixture().use { fixture ->
            val failure = CompletableDeferred<Throwable?>()
            val completed = CompletableDeferred<String>()
            fixture.queue.submit<String>({ throw IllegalStateException("provider denied") }) {
                failure.complete(it.exceptionOrNull())
            }
            fixture.queue.submit({ "next" }) { completed.complete(it.getOrThrow()) }
            assertEquals("provider denied", withTimeout(5_000) { failure.await() }?.message)
            assertEquals("next", withTimeout(5_000) { completed.await() })
        }
    }
}
