// ==============================================================================
// Mimra — Floating Panel View
// SwiftUI content for the floating search panel, item list, empty states, and footer.
// Linked Features: F-018, F-019
// Test IDs: T-UI-02, T-UI-03
// ==============================================================================

import SwiftUI

@MainActor
public struct FloatingPanelView: View {
    @ObservedObject public var viewModel: PanelViewModel
    @ObservedObject public var accessibilityService: AccessibilityService
    @FocusState private var isSearchFocused: Bool

    public init(viewModel: PanelViewModel, accessibilityService: AccessibilityService? = nil) {
        self.viewModel = viewModel
        self.accessibilityService = accessibilityService ?? AccessibilityService.shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Search Header Bar
            PanelSearchBar(
                text: $viewModel.searchText,
                isFocused: $isSearchFocused,
                onClear: {
                    viewModel.searchText = ""
                }
            )

            Divider()
                .opacity(0.4)

            // Copy-Only Mode Informational Banner (when Accessibility is not granted)
            if !accessibilityService.isTrusted {
                CopyOnlyBanner(onEnable: {
                    accessibilityService.promptForPermission()
                })
                Divider()
                    .opacity(0.4)
            }

            // 2. Main Content Area (Items list or empty state)
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Loading clipboard history...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.items.isEmpty {
                    PanelEmptyStateView(
                        iconName: "doc.on.clipboard",
                        title: "Clipboard is Empty",
                        subtitle: "Items copied to the clipboard will appear here automatically."
                    )
                } else if viewModel.filteredItems.isEmpty {
                    PanelEmptyStateView(
                        iconName: "magnifyingglass",
                        title: "No Matches Found",
                        subtitle: "No clipboard items match '\(viewModel.searchText)'."
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
                                    PanelItemRow(
                                        item: item,
                                        shortcutIndex: index < 9 ? (index + 1) : nil,
                                        isSelected: index == viewModel.selectedIndex
                                    )
                                    .id(item.id)
                                    .onHover { isHovered in
                                        if isHovered {
                                            viewModel.selectIndex(index, fromHover: true)
                                        }
                                    }
                                    .onTapGesture {
                                        viewModel.selectIndex(index, fromHover: false)
                                        viewModel.commitSelection()
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .onChange(of: viewModel.selectedIndex) { _, newIndex in
                            if newIndex >= 0 && newIndex < viewModel.filteredItems.count {
                                let targetId = viewModel.filteredItems[newIndex].id
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    proxy.scrollTo(targetId, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(0.4)

            // 3. Compact Footer Action Bar
            PanelFooterBar(
                itemCount: viewModel.filteredItems.count,
                totalCount: viewModel.items.count,
                onSettings: {
                    viewModel.onOpenSettings?()
                },
                onDismiss: {
                    viewModel.onDismiss?()
                }
            )
        }
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 800, minHeight: 320, idealHeight: 540, maxHeight: 1000)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .task {
            await viewModel.loadData()
            isSearchFocused = true
            accessibilityService.startObserving()
        }
        .onDisappear {
            accessibilityService.stopObserving()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mimraClipboardDidIngest)) { _ in
            Task { await viewModel.loadData() }
        }
    }
}

// MARK: - Search Bar Component

struct PanelSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search clipboard history...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - History Item Row Component

struct PanelItemRow: View {
    let item: HistoryItemSummaryDto
    let shortcutIndex: Int?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Type icon
            Image(systemName: iconForKind(item.contentKind))
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 20)

            // Text title and preview snippet
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }

                    if item.copyCount > 1 {
                        Text("\(item.copyCount)x")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                            .foregroundColor(isSelected ? .white : .secondary)
                            .cornerRadius(3)
                    }

                    Spacer()

                    // Quick-pick shortcut badge (⌘1 - ⌘9)
                    if let key = shortcutIndex {
                        Text("⌘\(key)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
                            .cornerRadius(4)
                    }
                }

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func iconForKind(_ kind: String) -> String {
        switch kind {
        case "text":
            return "text.alignleft"
        case "rich_text":
            return "text.quote"
        case "image":
            return "photo"
        case "file_urls":
            return "folder"
        default:
            return "square.stack.3d.down.right"
        }
    }
}

// MARK: - Empty State Component

struct PanelEmptyStateView: View {
    let iconName: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.bottom, 4)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Compact Footer Bar Component

struct PanelFooterBar: View {
    let itemCount: Int
    let totalCount: Int
    let onSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(itemCount) of \(totalCount) items")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Spacer()

            // Shortcut hints
            HStack(spacing: 8) {
                ShortcutHint(key: "↑↓", label: "Navigate")
                ShortcutHint(key: "↵", label: "Paste")
                ShortcutHint(key: "⎋", label: "Dismiss")
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Mimra Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct ShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(3)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Copy-Only Mode Banner Component

struct CopyOnlyBanner: View {
    var onEnable: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 1) {
                Text("Copy-Only Mode Active")
                    .font(.system(size: 11, weight: .semibold))
                Text("Press ⌘V to paste manually. Grant Accessibility to auto-paste.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Enable...") {
                onEnable()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}
