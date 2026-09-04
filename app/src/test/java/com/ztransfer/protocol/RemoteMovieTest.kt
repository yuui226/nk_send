package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteMovieTest {
    @Test
    fun diagnosticDistinguishesPreparationFailureFromStartResponse() {
        val diagnostic = RcMovieStartResult(
            responseCode = PtpConstants.OPERATION_NOT_SUPPORTED,
            prohibitCondition = (1L shl 14) or (1L shl 18),
            prohibitExtendedResponse = PtpConstants.OPERATION_NOT_SUPPORTED,
            applicationModeResponse = PtpConstants.OPERATION_NOT_SUPPORTED,
            applicationModePropertyResponse = 0x200A,
            startCommandResponse = null,
        ).diagnosticSummary()

        assertEquals(
            "result=0x2005 startOp=not-sent prohibit=0x00044000 " +
                "preEx=0x2005 appOp=0x2005 appProp=0x200A",
            diagnostic
        )
    }
}
