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
                Color.black.opacity(0.32).ignoresSafeArea().onTapGesture(perform: onDismiss)
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
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                VStack(alignment: .leading, spacing: 0) {
                    Text(AppLocalized.resource("gps_clear_pairing_title"))
                        .zTransferTypography(.titleMedium, weight: .bold)
                    Spacer().frame(height: 8)
                    HStack(spacing: 7) {
                        Image(systemName: "bluetooth")
                            .font(.system(size: 17, weight: .semibold))
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .zIndex(100)
    }
}
