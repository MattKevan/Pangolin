//
//  LibraryDocument.swift
//  Pangolin
//
//  Document type for creating new .pangolin libraries
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var pangolinLibrary: UTType {
        UTType(importedAs: "com.pangolin.library")
    }
}

struct LibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pangolinLibrary] }

    // Empty document - the actual library structure will be created by LibraryManager
    init() {}

    init(configuration: ReadConfiguration) throws {
        // Not used for creation, but required by FileDocument
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Return empty file wrapper - the actual directory structure
        // will be created by LibraryManager after the user chooses location
        return FileWrapper(regularFileWithContents: Data())
    }
}