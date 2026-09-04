package com.ztransfer.viewmodel

const val REMOTE_ENTRY_INTRO_MAX_PLAYS = 6

fun isRemoteEntryIntroEligible(playCount: Int): Boolean =
    playCount.coerceAtLeast(0) < REMOTE_ENTRY_INTRO_MAX_PLAYS
