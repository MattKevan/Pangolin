//
//  PhoneLibraryToolbar.swift
//  Pangolin
//

import SwiftUI

/// The iPhone's bottom bar. Collapsed it is a Library button beside a wide search field. Expanded,
/// Library widens into its four destinations and search shrinks to a button; the glass shapes
/// morph between the two.
struct PhoneLibraryToolbar: View {
    @Binding var destination: PhoneLibraryDestination
    @Binding var isExpanded: Bool
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding
    let actions: LibraryActions

    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isExpanded {
                    destinationBar
                    searchButton
                } else {
                    libraryButton
                    searchField
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.3), value: isExpanded)
    }

    /// A tap expands the destinations; touch and hold opens the library actions.
    private var libraryButton: some View {
        Menu {
            LibraryActionsMenuContent(actions: actions)
        } label: {
            Label("Library", systemImage: "rectangle.stack")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 56)
        } primaryAction: {
            isSearchFocused.wrappedValue = false
            isExpanded = true
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("library", in: glassNamespace)
        .accessibilityHint("Shows All videos, Projects, Favourites and Recents. Touch and hold for library actions.")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search library", text: $searchText)
                .focused(isSearchFocused)
                .submitLabel(.search)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("search", in: glassNamespace)
    }

    private var destinationBar: some View {
        HStack(spacing: 2) {
            ForEach(PhoneLibraryDestination.allCases) { item in
                let isCurrent = item == destination
                Button {
                    destination = item
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(item.title)
                            .font(.caption2.weight(isCurrent ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .background {
                        if isCurrent {
                            Capsule().fill(Color.primary.opacity(0.08))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("library", in: glassNamespace)
    }

    private var searchButton: some View {
        Button {
            isExpanded = false
            isSearchFocused.wrappedValue = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("search", in: glassNamespace)
        .accessibilityLabel("Search library")
    }
}
