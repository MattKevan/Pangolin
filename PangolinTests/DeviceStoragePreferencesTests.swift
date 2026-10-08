import Foundation
import Testing
@testable import Pangolin

struct DeviceStoragePreferencesTests {
    private func makeDefaults() -> UserDefaults {
        let name = "DeviceStoragePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Defaults are Offload to iCloud, Keep Originals and 10 GB")
    func defaultValues() {
        let defaults = makeDefaults()

        #expect(DeviceStoragePreferences.storageMode(defaults: defaults) == .optimizeStorage)
        #expect(DeviceStoragePreferences.uploadOptimization(defaults: defaults) == .original)
        #expect(DeviceStoragePreferences.cacheLimitGB(defaults: defaults) == 10)
    }

    @Test("A mode saved on the synced library is used until the device chooses one")
    func legacySyncedModeIsAFallback() {
        let defaults = makeDefaults()
        #expect(DeviceStoragePreferences.storageMode(legacySyncedValue: "keep_all_downloaded", defaults: defaults) == .keepAllDownloaded)

        DeviceStoragePreferences.setStorageMode(.optimizeStorage, defaults: defaults)
        #expect(DeviceStoragePreferences.storageMode(legacySyncedValue: "keep_all_downloaded", defaults: defaults) == .optimizeStorage)
    }

    @Test("Values written by the iOS Settings bundle are read back")
    func settingsBundleValues() {
        let defaults = makeDefaults()
        defaults.set("keep_all_downloaded", forKey: DeviceStoragePreferences.storageModeKey)
        defaults.set(25.0, forKey: DeviceStoragePreferences.cacheLimitGBKey)

        #expect(DeviceStoragePreferences.storageMode(defaults: defaults) == .keepAllDownloaded)
        #expect(DeviceStoragePreferences.cacheLimitGB(defaults: defaults) == 25)
    }

    @Test("A cache limit saved per library before the move is converted to whole gigabytes")
    func legacyCacheLimit() {
        let defaults = makeDefaults()
        let id = UUID()
        defaults.set(Int64(3) * 1024 * 1024 * 1024, forKey: "maxLocalVideoCacheBytes." + id.uuidString)

        #expect(DeviceStoragePreferences.cacheLimitGB(legacyLibraryID: id, defaults: defaults) == 3)
    }

    @Test("A cache limit below one gigabyte is raised to one")
    func cacheLimitFloor() {
        let defaults = makeDefaults()
        DeviceStoragePreferences.setCacheLimitGB(0, defaults: defaults)

        #expect(DeviceStoragePreferences.cacheLimitGB(defaults: defaults) == 1)
    }
}
