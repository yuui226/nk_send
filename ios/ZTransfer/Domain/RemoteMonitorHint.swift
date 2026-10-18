import Foundation

/// RemoteScreen.showHint: one message and one hide deadline for the whole
/// monitor, including repeated identical messages. Keep text while invisible
/// so the outgoing AnimatedVisibility can finish without changing its content.
struct RemoteMonitorHint: Equatable {
    enum Source { case interaction, cameraRecording, lut }
    var text = ""
    var visible = false
    var source: Source = .interaction
    var nonce: UInt64 = 0

    func message(for source: Source) -> String? {
        visible && self.source == source ? text : nil
    }
}
