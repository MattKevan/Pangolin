// Views/Sidebar/CreateFolderView.swift
import SwiftUI
import CoreData

struct CreateFolderView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var store: FolderNavigationStore
    @State private var folderName = ""
    
    let parentFolderID: UUID?
    
    var body: some View {
        VStack {
            Text("Create New Folder")
                .font(.headline)
            
            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    Task {
                        await createFolder()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 150)
    }
    
    private func createFolder() async {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        await store.createFolder(name: trimmedName, in: parentFolderID)
        dismiss()
    }
}
