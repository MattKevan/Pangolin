//
//  OrphanedFilesView.swift
//  Pangolin
//
//  UI for managing orphaned iCloud files
//

import SwiftUI

struct OrphanedFilesView: View {
    @ObservedObject var orphanManager: iCloudOrphanManager
    @ObservedObject var libraryManager: LibraryManager
    
    @State private var selectedFiles: Set<OrphanedFile.ID> = []
    @State private var showingActionSheet = false
    @State private var pendingAction: OrphanedFileAction?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            
            if orphanManager.isScanning {
                scanningSection
            } else if orphanManager.orphanedFiles.isEmpty {
                emptyStateSection
            } else {
                filesListSection
                actionsSection
            }
        }
        .padding()
        .alert("Confirm Deletion", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                performAction(.delete)
            }
        } message: {
            Text("Are you sure you want to move \(selectedFiles.count) file(s) to the trash? This action cannot be undone.")
        }
        .task {
            await scanForOrphans()
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Orphaned Files")
                    .font(.headline)
                Spacer()
                Button("Rescan") {
                    Task { await scanForOrphans() }
                }
                .disabled(orphanManager.isScanning)
            }
            
            Text("These video files exist in iCloud but are not tracked in your library database. You can re-import them or remove them.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var scanningSection: some View {
        VStack(spacing: 8) {
            ProgressView(value: orphanManager.scanProgress)
                .progressViewStyle(LinearProgressViewStyle())
            
            Text(orphanManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyStateSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("No Orphaned Files")
                .font(.headline)
            
            Text("All video files in your iCloud library are properly tracked in the database.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    private var filesListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Found \(orphanManager.orphanedFiles.count) orphaned files")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button(selectedFiles.count == orphanManager.orphanedFiles.count ? "Deselect All" : "Select All") {
                    if selectedFiles.count == orphanManager.orphanedFiles.count {
                        selectedFiles.removeAll()
                    } else {
                        selectedFiles = Set(orphanManager.orphanedFiles.map { $0.id })
                    }
                }
                .font(.caption)
            }
            
            List(orphanManager.orphanedFiles) { file in
                OrphanedFileRow(
                    file: file,
                    isSelected: selectedFiles.contains(file.id)
                ) {
                    if selectedFiles.contains(file.id) {
                        selectedFiles.remove(file.id)
                    } else {
                        selectedFiles.insert(file.id)
                    }
                }
            }
            .frame(height: min(300, Double(orphanManager.orphanedFiles.count * 44) + 20))
            .listStyle(PlainListStyle())
        }
    }
    
    private var actionsSection: some View {
        HStack {
            Text("\(selectedFiles.count) selected")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("Ignore Selected") {
                pendingAction = .ignore
                performAction(.ignore)
            }
            .disabled(selectedFiles.isEmpty)
            
            Button("Re-import Selected") {
                pendingAction = .reimport
                performAction(.reimport)
            }
            .disabled(selectedFiles.isEmpty)
            .buttonStyle(.borderedProminent)
            
            Button("Delete Selected") {
                pendingAction = .delete
                showingDeleteConfirmation = true
            }
            .disabled(selectedFiles.isEmpty)
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }
    
    private func scanForOrphans() async {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else {
            return
        }
        
        do {
            _ = try await orphanManager.scanForOrphanedFiles(library: library, context: context)
        } catch {
            print("❌ ORPHAN: Scan failed: \(error)")
        }
    }
    
    private func performAction(_ action: OrphanedFileAction) {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else {
            return
        }
        
        let filesToProcess = orphanManager.orphanedFiles.filter { selectedFiles.contains($0.id) }
        
        Task {
            do {
                try await orphanManager.processOrphanedFiles(filesToProcess, action: action, library: library, context: context)
                
                await MainActor.run {
                    selectedFiles.removeAll()
                }
            } catch {
                print("❌ ORPHAN: Action failed: \(error)")
            }
        }
    }
}

struct OrphanedFileRow: View {
    let file: OrphanedFile
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(file.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Image(systemName: file.iCloudStatus.systemImage)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor(for: file.iCloudStatus))
                        .help(file.iCloudStatus.displayName)
                }
                
                HStack {
                    Text(file.sizeFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("Created: \(file.createdDate, style: .date)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func statusColor(for status: iCloudFileStatus) -> Color {
        switch status {
        case .unknown: return .gray
        case .notUbiquitous: return .primary
        case .downloaded, .current, .uploaded: return .green
        case .notDownloaded: return .blue
        case .downloading, .uploading: return .orange
        case .conflicts: return .yellow
        case .error: return .red
        }
    }
}

// MARK: - Integration with Main UI

extension OrphanedFilesView {
    /// Show as a sheet from the main library view
    static func presentAsSheet(libraryManager: LibraryManager) -> some View {
        OrphanedFilesView(
            orphanManager: iCloudOrphanManager(),
            libraryManager: libraryManager
        )
    }
}

#Preview {
    OrphanedFilesView(
        orphanManager: iCloudOrphanManager(),
        libraryManager: LibraryManager.shared
    )
    .frame(width: 600, height: 500)
}