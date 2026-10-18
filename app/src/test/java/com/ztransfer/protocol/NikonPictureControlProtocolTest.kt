package com.ztransfer.protocol

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Protocol discovery fixtures assert the complete read-only exchange sequence. */
class NikonPictureControlProtocolTest {
    private val operations = setOf(0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF, 0x940E)
    private data class Step(
        val code: Int,
        val params: List<Int>,
        val response: Pair<Int, ByteArray?> = 0x2001 to null,
        val error: Throwable? = null,
        val afterResponse: (() -> Unit)? = null,
    )

    private class ScriptedTransport(vararg steps: Step) : PictureControlTransport {
        private val expected = steps.toList()
        var exchanges = 0
            private set

        override suspend fun exchange(code: Int, params: IntArray, data: ByteArray?): Pair<Int, ByteArray?> {
            assertNull("Discovery must never send a data payload", data)
            assertTrue("Discovery must only read", code in setOf(0x90CC, 0x1014))
            assertTrue("Unexpected extra discovery command", exchanges < expected.size)
            val step = expected[exchanges++]
            assertEquals(step.code, code)
            assertEquals(step.params, params.toList())
            step.error?.let { throw it }
            step.afterResponse?.invoke()
            return step.response.first to step.response.second?.copyOf()
        }

        fun assertComplete() = assertEquals(expected.size, exchanges)
    }

    private fun zStandard(): ByteArray = javaClass.getResourceAsStream("/picture_control/z30-v3.tsv")!!
        .bufferedReader().useLines { lines ->
            val row = lines.filter { !it.startsWith('#') && it.isNotBlank() }.map { it.split('\t') }
                .single { it[1] == "90CC" && it[2] == "1,0" && it[3] == "2001" }
            row[4].chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }

    private fun v2Standard(curve: Boolean = false): ByteArray = ByteArray(if (curve) 610 else 32).also {
        it[0] = 1
        "STANDARD".toByteArray(Charsets.US_ASCII).copyInto(it, 3)
        it[27] = 12
        it[31] = if (curve) 1 else 0
        if (curve) for (offset in 32 until it.size) it[offset] = (offset * 13).toByte()
    }

    private fun movieDescriptor(): ByteArray = byteArrayOf(
        0x37, 0xD2.toByte(), 4, 0, 1, 1, 0, 1, 0, 2, 2, 0, 1, 0, 0xC9.toByte(), 0)

    private fun read3(rc: Int = 0x2001, bytes: ByteArray? = null,
                      error: Throwable? = null, afterResponse: (() -> Unit)? = null, movie: Boolean = false) =
        Step(0x90CC, listOf(1, 0, if (movie) 1 else 0), rc to bytes, error, afterResponse)
    private fun read2(rc: Int = 0x2001, bytes: ByteArray? = v2Standard(), error: Throwable? = null) =
        Step(0x90CC, listOf(1, 0), rc to bytes, error)
    private fun movieProperty(rc: Int, bytes: ByteArray? = null, error: Throwable? = null) =
        Step(0x1014, listOf(0xD237), rc to bytes, error)
    private fun discover(transport: ScriptedTransport, properties: Set<Int> = emptySet(),
                         advertised: Set<Int> = operations, session: () -> Boolean = { true },
                         log: ((String) -> Unit)? = null, movie: Boolean = false): NikonPictureControlProtocol = runBlocking {
        discoverPictureControlProtocol(advertised, properties, transport, session, movie, log)
    }

    @Test fun aNormalZResponseNeedsOnlyOneReadAndKeepsBothBanks() {
        for (properties in listOf(emptySet(), setOf(0xD237))) {
            val transport = ScriptedTransport(read3(bytes = zStandard()))
            val protocol = discover(transport, properties)
            assertEquals(NikonPictureControlFormat.CLASSIC_Z, protocol.format)
            assertTrue(protocol.supportsMovie)
            assertTrue(protocol.cacheable)
            protocol.requireMode(false)
            protocol.requireMode(true)
            transport.assertComplete()
        }
    }

    @Test fun zMovieDiscoveryReadsOnlyTheMovieBank() {
        val transport = ScriptedTransport(read3(bytes = zStandard(), movie = true))
        val protocol = discover(transport, movie = true)
        assertEquals(NikonPictureControlFormat.CLASSIC_Z, protocol.format)
        protocol.requireMode(true)
        transport.assertComplete()
    }

    @Test fun legacyMovieDiscoveryStillRequiresAnExplicitlyConfirmedSharedBank() {
        for (shared in listOf(true, false)) {
            val transport = ScriptedTransport(read3(rc = 0x201D, movie = true), read2(),
                movieProperty(if (shared) 0x200A else 0x2001, if (shared) null else movieDescriptor()))
            val protocol = discover(transport, movie = true)
            assertEquals(NikonPictureControlFormat.LEGACY_V2, protocol.format)
            assertEquals(shared, protocol.supportsMovie)
            if (shared) protocol.requireMode(true)
            else assertThrows(PictureControlMovieBankUnsupportedException::class.java) { protocol.requireMode(true) }
            transport.assertComplete()
        }
    }

    @Test fun eitherDocumentedParameterErrorCanLeadToValidatedV2AndAConfirmedSharedBank() {
        for (code in listOf(0x2006, 0x201D)) {
            val transport = ScriptedTransport(read3(rc = code), read2(), movieProperty(0x200A))
            val protocol = discover(transport)
            assertEquals(NikonPictureControlFormat.LEGACY_V2, protocol.format)
            assertTrue(protocol.supportsMovie)
            assertTrue(protocol.cacheable)
            assertEquals(0xD200, protocol.format.selectionProperty(true))
            protocol.requireMode(true)
            transport.assertComplete()
        }
    }

    @Test fun aCameraIgnoringTheThirdArgumentMustStillAcceptAnExplicitTwoArgumentRead() {
        for (curve in listOf(false, true)) {
            val transport = ScriptedTransport(read3(bytes = v2Standard(curve)),
                read2(bytes = v2Standard(curve)), movieProperty(0x200A))
            val protocol = discover(transport)
            assertEquals(NikonPictureControlFormat.LEGACY_V2, protocol.format)
            assertTrue(protocol.supportsMovie)
            assertTrue(protocol.cacheable)
            transport.assertComplete()
        }
    }

    @Test fun aValidFirstV2PayloadDoesNotOverrideRejectionOfTheTwoArgumentCommand() {
        for (code in listOf(0x2006, 0x201D, 0x2019)) {
            val transport = ScriptedTransport(read3(bytes = v2Standard()), read2(rc = code, bytes = null))
            assertThrows(IllegalStateException::class.java) { discover(transport) }
            transport.assertComplete()
        }
    }

    @Test fun theTwoArgumentConfirmationMustReturnV2RatherThanAValidZDataset() {
        val transport = ScriptedTransport(read3(rc = 0x2006), read2(bytes = zStandard()))
        assertThrows(IllegalArgumentException::class.java) { discover(transport) }
        transport.assertComplete()
    }

    @Test fun oldV1LayoutsAreRejectedWithoutGuessingAnotherProtocol() {
        for (size in listOf(31, 609)) {
            val oldLayout = ByteArray(size).also {
                it[0] = 1
                "STANDARD".toByteArray(Charsets.US_ASCII).copyInto(it, 3)
            }
            val direct = ScriptedTransport(read3(bytes = oldLayout))
            assertThrows(IllegalArgumentException::class.java) { discover(direct) }
            direct.assertComplete()
            val second = ScriptedTransport(read3(rc = 0x201D), read2(bytes = oldLayout))
            assertThrows(IllegalArgumentException::class.java) { discover(second) }
            second.assertComplete()
        }
    }

    @Test fun busyAndOtherNonParameterErrorsDoNotFallBackToLegacy() {
        for (code in listOf(0x2019, 0x2002, 0x2003, 0x2005, 0x200A, 0x201F)) {
            val transport = ScriptedTransport(read3(rc = code))
            assertThrows(IllegalStateException::class.java) { discover(transport) }
            transport.assertComplete()
        }
    }

    @Test fun malformedSuccessfulResponsesNeverTriggerLegacyRetries() {
        val payloads = listOf(
            null,
            byteArrayOf(1, 2, 3),
            ByteArray(36),
            ByteArray(32),
            zStandard().also { it[0] = 2 },
            zStandard().also { it[2] = 0xFF.toByte() },
            v2Standard().also { it[0] = 2 },
            v2Standard().also { it[2] = 2 },
            v2Standard().also { it[1] = 3 },
            v2Standard().also { it[3] = 0xFF.toByte() },
            v2Standard().also { it[31] = 1 },
        )
        for (bytes in payloads) {
            val transport = ScriptedTransport(read3(bytes = bytes))
            assertThrows(RuntimeException::class.java) { discover(transport) }
            transport.assertComplete()
        }
    }

    @Test fun malformedLegacyConfirmationDoesNotReachTheMovieProbe() {
        val transport = ScriptedTransport(read3(rc = 0x2006), read2(bytes = ByteArray(32)))
        assertThrows(RuntimeException::class.java) { discover(transport) }
        transport.assertComplete()
    }

    @Test fun disconnectAndCancellationPropagateWithoutAnyRetryOrMovieProbe() {
        for (error in listOf(IOException("Disconnected"), CancellationException("Cancelled"))) {
            for (firstRead in listOf(true, false)) {
                val transport = if (firstRead) ScriptedTransport(read3(error = error))
                    else ScriptedTransport(read3(rc = 0x2006), read2(error = error))
                val thrown = assertThrows(error.javaClass) { discover(transport) }
                assertSame(error, thrown)
                transport.assertComplete()
            }
        }
    }

    @Test fun aChangedSessionStopsBeforeAnyFollowupRead() {
        var connected = true
        val transport = ScriptedTransport(read3(rc = 0x2006, afterResponse = { connected = false }))
        assertThrows(IllegalStateException::class.java) { discover(transport, session = { connected }) }
        transport.assertComplete()
    }

    @Test fun anAlreadyChangedSessionNeverSendsACommand() {
        val transport = ScriptedTransport()
        assertThrows(IllegalStateException::class.java) { discover(transport, session = { false }) }
        transport.assertComplete()
    }

    @Test fun missingReadOperationNeverSendsAnyProbe() {
        for (advertised in listOf(emptySet(), operations - 0x90CC)) {
            val transport = ScriptedTransport()
            assertThrows(IllegalStateException::class.java) { discover(transport, advertised = advertised) }
            transport.assertComplete()
        }
    }

    @Test fun advertisedMoviePropertyMakesLegacyPhotoOnlyWithoutAPropertyProbe() {
        val transport = ScriptedTransport(read3(rc = 0x2006), read2())
        val protocol = discover(transport, properties = setOf(0xD200, 0xD237))
        assertEquals(NikonPictureControlFormat.LEGACY_V2, protocol.format)
        assertFalse(protocol.supportsMovie)
        assertTrue(protocol.cacheable)
        protocol.requireMode(false)
        assertThrows(IllegalStateException::class.java) { protocol.requireMode(true) }
        transport.assertComplete()
    }

    @Test fun absenceOfTheMovieAdvertisementAloneDoesNotProveASharedBank() {
        val transport = ScriptedTransport(read3(rc = 0x201D), read2())
        val protocol = discover(transport, advertised = operations - 0x1014)
        assertFalse(protocol.supportsMovie)
        assertFalse(protocol.cacheable)
        protocol.requireMode(false)
        assertThrows(IllegalStateException::class.java) { protocol.requireMode(true) }
        transport.assertComplete()
    }

    @Test fun onlyExplicitUnsupportedMoviePropertyConfirmsLegacyMovieSupport() {
        // A valid or malformed successful descriptor, busy, and generic errors all
        // leave the movie protocol unverified rather than selecting D200 for it.
        val responses = listOf(0x2001 to null, 0x2001 to byteArrayOf(1),
            0x2001 to movieDescriptor().also { it[0] = 0 },
            0x2019 to null, 0x201D to null, 0x2006 to null, 0x2002 to null, 0x200F to null)
        for ((code, bytes) in responses) {
            val transport = ScriptedTransport(read3(rc = 0x2006), read2(), movieProperty(code, bytes))
            val protocol = discover(transport)
            assertFalse(protocol.supportsMovie)
            assertFalse("An unverified bank must be retried next time", protocol.cacheable)
            protocol.requireMode(false)
            assertThrows(IllegalStateException::class.java) { protocol.requireMode(true) }
            transport.assertComplete()
        }
    }

    @Test fun aValidUnadvertisedMovieDescriptorConfirmsPhotoOnlyAndCanBeCached() {
        val transport = ScriptedTransport(read3(rc = 0x2006), read2(), movieProperty(0x2001, movieDescriptor()))
        val protocol = discover(transport)
        assertEquals(NikonPictureControlFormat.LEGACY_V2, protocol.format)
        assertFalse(protocol.supportsMovie)
        assertTrue(protocol.cacheable)
        protocol.requireMode(false)
        assertThrows(IllegalStateException::class.java) { protocol.requireMode(true) }
        transport.assertComplete()
    }

    @Test fun movieProbeDisconnectAndCancellationAreNotTreatedAsUnsupportedProperty() {
        for (error in listOf(IOException("Disconnected"), CancellationException("Cancelled"))) {
            val transport = ScriptedTransport(read3(rc = 0x2006), read2(), movieProperty(0x200A, error = error))
            assertSame(error, assertThrows(error.javaClass) { discover(transport) })
            transport.assertComplete()
        }
    }

    @Test fun aFailedTransportStillRecordsTheExactOutgoingProbe() {
        val lines = mutableListOf<String>()
        val transport = ScriptedTransport(read3(error = IOException("Disconnected")))
        assertThrows(IOException::class.java) { discover(transport, log = lines::add) }
        assertEquals(listOf("out op=0x90CC params=1, 0, 0"), lines)
        transport.assertComplete()
    }
}
