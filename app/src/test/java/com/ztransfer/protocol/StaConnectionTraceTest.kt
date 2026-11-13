package com.ztransfer.protocol

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StaConnectionTraceTest {
    @Test fun timestampsSeparateElapsedTimeFromPreviousStep() {
        var nanos = 1_000_000L
        val trace = StaConnectionTrace { nanos }
        trace.clear()
        nanos += 20_000_000L
        trace += "socket"
        nanos += 45_000_000L
        trace += "ack"
        assertTrue(trace.report().contains("+20ms Δ20ms socket"))
        assertTrue(trace.report().contains("+65ms Δ45ms ack"))
        trace.clear()
        nanos += 2_000_000L
        trace += "retry"
        assertTrue(trace.report().contains("+2ms Δ2ms retry"))
        assertFalse(trace.report().contains("socket"))
    }

    @Test fun eventFloodKeepsInitialHandshakeAndFinalOutcome() {
        val trace = StaConnectionTrace { 0L }
        repeat(300) { trace += "step=$it;" }
        val report = trace.report()
        assertTrue(report.contains("step=0;"))
        assertTrue(report.contains("step=299;"))
        assertFalse(report.contains("step=128;"))
        assertTrue(report.contains("中间省略 44 条"))
    }
}
