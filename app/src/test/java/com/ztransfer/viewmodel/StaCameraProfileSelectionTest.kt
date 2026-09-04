package com.ztransfer.viewmodel

import com.ztransfer.connection.StaInitiatorIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StaCameraProfileSelectionTest {
    @Test
    fun responderGuidNormalizationRejectsUnstableValues() {
        assertEquals(
            "0123456789abcdef0123456789abcdef",
            normalizeResponderGuid(" 0123456789ABCDEF0123456789ABCDEF "),
        )
        assertNull(normalizeResponderGuid(null))
        assertNull(normalizeResponderGuid("camera-z8"))
        assertNull(normalizeResponderGuid("0123"))
    }

    @Test
    fun eachCameraKeepsItsOwnSuccessfulIdentity() {
        val profiles = listOf(
            profile(
                guid = "11111111111111111111111111111111",
                ip = "192.168.50.10",
                identity = StaInitiatorIdentity.PAIRED_COMPUTER,
                seenAt = 10L,
            ),
            profile(
                guid = "22222222222222222222222222222222",
                ip = "192.168.50.11",
                identity = StaInitiatorIdentity.ALBUM_EXPLORER,
                seenAt = 20L,
            ),
        )

        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.10",
                profiles = profiles,
            ),
        )
        assertEquals(
            StaInitiatorIdentity.ALBUM_EXPLORER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.11",
                profiles = profiles,
            ),
        )
    }

    @Test
    fun unknownCameraStartsWithPairingIdentity() {
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.99",
                profiles = emptyList(),
            ),
        )
    }

    @Test
    fun unconfirmedAlbumRouteCannotBypassPairingIdentity() {
        val unconfirmed = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 20L,
        ).copy(pairingConfirmed = false)

        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.10",
                profiles = listOf(unconfirmed),
            ),
        )
    }

    @Test
    fun olderConfirmedRouteWinsOverNewerUnconfirmedRouteAtSameAddress() {
        val confirmed = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 10L,
        )
        val unconfirmed = profile(
            guid = "22222222222222222222222222222222",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 20L,
        ).copy(pairingConfirmed = false)

        assertEquals(
            StaInitiatorIdentity.ALBUM_EXPLORER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.10",
                profiles = listOf(confirmed, unconfirmed),
            ),
        )
    }

    @Test
    fun newestProfileWinsIfDhcpReusesAnAddress() {
        val old = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 10L,
        )
        val current = profile(
            guid = "22222222222222222222222222222222",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 20L,
        )

        assertEquals(current, mostRecentStaProfileForIp(listOf(old, current), current.lastIp!!))
        assertTrue(
            hasReusableStaProfileUsing(
                listOf(old, current),
                StaInitiatorIdentity.ALBUM_EXPLORER,
            ),
        )
        assertFalse(
            hasReusableStaProfileUsing(
                listOf(current.copy(pairingConfirmed = false)),
                StaInitiatorIdentity.PAIRED_COMPUTER,
            ),
        )
    }

    @Test
    fun lastUsedBodyIsSelectedByGuidInsteadOfDhcpAddressAlone() {
        val previous = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 10L,
        )
        val lastUsed = profile(
            guid = "22222222222222222222222222222222",
            ip = "192.168.50.11",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 20L,
        )

        assertEquals(
            lastUsed,
            mostRecentlyUsedStaProfile(listOf(previous, lastUsed), lastUsed.lastIp),
        )
        assertEquals(
            lastUsed,
            mostRecentlyUsedStaProfile(
                profiles = listOf(previous, lastUsed),
                lastUsedIp = "192.168.50.99",
            ),
        )
    }

    @Test
    fun unconfirmedLastUsedBodyIsNotRestoredAsExpectedCamera() {
        val unconfirmed = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 20L,
        ).copy(pairingConfirmed = false)

        assertNull(
            mostRecentlyUsedStaProfile(
                profiles = listOf(unconfirmed),
                lastUsedIp = unconfirmed.lastIp,
            ),
        )
    }

    private fun profile(
        guid: String,
        ip: String,
        identity: StaInitiatorIdentity,
        seenAt: Long,
    ) = StaCameraProfile(
        responderGuid = guid,
        lastIp = ip,
        preferredIdentity = identity,
        pairingConfirmed = true,
        lastSeenAtMs = seenAt,
    )
}
