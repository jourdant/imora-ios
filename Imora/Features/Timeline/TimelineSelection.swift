import SwiftUI

// photos.app style chrome for multi-select: the toolbar's ellipsis menu next
// to the cancel button, the bottom control bar and the selected-items sheet
// behind its center pill.

/// remaining bulk actions behind an ellipsis, mounted as a toolbar item next
/// to the cancel button - the bottom bar has no room left for it. bulk
/// backup lives here too, offered whenever the selection holds
/// not-yet-backed-up device photos.
struct SelectionMoreMenu: View {
    let filter: TimelineFilter
    let isDisabled: Bool
    /// server actions need a remote id for every item, so a selection
    /// holding device photos turns them off while back up stays live.
    let serverActionsDisabled: Bool
    let onFavorite: () async -> Void
    let onArchive: () async -> Void
    var onRemoveFromAlbum: (() async -> Void)?
    /// set on owned albums while exactly one photo is picked.
    var onSetAlbumCover: (() async -> Void)?
    let onAddToAlbum: () -> Void
    /// set while the selection holds not-yet-backed-up device photos. only
    /// those upload; the title reads back up missing when server items are
    /// mixed in.
    var onBackUp: (() -> Void)?
    var backUpTitle = "Back Up"

    var body: some View {
        Menu {
            if let onBackUp {
                Section {
                    Button(action: onBackUp) {
                        Label(backUpTitle, systemImage: "icloud.and.arrow.up")
                    }
                    .accessibilityIdentifier("selection-backup")
                }
            }
            Section {
                Button {
                    Task { await onFavorite() }
                } label: {
                    Label("Favorite", systemImage: "heart")
                }
                if let onRemoveFromAlbum {
                    Button(action: onAddToAlbum) {
                        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button {
                        Task { await onRemoveFromAlbum() }
                    } label: {
                        Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                    }
                    if let onSetAlbumCover {
                        Button {
                            Task { await onSetAlbumCover() }
                        } label: {
                            Label("Set as Album Cover", systemImage: "photo.badge.checkmark")
                        }
                        .accessibilityIdentifier("selection-album-cover")
                    }
                } else {
                    Button {
                        Task { await onArchive() }
                    } label: {
                        Label(
                            filter.visibility == .archive ? "Unarchive" : "Archive",
                            systemImage: filter.visibility == .archive ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    Button(action: onAddToAlbum) {
                        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                    }
                }
            }
            .disabled(serverActionsDisabled)
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(isDisabled)
        .accessibilityLabel("More Actions")
        .accessibilityIdentifier("selection-more")
    }
}

/// bottom controls during multi-select, laid out like photos.app: a share
/// control on the left, the selected-count pill in the middle and trash on
/// the right. trash grids swap share for restore and delete permanently.
struct SelectionControlBar: View {
    let count: Int
    let filter: TimelineFilter
    let isWorking: Bool
    let onShare: () -> Void
    let onShowSelected: () -> Void
    var onRestore: (() async -> Void)?
    let onTrash: () async -> Void

    @State private var confirmsTrash = false

    private var actionsDisabled: Bool { isWorking || count == 0 }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ZStack {
                HStack(spacing: 12) {
                    if let onRestore {
                        circleButton("arrow.uturn.backward", "Restore") {
                            Task { await onRestore() }
                        }
                    } else {
                        circleButton("square.and.arrow.up", "Share", action: onShare)
                            .accessibilityIdentifier("selection-share")
                    }
                    Spacer(minLength: 0)
                    trashButton
                }
                selectedPill
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var trashConfirmationTitle: String {
        let noun = count == 1 ? "1 Item" : "\(count) Items"
        return filter.isTrashed == true
            ? "Permanently Delete \(noun)?"
            : "Move \(noun) to Trash?"
    }

    private var trashButton: some View {
        Button(role: .destructive) {
            confirmsTrash = true
        } label: {
            Image(systemName: filter.isTrashed == true ? "trash.slash" : "trash")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .confirmationDialog(
            trashConfirmationTitle,
            isPresented: $confirmsTrash,
            titleVisibility: .visible
        ) {
            Button(
                filter.isTrashed == true ? "Delete Permanently" : "Move to Trash",
                role: .destructive
            ) {
                Task { await onTrash() }
            }
        } message: {
            Text(filter.isTrashed == true
                ? "This cannot be undone."
                : "Deleted items can be restored from the trash later.")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .glassEffect(.regular, in: .circle)
        .opacity(actionsDisabled ? 0.5 : 1)
        .disabled(actionsDisabled)
        .accessibilityLabel(filter.isTrashed == true ? "Delete Permanently" : "Move to Trash")
        .accessibilityIdentifier("selection-trash")
    }

    /// "Select Items" while nothing is picked, then a tappable
    /// "Show Selected (n)" that opens the selected-items sheet.
    private var selectedPill: some View {
        Group {
            if count == 0 {
                Text("Select Items")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .glassEffect(.regular, in: .capsule)
            } else {
                Button(action: onShowSelected) {
                    Text("Show Selected (\(count))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)
                .disabled(isWorking)
                .accessibilityIdentifier("selection-show-selected")
            }
        }
        .animation(.snappy(duration: 0.2), value: count)
    }

    private func circleButton(
        _ icon: String,
        _ label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .glassEffect(.regular, in: .circle)
        .opacity(actionsDisabled ? 0.5 : 1)
        .disabled(actionsDisabled)
        .accessibilityLabel(label)
    }
}

/// every currently selected asset in one grid, opened from the bar's pill.
/// the asset list is frozen at open so tiles do not vanish mid-tap - a tap
/// unchecks live against the shared selection and can be tapped right back.
struct SelectedAssetsSheet: View {
    let assets: [Asset]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss

    private static let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 2) {
                    ForEach(assets) { asset in
                        tile(asset)
                    }
                }
            }
            .navigationTitle(selection.isEmpty ? "Selected Items" : "\(selection.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("selection-done")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    selection.removeAll()
                    dismiss()
                } label: {
                    Text("Deselect All")
                        .font(.headline)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .fixedSize()
                .disabled(selection.isEmpty)
                .padding(.vertical, 10)
                .accessibilityIdentifier("selection-deselect-all")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func tile(_ asset: Asset) -> some View {
        let isSelected = selection.contains(asset.id)
        return AssetTile(asset: asset)
            .overlay(alignment: .topLeading) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.25))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.22), value: isSelected)
                    .padding(6)
            }
            .contentShape(.rect)
            .onTapGesture {
                if isSelected {
                    selection.remove(asset.id)
                } else {
                    selection.insert(asset.id)
                }
            }
    }
}
