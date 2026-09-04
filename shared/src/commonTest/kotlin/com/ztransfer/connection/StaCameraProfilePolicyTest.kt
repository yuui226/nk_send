package com.ztransfer.connection

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StaCameraProfilePolicyTest {
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
    fun unknownOrUnconfirmedCameraStartsWithPairingIdentity() {
        assertEquals(
            StaInitiatorIdentity.PAIRED_COMPUTER,
            preferredStaIdentityForCandidate(
                ip = "192.168.50.99",
                profiles = emptyList(),
            ),
        )

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
    fun confirmedRouteWinsOverNewerUnconfirmedRouteAtSameAddress() {
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
    fun equalTimestampsPreserveTheFirstMatchingInput() {
        val first = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 20L,
        )
        val second = profile(
            guid = "22222222222222222222222222222222",
            ip = first.lastIp!!,
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 20L,
        )

        assertEquals(first, mostRecentStaProfileForIp(listOf(first, second), first.lastIp!!))
    }

    @Test
    fun lastUsedRoutePrecedesTheGlobalNewestFallback() {
        val lastUsed = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 10L,
        )
        val globalNewest = profile(
            guid = "22222222222222222222222222222222",
            ip = "192.168.50.11",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 20L,
        )

        assertEquals(
            lastUsed,
            mostRecentlyUsedStaProfile(listOf(lastUsed, globalNewest), lastUsed.lastIp),
        )
        assertEquals(
            globalNewest,
            mostRecentlyUsedStaProfile(
                profiles = listOf(lastUsed, globalNewest),
                lastUsedIp = "192.168.50.99",
            ),
        )
    }

    @Test
    fun unconfirmedOrNeverSeenProfilesAreNotGlobalFallbacks() {
        val unconfirmed = profile(
            guid = "11111111111111111111111111111111",
            ip = "192.168.50.10",
            identity = StaInitiatorIdentity.ALBUM_EXPLORER,
            seenAt = 20L,
        ).copy(pairingConfirmed = false)
        val neverSeen = profile(
            guid = "22222222222222222222222222222222",
            ip = "192.168.50.11",
            identity = StaInitiatorIdentity.PAIRED_COMPUTER,
            seenAt = 0L,
        )

        assertNull(
            mostRecentlyUsedStaProfile(
                profiles = listOf(unconfirmed),
                lastUsedIp = unconfirmed.lastIp,
            ),
        )
        assertNull(
            mostRecentlyUsedStaProfile(
                profiles = listOf(neverSeen),
                lastUsedIp = null,
            ),
        )
        assertEquals(
            neverSeen,
            mostRecentlyUsedStaProfile(
                profiles = listOf(neverSeen),
                lastUsedIp = neverSeen.lastIp,
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
