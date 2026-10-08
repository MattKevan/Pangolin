//
//  PangolinTests.swift
//  PangolinTests
//
//  Created by Matt Kevan on 16/08/2025.
//

import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin

@MainActor

struct PangolinTests {
    @Test("Sidebar project selection opens projects only")
    func sidebarProjectSelectionPolicyOpensOnlyProjects() {
        #expect(SidebarProjectSelectionPolicy.canOpen(isProject: true))
        #expect(!SidebarProjectSelectionPolicy.canOpen(isProject: false))
    }

    @Test("Sidebar highlights an open project instead of the projects shortcut")
    func sidebarProjectSelectionPolicyHighlightsOpenProject() {
        #expect(SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: true,
            hasSelectedProject: true
        ))
        #expect(!SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: true,
            hasSelectedProject: false
        ))
        #expect(!SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: false,
            hasSelectedProject: true
        ))
    }

    @Test("Sidebar projects shortcut resets an open project detail")
    func sidebarProjectSelectionPolicyResetsProjectDetailForProjectsShortcut() {
        #expect(SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: true,
            hasSelectedProject: true
        ))
        #expect(!SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: true,
            hasSelectedProject: false
        ))
        #expect(!SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: false,
            hasSelectedProject: true
        ))
    }

    @Test("Sidebar project rows keep the folder outline icon while renaming")
    func sidebarProjectRowUsesFolderOutlineIcon() {
        #expect(SidebarProjectRowPresentation.systemImage == "folder")
    }

    @Test("Sidebar project row identity survives a Core Data object ID promotion")
    func sidebarProjectRowIdentityUsesProjectUUID() {
        let projectID = UUID()
        let temporaryObjectURI = URL(string: "x-coredata://temporary/project")!
        let permanentObjectURI = URL(string: "x-coredata://permanent/project")!

        #expect(ProjectSidebarRowIdentity.value(
            projectID: projectID,
            objectURI: temporaryObjectURI
        ) == ProjectSidebarRowIdentity.value(
            projectID: projectID,
            objectURI: permanentObjectURI
        ))
    }

    @Test("File commands use the standard create and open shortcuts")
    func fileCommandsUseStandardShortcuts() {
        #expect(FileCommandPolicy.newProjectShortcut == "n")
        #expect(FileCommandPolicy.importVideosShortcut == "o")
    }

    @Test("Storage policy schedules only optimized libraries")
    func storagePolicySchedulesOnlyOptimizedLibraries() {
        #expect(StoragePolicyWorkPolicy.shouldScheduleAutomatically(for: .optimizeStorage))
        #expect(!StoragePolicyWorkPolicy.shouldScheduleAutomatically(for: .keepAllDownloaded))
    }

    @Test("Video table opens a single selected row")
    func videoTableOpensSingleSelectedRow() {
        #expect(VideoTableInteractionPolicy.shouldOpen(selectionCount: 1))
        #expect(!VideoTableInteractionPolicy.shouldOpen(selectionCount: 2))
    }

    @Test("Dragging a selected table row carries the full selection")
    func videoTableDragUsesTheCurrentMultiSelection() {
        let first = UUID()
        let second = UUID()

        #expect(VideoTableDragPolicy.videoIDs(
            for: first,
            selection: [first, second]
        ) == Set([first, second]))
        #expect(VideoTableDragPolicy.videoIDs(
            for: first,
            selection: [second]
        ) == Set([first]))
    }

    @Test("External folder drops are limited to project folders")
    func externalProjectDropFiltersOutVideoFiles() {
        let folder = URL(fileURLWithPath: "/tmp/Project", isDirectory: true)
        let video = URL(fileURLWithPath: "/tmp/video.mp4")

        #expect(ExternalImportDropPolicy.importURLs(
            from: [folder, video],
            foldersOnly: true
        ) == [folder])
        #expect(ExternalImportDropPolicy.importURLs(
            from: [folder, video],
            foldersOnly: false
        ) == [folder, video])
    }

    @Test("Balanced upload optimisation uses the recommended HEVC 1080p preset")
    func balancedUploadOptimisationPreset() {
        #expect(VideoUploadOptimizationPreset.original.isEnabled == false)
        #expect(VideoUploadOptimizationPreset.balanced.isEnabled)
        #expect(VideoUploadOptimizationPreset.balanced.exportPresetName == AVAssetExportPresetHEVC1920x1080)
    }

    @Test("Upload optimisation skips videos already below the selected target")
    func uploadOptimisationSkipsSmallVideos() {
        #expect(!VideoUploadOptimizationPreset.balanced.needsOptimization(
            fileSize: 500_000,
            duration: 1,
            resolution: "1280x720"
        ))
        #expect(VideoUploadOptimizationPreset.balanced.needsOptimization(
            fileSize: 5_000_000,
            duration: 1,
            resolution: "3840x2160"
        ))
    }

    @Test("Table drag metadata is indexed once by video ID")
    func videoTableDragMetadataUsesStableIDs() {
        let first = UUID()
        let second = UUID()
        let descriptors = [
            VideoFileExportDescriptor(id: first, fileName: "one.mp4", fileTypeIdentifier: "public.mpeg-4"),
            VideoFileExportDescriptor(id: second, fileName: "two.mov", fileTypeIdentifier: "com.apple.quicktime-movie")
        ]

        let indexed = VideoTablePresentationPolicy.descriptorMap(descriptors)
        #expect(indexed.count == 2)
        #expect(indexed[first]?.fileName == "one.mp4")
        #expect(indexed[second]?.fileName == "two.mov")
    }

    @Test("Duplicate video IDs keep the first descriptor instead of trapping")
    func videoTableDragMetadataToleratesDuplicateIDs() {
        let id = UUID()
        let descriptors = [
            VideoFileExportDescriptor(id: id, fileName: "first.mp4", fileTypeIdentifier: "public.mpeg-4"),
            VideoFileExportDescriptor(id: id, fileName: "second.mp4", fileTypeIdentifier: "public.mpeg-4")
        ]

        let indexed = VideoTablePresentationPolicy.descriptorMap(descriptors)

        #expect(indexed.count == 1)
        #expect(indexed[id]?.fileName == "first.mp4")
    }

    @Test("Project sidebar drops require videos and a project destination")
    func projectSidebarDropRequiresVideoIDsAndProject() {
        #expect(ProjectSidebarDropPolicy.canMove(videoIDs: [UUID()], isProject: true))
        #expect(!ProjectSidebarDropPolicy.canMove(videoIDs: [], isProject: true))
        #expect(!ProjectSidebarDropPolicy.canMove(videoIDs: [UUID()], isProject: false))
    }

    @Test("Project sidebar drops do not consume an empty payload")
    func projectSidebarDropDoesNotConsumeAnEmptyPayload() {
        #expect(!ProjectSidebarDropPolicy.shouldConsumePayload(
            videoIDs: [],
            isProject: true,
            hasAlreadyHandledSession: false
        ))
        #expect(ProjectSidebarDropPolicy.shouldConsumePayload(
            videoIDs: [UUID()],
            isProject: true,
            hasAlreadyHandledSession: false
        ))
    }

    @Test("Core Data store file protection uses a valid protection class string")
    func persistentStoreFileProtectionUsesValidString() {
        #expect(
            CoreDataStack.persistentStoreFileProtectionOptionValue
                == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
    }

    @Test("iOS Info plist enables remote notifications for CloudKit")
    func infoPlistIncludesRemoteNotificationBackgroundMode() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pangolin/Info-iOS.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(plist as? [String: Any])
        let backgroundModes = try #require(dictionary["UIBackgroundModes"] as? [String])

        #expect(backgroundModes.contains("remote-notification"))
    }

    @Test("Platform Info plists export the video-table drag type")
    func platformInfoPlistsExportVideoTableDragType() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let typeIdentifier = "com.newindustries.pangolin.video-table-drag"

        for plistName in ["Info-iOS.plist", "Info-macOS.plist"] {
            let plistURL = projectRoot.appendingPathComponent("Pangolin/\(plistName)")
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let dictionary = try #require(plist as? [String: Any])
            let declarations = try #require(dictionary["UTExportedTypeDeclarations"] as? [[String: Any]])

            #expect(declarations.contains { declaration in
                declaration["UTTypeIdentifier"] as? String == typeIdentifier
            })
        }
    }
}
