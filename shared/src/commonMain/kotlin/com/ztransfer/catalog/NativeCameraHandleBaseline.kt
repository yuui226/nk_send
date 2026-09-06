package com.ztransfer.catalog

/** One connection owner's successful enumeration baseline. No IO, publication or event scheduling. */
class NativeCameraHandleBaseline {
    private var knownHandles: Set<Int>? = null
    val hasSnapshot: Boolean get() = knownHandles != null
    fun shouldResolve(handle: Int, visibleFiles: List<com.ztransfer.protocol.CameraFileInfo>): Boolean =
        com.ztransfer.viewmodel.NewCameraObjectPolicy.shouldResolve(handle, knownHandles, visibleFiles)
    fun recordPublished(handle: Int) { knownHandles = knownHandles?.plus(handle) }

    /**
     * Call only after ALL handle enumerations succeed and the connection is still current.
     * Like CameraViewModel.loadFiles, commit BEFORE ObjectInfo reads: metadata failures do not
     * undo a successful enumeration. An empty first catalog is still a valid baseline.
     */
    fun acceptEnumeration(handles: IntArray, detectNewHandles: Boolean): CameraHandleDelta {
        val current = handles.toSet()
        val delta = knownHandles?.let { cameraHandleDelta(it, current) }
            ?: CameraHandleDelta(emptySet(), emptySet())
        knownHandles = current
        return if (detectNewHandles) delta else CameraHandleDelta(emptySet(), delta.removed)
    }
}
