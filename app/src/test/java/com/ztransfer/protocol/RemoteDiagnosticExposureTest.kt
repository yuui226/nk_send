package com.ztransfer.protocol

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class RemoteDiagnosticExposureTest {
    private val nikon = RcParam(Lab.PROP_NK_SHUTTER, 6, true, 65736L, listOf(65736L, 65636L))
    private val standard = RcParam(Lab.PROP_EXPOSURE_TIME_STD, 6, true, 50L, listOf(50L, 100L))

    @Test
    fun normalUsersStillStopAtFirstWritableDescriptor() = runBlocking {
        val queried = mutableListOf<Int>()
        assertEquals(nikon, readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, null) {
            queried.add(it)
            nikon
        })
        assertEquals(listOf(Lab.PROP_NK_SHUTTER), queried)
    }

    @Test
    fun diagnosticQueriesBothButPreservesNormalPriority() = runBlocking {
        val queried = mutableListOf<Int>()
        assertEquals(nikon, readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, {}) {
            queried.add(it)
            if (it == nikon.prop) nikon else standard
        })
        assertEquals(listOf(nikon.prop, standard.prop), queried)
    }

    @Test
    fun secondaryDiagnosticFailureDoesNotDiscardUsableNikonShutter() = runBlocking {
        val logs = mutableListOf<String>()
        assertEquals(nikon, readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, { logs.add(it) }) {
            if (it == nikon.prop) nikon else throw IllegalStateException("descriptor failed")
        })
        assertTrue(logs.single().contains("descriptor failed"))
    }

    @Test
    fun readOnlyNikonFallsBackToWritableStandardAndLockedPairRemainsReadOnly() = runBlocking {
        assertEquals(standard, readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, {}) {
            if (it == nikon.prop) nikon.copy(writable = false) else standard
        })
        assertEquals(nikon.copy(writable = false), readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, {}) {
            if (it == nikon.prop) nikon.copy(writable = false) else standard.copy(writable = false)
        })
    }

    @Test(expected = CancellationException::class)
    fun diagnosticQueriesDoNotSwallowNavigationCancellation(): Unit = runBlocking {
        readCompatibleExposureParam(Lab.PROP_NK_SHUTTER, {}) { throw CancellationException("exit") }
        Unit
    }
}
