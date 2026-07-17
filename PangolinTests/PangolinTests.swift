//
//  PangolinTests.swift
//  PangolinTests
//
//  Created by Matt Kevan on 16/08/2025.
//

import Testing
import Foundation
@testable import Pangolin

struct PangolinTests {
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
}

@Suite("Video floating layout")
struct VideoFloatingLayoutTests {
    @Test("Floating state uses separate float and dock thresholds")
    func floatingStateUsesHysteresis() {
        #expect(VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: 0.25))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: 0.26))
        #expect(VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.59))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.60))
    }

    @Test("Resolution strings produce valid aspect ratios")
    func resolutionAspectRatios() {
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1920x1080") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1080X1920") - 9.0 / 16.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "invalid") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: nil) - 16.0 / 9.0) < 0.000_001)
    }

    @Test("Default frame starts at the top right and fits the inline width")
    func defaultFrame() {
        let frame = VideoFloatingLayout.defaultFrame(
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )

        #expect(frame.width == 418)
        #expect(frame.height == 235.125)
        #expect(frame.maxX == 1_184)
        #expect(frame.minY == 16)
    }

    @Test("Resizing preserves aspect ratio and the opposite corner")
    func resizingFromBottomLeading() {
        let frame = VideoFloatingLayout.resizedFrame(
            from: CGRect(x: 700, y: 16, width: 400, height: 225),
            handle: .bottomLeading,
            translation: CGSize(width: -100, height: 20),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.000_001)
        #expect(frame.maxX == 1_100)
        #expect(frame.minY == 16)
    }

    @Test("Fitting keeps an oversized-positioned frame reachable")
    func fittingFrameIntoBounds() {
        let frame = VideoFloatingLayout.fittedFrame(
            CGRect(x: 800, y: 550, width: 400, height: 225),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 900, height: 600)
        )

        #expect(frame.minX >= 16)
        #expect(frame.minY >= 16)
        #expect(frame.maxX <= 884)
        #expect(frame.maxY <= 584)
        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.000_001)
    }
}
