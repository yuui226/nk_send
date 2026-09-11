import SwiftUI
import UIKit

/// Shared long-press entry point used by the settings and photo-workbench filter wheels.
/// The host keeps ownership of the preview; this view only returns an atomic filter selection.
struct PhotoFilterWheelLauncher<Label: View>: View {
    @ObservedObject var store: PhotoFilterCatalogStore
    let onTap: () -> Void
    let onSelection: (IOSPhotoFilterSelection) -> Void
    @ViewBuilder let label: () -> Label
    @State private var showingPicker = false

    var body: some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
                    .onEnded { _ in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showingPicker = true
                    }
            )
            .sheet(isPresented: $showingPicker) {
                PhotoFilterPickerView(store: store) { selection in
                    onSelection(selection)
                    showingPicker = false
                }
            }
    }
}

/// Compact, landscape-friendly picker: categories occupy a narrow left rail and filters occupy
/// the larger right column. There is intentionally no title or Done button; selecting a card is
/// the commit action and dismisses the sheet immediately.
struct PhotoFilterPickerView: View {
    @ObservedObject var store: PhotoFilterCatalogStore
    let onSelection: (IOSPhotoFilterSelection) -> Void

    private let categoryWidth: CGFloat = 96

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                categoryRail
                    .frame(width: min(categoryWidth, max(84, proxy.size.width * 0.26)))
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
                    .padding(.vertical, 12)
                filterColumn
            }
            .padding(12)
            .frame(width: min(proxy.size.width - 24, 560),
                   height: min(proxy.size.height - 24, 520))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }

    private var categoryRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 7) {
                ForEach(IOSPhotoFilterCategory.allCases) { category in
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { store.category = category }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbolName)
                                .font(.caption.weight(.semibold))
                                .frame(width: 17)
                            Text(category.rawValue)
                                .font(.caption.weight(store.category == category ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(store.category == category ? Color.accentColor : .primary.opacity(0.72))
                        .padding(.horizontal, 9)
                        .frame(height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(store.category == category ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(store.category == category ? Color.accentColor.opacity(0.34) : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filterColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 7) {
                if store.visibleEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "star")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("暂无收藏滤镜")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(store.visibleEntries) { entry in
                        filterCard(entry)
                    }
                }
            }
            .padding(.leading, 12)
        }
    }

    private func filterCard(_ entry: IOSPhotoFilterEntry) -> some View {
        let selected = store.selectedKey == entry.catalogKey
        return HStack(spacing: 8) {
            Button {
                store.toggleFavorite(entry)
            } label: {
                Image(systemName: store.favoriteKeys.contains(entry.catalogKey) ? "star.fill" : "star")
                    .foregroundStyle(store.favoriteKeys.contains(entry.catalogKey) ? .yellow : .secondary)
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                onSelection(store.selection(for: entry))
            } label: {
                Text(entry.name)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.46) : Color.white.opacity(0.16), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

private extension IOSPhotoFilterCategory {
    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .landscape: return "mountain.2"
        case .portrait: return "person.crop.circle"
        case .monochrome: return "circle.lefthalf.filled"
        case .film: return "film"
        case .cinematic: return "theatermasks"
        case .color: return "paintpalette"
        }
    }
}
