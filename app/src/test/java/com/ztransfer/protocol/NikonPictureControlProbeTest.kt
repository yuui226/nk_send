package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlProbeTest {
    private val descriptor = "00D20400010800050002250001000200030004000500060007000800650066006700680069006A006B006C006D006E006F00700071007200730074007500760077007800C900CA00CB00CC00CD00CE00CF00D000D100"
        .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private val choices = (1..8).toList() + (101..120).toList() + (201..209).toList()
    private val info = LabDeviceInfo("Nikon", "Z 30", "V1.20", "private-serial", 10, 100, "",
        setOf(0x1014, 0x1015, 0x90CC, 0x90CD, 0x90CE, 0x90CF), emptySet(), emptySet())
    private data class Request(val op: Int, val args: List<Int>)

    private fun response(op: Int, args: IntArray): Pair<Int, ByteArray?> = when (op) {
        0x1014 -> if (args[0] == 0xD200) 0x2001 to descriptor else 0x200A to null
        0x1015 -> if (args[0] == 0xD200) 0x2001 to byteArrayOf(5, 0) else 0x200A to null
        0x90CC -> 0x2001 to ByteArray(36).also { if (args[0] < 201) it[0] = args[0].toByte() }
        0x90CF -> 0x2001 to byteArrayOf(1, 2, 3, 4)
        else -> 0x2005 to null
    }

    @Test fun oneRunCollectsAllAdvertisedItemsAndEveryCustomSlotWithoutWrites() = runBlocking {
        val requests = mutableListOf<Request>()
        val log = mutableListOf<String>()
        runPictureControlProbe(info, log::add) { op, args ->
            requests += Request(op, args.toList())
            response(op, args)
        }
        for (argument in 0..3) {
            assertEquals(choices.toSet(), requests.filter { it.op == 0x90CC && it.args[1] == argument }
                .map { it.args[0] }.toSet())
        }
        assertEquals((listOf(0) + choices).toSet(), requests.filter { it.op == 0x90CF }.map { it.args[0] }.toSet())
        // DeviceInfo.props is empty, but photo and movie properties must still be read.
        for (property in listOf(0xD200, 0xD201, 0xD237, 0xD238)) {
            assertTrue(requests.contains(Request(0x1014, listOf(property))))
            assertTrue(requests.contains(Request(0x1015, listOf(property))))
        }
        assertTrue(requests.all { it.op in setOf(0x1014, 0x1015, 0x90CC, 0x90CF) })
        assertTrue(log.any { it.contains("confirmedLastCustomSlot=209") })
        assertTrue(log.last().startsWith("probe complete:"))
        assertFalse(log.joinToString().contains("private-serial"))
        assertTrue(requests.size < 220)
    }

    @Test fun rejectedReadArgumentsAreBoundedButDoNotSuppressOtherArguments() = runBlocking {
        val requests = mutableListOf<Request>()
        runPictureControlProbe(info, {}) { op, args ->
            requests += Request(op, args.toList())
            if (op == 0x90CC && args[1] in 1..2) 0x201D to null else response(op, args)
        }
        for (argument in 1..2) {
            assertEquals(listOf(1, 4, 209), requests.filter { it.op == 0x90CC && it.args[1] == argument }.map { it.args[0] })
        }
        assertEquals(37, requests.count { it.op == 0x90CC && it.args[1] == 3 })
    }

    @Test fun busyReadIsRetriedAndNotMistakenForUnsupportedFormat() = runBlocking {
        var retried = false
        var argumentOneReads = 0
        runPictureControlProbe(info, {}) { op, args ->
            if (op == 0x90CC && args[1] == 1) argumentOneReads++
            if (op == 0x90CC && args.contentEquals(intArrayOf(1, 1)) && !retried) {
                retried = true
                0x2019 to null
            } else response(op, args)
        }
        assertTrue(retried)
        assertEquals(38, argumentOneReads)
    }

    @Test fun unsupportedCapabilityOperationIsOnlySentOnce() = runBlocking {
        var capabilityRequests = 0
        runPictureControlProbe(info, {}) { op, args ->
            if (op == 0x90CF) { capabilityRequests++; 0x2005 to null } else response(op, args)
        }
        assertEquals(1, capabilityRequests)
    }

    @Test fun cancellationStopsThePlanAndNeverClaimsCompletion() = runBlocking {
        val log = mutableListOf<String>()
        var requests = 0
        try {
            runPictureControlProbe(info, log::add) { _, _ ->
                requests++
                throw CancellationException("disconnected")
            }
            fail("Expected cancellation")
        } catch (_: CancellationException) { }
        assertEquals(1, requests)
        assertFalse(log.any { it.startsWith("probe complete:") })
    }

    @Test fun timeBudgetStopsBeforeStartingAnotherRequest() = runBlocking {
        var now = 0L
        var requests = 0
        try {
            runPictureControlProbe(info, {}, nowNanos = { now }) { op, args ->
                requests++
                now += 90_000_000_000L
                response(op, args)
            }
            fail("Expected collection limit")
        } catch (error: IllegalStateException) {
            assertTrue(error.message.orEmpty().contains("INCOMPLETE"))
        }
        assertEquals(2, requests)
    }

    @Test fun dataLargerThanOld4096ByteLimitCanBeReconstructedExactlyAndDeduplicated() {
        val lines = mutableListOf<String>()
        val payloads = PictureControlProbePayloads(lines::add)
        val data = ByteArray(6341) { (it * 19).toByte() }
        payloads.record("r001", data)
        payloads.record("r002", data.copyOf())
        val decoded = lines.filter { it.startsWith("r001 data[") }
            .joinToString("") { it.substringAfter('=') }
            .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        assertArrayEquals(data, decoded)
        assertEquals(data.size.toLong(), payloads.uniqueBytes)
        assertTrue(lines.last().startsWith("r002 dataRef=r001 sha256="))
    }

    @Test fun vendorListsPreserveExtendedPropertyIdsAndRejectInvalidCounts() {
        val extended = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(2).putInt(0x1D01D).putInt(0xD237).array()
        assertEquals(setOf(0x1D01D, 0xD237), parsePictureControlVendorCodes(extended, 4))
        assertThrows(IllegalArgumentException::class.java) { parsePictureControlVendorCodes(extended, 2) }
        assertThrows(IllegalArgumentException::class.java) {
            parsePictureControlVendorCodes(byteArrayOf(-1, -1, -1, -1), 4)
        }
    }

    @Test fun movieSelectionAndExtendedPropertiesAreIncludedWhenAdvertised() = runBlocking {
        val extendedInfo = info.copy(operations = info.operations + 0x9439)
        val requests = mutableListOf<Request>()
        runPictureControlProbe(extendedInfo, {}) { op, args ->
            requests += Request(op, args.toList())
            when {
                op == 0x9439 -> 0x2001 to ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(1).putInt(0x1D01D).array()
                op == 0x1014 && args[0] == 0xD237 -> 0x2001 to descriptor.copyOf().apply { this[0] = 0x37 }
                else -> response(op, args)
            }
        }
        assertTrue(requests.contains(Request(0x9439, listOf(0x0D))))
        assertTrue(requests.contains(Request(0x1014, listOf(0x1D01D))))
        assertTrue(requests.contains(Request(0x1015, listOf(0x1D01D))))
    }
}
