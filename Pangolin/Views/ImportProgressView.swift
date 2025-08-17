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
                    .frame(maxHeight: 100)
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