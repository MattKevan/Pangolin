import SwiftUI

extension Color {
    static var appWindowBackground: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }
}

extension ShapeStyle where Self == Color {
    static var appFramedPlayerBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

func platformImage(from url: URL) -> PlatformImage? {
    #if os(macOS)
    return NSImage(contentsOf: url)
    #else
    return UIImage(contentsOfFile: url.path)
    #endif
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
