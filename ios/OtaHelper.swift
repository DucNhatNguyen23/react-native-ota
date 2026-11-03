import Foundation
import UIKit

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
    private static let resumePrefix = "resume_"

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
                print("[OtaHelper] OTA bundle \(defaults.double(forKey: versionKey)) did not call notifyAppReady, rolling back")
                rollback()
            } else if launchedInForeground() {
                defaults.set(true, forKey: pendingLaunchedKey)
            } else {
                // Background launch (push, location, background fetch): the OS may kill the process before JS
                // gets to notifyAppReady(). Only a foreground launch counts as a try, or a good bundle gets
                // rolled back on the next launch.
                print("[OtaHelper] Background launch, pending OTA bundle not counted as launched")
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

    /// `.background` during didFinishLaunching means the OS started the app without UI.
    /// Off the main thread the state cannot be read safely, so count it as a foreground launch.
    private static func launchedInForeground() -> Bool {
        guard Thread.isMainThread else { return true }
        return UIApplication.shared.applicationState != .background
    }

    /// Resume data of an interrupted download, kept per bundle version (see Ota.mm).
    @objc(resumeDataURLWithVersion:) public static func resumeDataURL(version: Double) -> URL {
        rootURL.appendingPathComponent("\(resumePrefix)\(version).data")
    }

    /// Deletes resume data of every version except `keep` (nil = all).
    @objc(clearResumeDataExcept:) public static func clearResumeData(except keep: NSNumber?) {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        let keepName = keep.map { resumeDataURL(version: $0.doubleValue).lastPathComponent }
        for item in items where item.hasPrefix(resumePrefix) && item != keepName {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(item))
        }
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

    @objc public static func install(fromStaging staging: URL, version: Double) throws {
        lock.lock()
        defer { lock.unlock() }

        let name = "\(version)_\(Int(Date().timeIntervalSince1970 * 1000))"
        try FileManager.default.moveItem(at: staging, to: rootURL.appendingPathComponent(name))

        if !defaults.bool(forKey: pendingKey) {
            // The current bundle is confirmed (or embedded), it becomes the rollback target.
            // Otherwise it was never confirmed, so keep the last known good one.
            setOrRemove(defaults.string(forKey: dirKey), forKey: previousDirKey)
            defaults.set(defaults.double(forKey: versionKey), forKey: previousVersionKey)
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

    // Doubles: versions can be decimals (e.g. 12.1). double(forKey:) also reads integers saved by <= 2.0.0
    @objc public static func savedVersion() -> Double {
        defaults.double(forKey: versionKey)
    }

    @objc public static func failedVersion() -> Double {
        defaults.double(forKey: failedVersionKey)
    }

    // Include the build number: a store update can bump only CFBundleVersion
    @objc public static func nativeVersion() -> String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(shortVersion)(\(build))"
    }

    private static func rollback() {
        defaults.set(defaults.double(forKey: versionKey), forKey: failedVersionKey)
        setOrRemove(defaults.string(forKey: previousDirKey), forKey: dirKey)
        defaults.set(defaults.double(forKey: previousVersionKey), forKey: versionKey)
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
        for item in items where !keep.contains(item) && !item.hasPrefix(resumePrefix) {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(item))
        }
    }
}
