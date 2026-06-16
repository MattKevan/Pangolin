import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager

    @State private var sidebarSelections = Set<SidebarSelection>()
    @State private var isSyncingSelection = false

    var body: some View {
        List(selection: $sidebarSelections) {
            Section("Pangolin") {
                sidebarShortcutRow(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    destination: .search,
                    accessibilityID: "sidebar-search"
                )
                sidebarShortcutRow(
                    title: "Projects",
                    systemImage: "square.grid.2x2",
                    destination: .projects,
                    accessibilityID: "sidebar-projects"
                )

                ForEach(SmartCollectionKind.allCases) { smartCollection in
                    sidebarShortcutRow(
                        title: smartCollection.title,
                        systemImage: smartCollection.sidebarIcon,
                        destination: .smartCollection(smartCollection),
                        accessibilityID: "sidebar-\(smartCollection.rawValue)"
                    )
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Library")
        .contextMenu {
            Button("New project") {
                createTopLevelProject()
            }
            .disabled(libraryManager.currentLibrary == nil)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createTopLevelProject()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Add Project")
                .disabled(libraryManager.currentLibrary == nil)
            }
        }
        .onAppear {
            syncSidebarSelections(with: store.selectedSidebarItem)
        }
        .onChange(of: sidebarSelections) { oldSelection, newSelection in
            guard !isSyncingSelection else { return }
            guard oldSelection != newSelection else { return }
            store.selectedSidebarItem = newSelection.first
        }
        .onChange(of: store.selectedSidebarItem) { _, newSelection in
            syncSidebarSelections(with: newSelection)
        }
    }

    @ViewBuilder
    private func sidebarShortcutRow(
        title: String,
        systemImage: String,
        destination: SidebarSelection,
        accessibilityID: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .tag(destination)
            .accessibilityIdentifier(accessibilityID)
    }

    private func syncSidebarSelections(with selection: SidebarSelection?) {
        isSyncingSelection = true
        if let visibleSelection = visibleSelection(for: selection) {
            sidebarSelections = [visibleSelection]
        } else {
            sidebarSelections = []
        }
        isSyncingSelection = false
    }

    private func visibleSelection(for selection: SidebarSelection?) -> SidebarSelection? {
        switch selection {
        case .search, .projects, .smartCollection:
            return selection
        case .folder, .video, .none:
            return nil
        }
    }

    private func createTopLevelProject() {
        Task { @MainActor in
            guard let createdProjectID = await store.createFolder(name: "Untitled Project", in: nil),
                  let project = store.projects().first(where: { $0.id == createdProjectID }) else {
                return
            }
            store.openProject(project)
        }
    }
}
