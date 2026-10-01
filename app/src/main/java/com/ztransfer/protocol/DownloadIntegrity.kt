package com.ztransfer.protocol

/** Returns the first reliable size that disagrees with the received full object. */
internal fun mismatchedFullObjectSize(received: Long, declared: Long, known: Long): Long? {
    if (declared > 0 && declared != PtpConstants.SIZE_UNKNOWN && received != declared) return declared
    if (known > 0 && known != PtpConstants.SIZE_UNKNOWN && received != known) return known
    return null
}
