import Foundation

/// Owns the OTA bundle state. Layout:
///   Library/ota/<version>_<timestamp>/main.jsbundle + assets/  (one folder per install)
///   Library/ota/staging/  (download in progress)
///
/// A new bundle starts as "pending". The first launch marks it as launched; if JS does not call
/// notifyAppReady() before the next launch, the bundle is considered broken and rolled back.
@objc(OtaHelper)
public class OtaHelper: NSObject {
    private static let bundleName = "main.jsbundle"
    private static let stagingDirName = "staging"

    private static let lastVersionKey = "last_version"
    private static let versionKey = "ota_bundle_version"
    private static let dirKey = "ota_current_dir"
    private static let previousVersionKey = "ota_previous_version"
    private static let previousDirKey = "ota_previous_dir"
    private static let pendingKey = "ota_pending"
    private static let pendingLaunchedKey = "ota_pending_launched"
    private static let failedVersionKey = "ota_failed_version"
    private static let stateKeys = [
        versionKey, dirKey, previousVersionKey, previousDirKey,
        pendingKey, pendingLaunchedKey, failedVersionKey,
    ]

    private static let lock = NSLock()
    private static var defaults: UserDefaults { .standard }
    // bundleURL() can be called several times per launch: count each pending bundle once
    private static var checkedPendingDir: String?
    private static var runningDir: String?

    private static var rootURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ota")
    }

    @objc public static func bundleURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let native = nativeVersion()
        if defaults.string(forKey: lastVersionKey) != native {
            stateKeys.forEach { defaults.removeObject(forKey: $0) }
            defaults.set(native, forKey: lastVersionKey)
            try? FileManager.default.removeItem(at: rootURL)
            // Legacy location (<= 1.0.1)
            try? FileManager.default.removeItem(
                at: rootURL.deletingLastPathComponent().appendingPathComponent("ota-main.jsbundle"))
            print("[OtaHelper] Native version changed to \(native), removed OTA bundles")
        }

        if defaults.bool(forKey: pendingKey), let dir = defaults.string(forKey: dirKey),
           checkedPendingDir != dir {
            checkedPendingDir = dir
            if defaults.bool(forKey: pendingLaunchedKey) {
                print("[OtaHelper] OTA bundle \(defaults.integer(forKey: versionKey)) did not call notifyAppReady, rolling back")
                rollback()
            } else {
                defaults.set(true, forKey: pendingLaunchedKey)
            }
        }

        var bundle = currentBundleURL()
        if bundle == nil, defaults.string(forKey: dirKey) != nil {
            print("[OtaHelper] OTA bundle files missing, rolling back")
            rollback()
            bundle = currentBundleURL()
            if bundle == nil {
                defaults.removeObject(forKey: dirKey)
                defaults.removeObject(forKey: versionKey)
            }
        }

        runningDir = bundle == nil ? nil : defaults.string(forKey: dirKey)
        cleanup()

        if let bundle = bundle {
            print("[OtaHelper] Using OTA bundle at: \(bundle.path)")
            return bundle
        }
        print("[OtaHelper] Using main bundle in app")
        return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
    }

    @objc public static func stagingURL() -> URL {
        var root = rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bundles can be downloaded again, keep them out of iCloud backups
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root.appendingPathComponent(stagingDirName)
    }

    @objc public static func install(fromStaging staging: URL, version: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        let name = "\(version)_\(Int(Date().timeIntervalSince1970 * 1000))"
        try FileManager.default.moveItem(at: staging, to: rootURL.appendingPathComponent(name))

        if !defaults.bool(forKey: pendingKey) {
            // The current bundle is confirmed (or embedded), it becomes the rollback target.
            // Otherwise it was never confirmed, so keep the last known good one.
            setOrRemove(defaults.string(forKey: dirKey), forKey: previousDirKey)
            defaults.set(defaults.integer(forKey: versionKey), forKey: previousVersionKey)
        }
        defaults.set(name, forKey: dirKey)
        defaults.set(version, forKey: versionKey)
        defaults.set(true, forKey: pendingKey)
        defaults.set(false, forKey: pendingLaunchedKey)

        cleanup()
    }

    @objc public static func notifyAppReady() {
        lock.lock()
        defer { lock.unlock() }

        guard defaults.bool(forKey: pendingKey) else { return }
        // A bundle downloaded during this session is not running yet, it must not be confirmed
        guard let running = runningDir, running == defaults.string(forKey: dirKey) else { return }

        [pendingKey, pendingLaunchedKey, previousDirKey, previousVersionKey]
            .forEach { defaults.removeObject(forKey: $0) }
        cleanup()
    }

    @objc public static func clear() {
        lock.lock()
        defer { lock.unlock() }

        stateKeys.forEach { defaults.removeObject(forKey: $0) }
        cleanup()
    }

    @objc public static func savedVersion() -> Int {
        defaults.integer(forKey: versionKey)
    }

    @objc public static func failedVersion() -> Int {
        defaults.integer(forKey: failedVersionKey)
    }

    // Include the build number: a store update can bump only CFBundleVersion
    @objc public static func nativeVersion() -> String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(shortVersion)(\(build))"
    }

    private static func rollback() {
        defaults.set(defaults.integer(forKey: versionKey), forKey: failedVersionKey)
        setOrRemove(defaults.string(forKey: previousDirKey), forKey: dirKey)
        defaults.set(defaults.integer(forKey: previousVersionKey), forKey: versionKey)
        [previousDirKey, previousVersionKey, pendingKey, pendingLaunchedKey]
            .forEach { defaults.removeObject(forKey: $0) }
    }

    private static func currentBundleURL() -> URL? {
        guard let dir = defaults.string(forKey: dirKey) else { return nil }
        let url = rootURL.appendingPathComponent(dir).appendingPathComponent(bundleName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func setOrRemove(_ value: String?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // Deletes every install folder that is not current, previous, running or being downloaded
    private static func cleanup() {
        let keep: Set<String?> = [
            defaults.string(forKey: dirKey),
            defaults.string(forKey: previousDirKey),
            runningDir,
            stagingDirName,
        ]
        let items = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        for item in items where !keep.contains(item) {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(item))
        }
    }
}
