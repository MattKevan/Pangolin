//
//  PlatformUtilities.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Utilities/PlatformUtilities.swift
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PlatformUtilities {
    static var isRunningOnMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
    
    static var deviceType: String {
        #if os(macOS)
        return "Mac"
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "iPad"
        } else {
            return "iPhone"
        }
        #endif
    }
    
    static func openFilePanel(completion: @escaping (URL?) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a location for your video library"
        
        panel.begin { response in
            if response == .OK {
                completion(panel.url)
            } else {
                completion(nil)
            }
        }
        #else
        // iOS would use document picker
        completion(nil)
        #endif
    }
    
    static func selectVideosForImport(completion: @escaping ([URL]) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select videos or folders to import"
        panel.allowedContentTypes = [.movie, .video]
        
        panel.begin { response in
            if response == .OK {
                completion(panel.urls)
            } else {
                completion([])
            }
        }
        #else
        // iOS document picker implementation
        completion([])
        #endif
    }
}
