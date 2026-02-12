# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pangolin is a macOS/iOS SwiftUI video library management application that allows users to organize, transcribe, translate, and summarize video content. It uses Core Data for local storage with CloudKit integration and supports importing videos with automatic thumbnail generation, speech transcription, and AI-powered content analysis.

## Architecture

### Core Components

- **Library Management**: Document-based architecture using `.pangolin` bundle packages containing Core Data database and media files
- **Core Data Stack**: Singleton-managed Core Data stack (`CoreDataStack.swift`) ensuring one instance per database to prevent corruption
- **Processing Pipeline**: Queue-based video processing system with transcription, translation, and summarization services
- **File System Management**: Handles video imports, thumbnail generation, and media file organization within library packages

### Key Managers & Services

- `LibraryManager`: Central coordinator for library operations, handles opening/creating libraries
- `VideoFileManager`: Manages video file operations and processing queues
- `ProcessingQueueManager`: Coordinates background processing tasks
- `TaskQueueManager`: Manages async task execution
- `SearchManager`: Handles full-text search across video content
- `SpeechTranscriptionService`: Converts speech to text using system APIs
- `SummaryService`: AI-powered content summarization

### SwiftUI Structure

- `MainView`: Primary interface with sidebar/detail split view
- `SidebarView`: Hierarchical content navigation
- `DetailView`: Video playback and content inspection
- `HierarchicalContentView`: Tree-based content organization
- Inspector panels for transcripts, translations, summaries, and metadata

## Development Commands

### Building & Testing
```bash
# Build for macOS
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' build

# Clean and build for macOS
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' clean build

# Build for iOS Simulator
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run tests
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test

# Run specific test classes
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing PangolinTests/TransferableContentTests
xcodebuild -project Pangolin.xcodeproj -scheme Pangolin -destination 'platform=macOS' test -only-testing PangolinTests/HierarchicalSidebarTests
```

### MCP Integration
The project is configured with XcodeBuildMCP for enhanced Xcode build capabilities. Build commands can also be executed through the MCP server tools for better integration with Claude Code.

## Key Data Models

- `HierarchicalContent`: Tree structure for organizing videos and folders
- `VideoModel`: Core video entity with metadata, processing status, and content
- `Library`: Container entity representing a video library
- `ProcessingTask`: Queue item for background processing operations
- `ContentTransfer`/`FolderTransfer`: Transferable types for drag & drop operations

## File Organization

- `Models/`: Core Data models and business logic entities
- `Views/`: SwiftUI view hierarchy organized by feature
- `ViewModels/`: View model classes for complex UI state management
- `Managers/`: Singleton service classes for system operations
- `Services/`: Specialized processing services (transcription, summary, etc.)
- `Import/`: Video import and processing logic
- `Utilities/`: Helper classes and extensions
- `CoreData/`: Core Data stack and persistence layer

## Important Patterns

- **Error Handling**: Custom `LibraryError` enum with recovery suggestions
- **Async/Await**: Heavy use of Swift concurrency for file operations and processing
- **Singleton Pattern**: Shared managers accessed via `.shared` property
- **Document-Based**: Uses `FileDocument` protocol for library creation/opening
- **CloudKit Sync**: Core Data + CloudKit integration for cross-device synchronization
- **Queue-Based Processing**: Background processing uses dedicated queue managers

## Testing

Tests are located in `PangolinTests/` directory. The project includes unit tests for core functionality and transferable content operations.