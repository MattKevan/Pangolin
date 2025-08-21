//
//  ImportProgressView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/ImportProgressView.swift
import SwiftUI

struct ImportProgressView: View {
    @ObservedObject var importer: VideoImporter
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Importing Videos")
                .font(.headline)
            
            if importer.totalFiles > 0 {
                Text("\(importer.processedFiles) of \(importer.totalFiles) files")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if !importer.currentFile.isEmpty {
                Text(importer.currentFile)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            ProgressView(value: importer.progress)
                .progressViewStyle(.linear)
                .frame(width: 300)
            
            if !importer.errors.isEmpty || !importer.skippedFolders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !importer.errors.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Errors:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            ScrollView {
                                VStack(alignment: .leading) {
                                    ForEach(importer.errors) { error in
                                        Text("• \(error.fileName): \(error.error.localizedDescription)")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            .frame(maxHeight: 80)
                        }
                    }
                    
                    if !importer.skippedFolders.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Skipped folders (permission denied):")
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            ScrollView {
                                VStack(alignment: .leading) {
                                    ForEach(importer.skippedFolders, id: \.self) { folder in
                                        Text("• \(folder)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .frame(maxHeight: 80)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("💡 To access these folders:")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                
                                Text("1. Use 'Import Videos' again")
                                Text("2. Navigate to and select the specific folder")
                                Text("3. This grants the app permission to access it")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            if !importer.isImporting {
                HStack {
                    if !importer.errors.isEmpty {
                        Text("\(importer.importedVideos.count) videos imported successfully")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 400)
        .frame(minHeight: 200)
    }
}