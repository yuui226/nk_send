import SwiftUI

/// HomeScreen.ResetStaPairingDialog. Reset has one explicit confirmation and
/// clears every pairing/initiator, while retaining the selected wireless mode.
struct STAResetPairingOverlay: View {
    let count: Int
    let models: [String]
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // User-approved (2026-10-19): STA reset has no dimming.
                // Keep outside dismissal and the modal input boundary.
                DialogBackdrop(opacity: 0, onDismiss: onDismiss)
                VStack(alignment: .leading, spacing: 0) {
                    Text(AppLocalized.resource("sta_reset_pairing_title"))
                        .zTransferTypography(.titleMedium, weight: .bold)
                    Spacer().frame(height: 8)
                    HStack(spacing: 7) {
                        Image(systemName: "camera.fill").font(.system(size: 17)).foregroundStyle(ZTransferColors.accentBlue)
                        Text(([AppLocalized.formattedResource("sta_paired_camera_count", ["%1$d": String(count)])] + models).joined(separator: " · "))
                            .zTransferTypography(.labelMedium, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(ZTransferColors.accentBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    Spacer().frame(height: 10)
                    Text(AppLocalized.resource("sta_reset_pairing_message"))
                        .zTransferTypography(.bodyMedium)
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer().frame(height: 18)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(action: onDismiss) {
                            Text(AppLocalized.resource("cancel")).foregroundStyle(ZTransferColors.secondaryText)
                                .padding(.horizontal, 12).frame(height: 40)
                        }.buttonStyle(.plain)
                        Button(action: onConfirm) {
                            Text(AppLocalized.resource("sta_reset_pairing")).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 40)
                                .background(ZTransferColors.statusError, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }.zTransferTypography(.labelLarge, weight: .medium)
                }
                .foregroundStyle(ZTransferColors.primaryText)
                .padding(20)
                .background(ZTransferGlassSurface(cornerRadius: 20, kind: .panel))
                .frame(width: min(360, max(0, proxy.size.width - 48)))
                .fixedSize(horizontal: false, vertical: true)
                .androidDialogSurface()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.zIndex(100)
    }
}

/// Android `GpsResetPairingDialog`: the paired-state row is part of the
/// confirmation content, not a separate GPS-window state.
struct GPSResetPairingOverlay: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DialogBackdrop(onDismiss: onDismiss)

                VStack(alignment: .leading, spacing: 0) {
                    Text(AppLocalized.resource("gps_clear_pairing_title"))
                        .zTransferTypography(.titleMedium, weight: .bold)
                    Spacer().frame(height: 8)
                    HStack(spacing: 7) {
                        ConnectionPairingIcon(kind: .bluetooth)
                            .frame(width: 17, height: 17)
                            .foregroundStyle(ZTransferColors.accentBlue)
                        Text(AppLocalized.resource("gps_paired_device_status"))
                            .zTransferTypography(.labelMedium, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        ZTransferColors.accentBlue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    Spacer().frame(height: 10)
                    Text(AppLocalized.resource("gps_clear_pairing_message"))
                        .zTransferTypography(.bodyMedium)
                        .foregroundStyle(ZTransferColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer().frame(height: 18)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(action: onDismiss) {
                            Text(AppLocalized.resource("cancel"))
                                .foregroundStyle(ZTransferColors.secondaryText)
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                        }
                        .buttonStyle(.plain)
                        Button(action: onConfirm) {
                            Text(AppLocalized.resource("gps_clear_pairing"))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(
                                    ZTransferColors.statusError,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .zTransferTypography(.labelLarge, weight: .medium)
                }
                .foregroundStyle(ZTransferColors.primaryText)
                .padding(20)
                .background(ZTransferGlassSurface(cornerRadius: 24, kind: .panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(ZTransferColors.primaryText.opacity(0.12), lineWidth: 1)
                )
                .frame(width: min(360, max(0, proxy.size.width - 48)))
                .fixedSize(horizontal: false, vertical: true)
                .androidDialogSurface()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .zIndex(100)
    }
}


/// Material Icons LinkOff/Bluetooth, Apache-2.0, from Android's current
/// material-icons-extended 1.5.4 dependency (Compose BOM 2023.10.01).
/// Keep the original 24-unit filled paths; neither name is an SF Symbol.
struct ConnectionPairingIcon: Shape {
    enum Kind { case unlink, bluetooth }
    let kind: Kind
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale)
        return (kind == .unlink ? Self.unlink : Self.bluetooth).applying(transform)
    }
    private static let unlink: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 17, y: 7))
        path.addLine(to: CGPoint(x: 13, y: 7))
        path.addLine(to: CGPoint(x: 13, y: 8.9))
        path.addLine(to: CGPoint(x: 17, y: 8.9))
        path.addCurve(to: CGPoint(x: 20.1, y: 12), control1: CGPoint(x: 18.71, y: 8.9), control2: CGPoint(x: 20.1, y: 10.29))
        path.addCurve(to: CGPoint(x: 17.79, y: 14.98), control1: CGPoint(x: 20.1, y: 13.43), control2: CGPoint(x: 19.12, y: 14.63))
        path.addLine(to: CGPoint(x: 19.25, y: 16.44))
        path.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 20.88, y: 15.61), control2: CGPoint(x: 22, y: 13.95))
        path.addCurve(to: CGPoint(x: 17, y: 7), control1: CGPoint(x: 22, y: 9.24), control2: CGPoint(x: 19.76, y: 7))
        path.closeSubpath()
        path.move(to: CGPoint(x: 16, y: 11))
        path.addLine(to: CGPoint(x: 13.81, y: 11))
        path.addLine(to: CGPoint(x: 15.81, y: 13))
        path.addLine(to: CGPoint(x: 16, y: 13))
        path.closeSubpath()
        path.move(to: CGPoint(x: 2, y: 4.27))
        path.addLine(to: CGPoint(x: 5.11, y: 7.38))
        path.addCurve(to: CGPoint(x: 2, y: 12), control1: CGPoint(x: 3.29, y: 8.12), control2: CGPoint(x: 2, y: 9.91))
        path.addCurve(to: CGPoint(x: 7, y: 17), control1: CGPoint(x: 2, y: 14.76), control2: CGPoint(x: 4.24, y: 17))
        path.addLine(to: CGPoint(x: 11, y: 17))
        path.addLine(to: CGPoint(x: 11, y: 15.1))
        path.addLine(to: CGPoint(x: 7, y: 15.1))
        path.addCurve(to: CGPoint(x: 3.9, y: 12), control1: CGPoint(x: 5.29, y: 15.1), control2: CGPoint(x: 3.9, y: 13.71))
        path.addCurve(to: CGPoint(x: 6.66, y: 8.93), control1: CGPoint(x: 3.9, y: 10.41), control2: CGPoint(x: 5.11, y: 9.1))
        path.addLine(to: CGPoint(x: 8.73, y: 11))
        path.addLine(to: CGPoint(x: 8, y: 11))
        path.addLine(to: CGPoint(x: 8, y: 13))
        path.addLine(to: CGPoint(x: 10.73, y: 13))
        path.addLine(to: CGPoint(x: 13, y: 15.27))
        path.addLine(to: CGPoint(x: 13, y: 17))
        path.addLine(to: CGPoint(x: 14.73, y: 17))
        path.addLine(to: CGPoint(x: 18.74, y: 21))
        path.addLine(to: CGPoint(x: 20, y: 19.74))
        path.addLine(to: CGPoint(x: 3.27, y: 3))
        path.addLine(to: CGPoint(x: 2, y: 4.27))
        path.closeSubpath()
        return path
    }()
    private static let bluetooth: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 17.71, y: 7.71))
        path.addLine(to: CGPoint(x: 12, y: 2))
        path.addLine(to: CGPoint(x: 11, y: 2))
        path.addLine(to: CGPoint(x: 11, y: 9.59))
        path.addLine(to: CGPoint(x: 6.41, y: 5))
        path.addLine(to: CGPoint(x: 5, y: 6.41))
        path.addLine(to: CGPoint(x: 10.59, y: 12))
        path.addLine(to: CGPoint(x: 5, y: 17.59))
        path.addLine(to: CGPoint(x: 6.41, y: 19))
        path.addLine(to: CGPoint(x: 11, y: 14.41))
        path.addLine(to: CGPoint(x: 11, y: 22))
        path.addLine(to: CGPoint(x: 12, y: 22))
        path.addLine(to: CGPoint(x: 17.71, y: 16.29))
        path.addLine(to: CGPoint(x: 13.41, y: 12))
        path.addLine(to: CGPoint(x: 17.71, y: 7.71))
        path.closeSubpath()
        path.move(to: CGPoint(x: 13, y: 5.83))
        path.addLine(to: CGPoint(x: 14.88, y: 7.71))
        path.addLine(to: CGPoint(x: 13, y: 9.59))
        path.addLine(to: CGPoint(x: 13, y: 5.83))
        path.closeSubpath()
        path.move(to: CGPoint(x: 14.88, y: 16.29))
        path.addLine(to: CGPoint(x: 13, y: 18.17))
        path.addLine(to: CGPoint(x: 13, y: 14.41))
        path.addLine(to: CGPoint(x: 14.88, y: 16.29))
        path.closeSubpath()
        return path
    }()
}
