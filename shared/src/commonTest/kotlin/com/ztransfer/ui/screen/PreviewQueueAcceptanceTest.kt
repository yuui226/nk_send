package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.*
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.test.*

class PreviewQueueAcceptanceTest {
    private val files = listOf(CameraFileInfo(1, 12, "A.JPG", null, false), CameraFileInfo(2, 13, "B.JPG", null, false))
    private class Fixture {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val gate = PreviewQueueAcceptance()
        var current = true
        var flights = 0
        var calls = 0
        val results = mutableListOf<CancellableContinuation<Int>>()
        suspend fun enqueue(files: List<CameraFileInfo>): Int {
            check(files.isNotEmpty())
            calls++
            return suspendCancellableCoroutine { results += it }
        }
        fun request(files: List<CameraFileInfo>) = gate.request(scope, files, { current }, ::enqueue) { flights++ }
        fun close() { gate.close(); scope.cancel() }
    }

    @Test fun waitingForRealAcceptanceNeverStartsFlightAndDuplicateTapDoesNotEnqueueAgain() {
        val f = Fixture()
        assertTrue(f.request(files)); assertFalse(f.request(files)); assertEquals(1, f.calls)
        assertEquals(0, f.flights)
        f.results.single().resume(2)
        assertEquals(1, f.flights)
        assertTrue(f.request(files)); assertEquals(2, f.calls)
        f.close()
    }

    @Test fun partialRejectedNegativeAndOversizedCountsCannotAnimateTheEntireGroup() {
        val f = Fixture()
        for (count in listOf(-1, 0, 1, 3, Int.MAX_VALUE)) {
            assertTrue(f.request(files)); f.results.last().resume(count)
            assertEquals(0, f.flights)
        }
        f.close()
    }

    @Test fun cancellationReleasesTheGateAndLateOldReplyCannotCompleteTheNewRequest() {
        val f = Fixture()
        f.request(files); f.gate.cancel(); assertTrue(f.results.first().isCancelled)
        assertTrue(f.request(files))
        f.results.first().resume(2); assertEquals(0, f.flights)
        f.results.last().resume(2); assertEquals(1, f.flights)
        f.close()
    }

    @Test fun closingAndParentScopeCancellationRejectNewOrLateRequests() {
        for (closeGate in listOf(true, false)) {
            val f = Fixture(); f.request(files)
            if (closeGate) f.gate.close() else f.scope.cancel()
            f.results.single().resume(2)
            assertEquals(0, f.flights); assertFalse(f.request(files))
            f.close()
        }
    }

    @Test fun pageAndClosingPredicateIsCheckedBeforeIoAndAfterAcknowledgement() {
        val f = Fixture(); f.current = false
        assertFalse(f.request(files)); assertEquals(0, f.calls)
        f.current = true; f.request(files); f.current = false
        f.results.single().resume(2); assertEquals(0, f.flights)
        f.close()
    }

    @Test fun synchronousCompletionDoesNotLeaveACompletedJobBlockingTheNextRequest() {
        val f = Fixture()
        repeat(3) {
            assertTrue(f.gate.request(f.scope, files, { true }, { it.size }) { f.flights++ })
        }
        assertEquals(3, f.flights); f.close()
    }

    @Test fun callerMutationCannotChangeTheAwaitedGroupOrItsRequiredAcceptanceCount() {
        val f = Fixture(); val input = files.toMutableList()
        var captured: List<CameraFileInfo>? = null
        val response = CompletableDeferred<Int>()
        f.gate.request(f.scope, input, { true }, { captured = it; response.await() }) { f.flights++ }
        input.clear(); assertEquals(files, captured)
        response.complete(1); assertEquals(0, f.flights)
        assertFalse(f.request(emptyList())); f.close()
    }

    @Test fun failureOrCancellationFromAdmissionCannotLeakTheBusyGate() {
        val f = Fixture()
        assertTrue(f.gate.request(f.scope, files, { true }, { throw IllegalStateException("rejected") }) { f.flights++ })
        assertTrue(f.gate.request(f.scope, files, { true }, { throw CancellationException("closed") }) { f.flights++ })
        assertEquals(0, f.flights)
        assertTrue(f.request(files)); f.close()
    }

    @Test fun evenANonCancellableLateProducerCannotClearOrAnimateANewerRequest() {
        val f = Fixture()
        var reply: kotlin.coroutines.Continuation<Int>? = null
        f.gate.request(f.scope, files, { true }, { suspendCoroutine { reply = it } }) { f.flights++ }
        f.gate.cancel(); assertTrue(f.request(files))
        reply!!.resume(2)
        assertEquals(0, f.flights); assertFalse(f.request(files))
        f.results.single().resume(2); assertEquals(1, f.flights)
        f.close()
    }
}
