import Foundation

@objc(OtaHelper)
public class OtaHelper: NSObject {
    @objc public static func bundleURL() -> URL? {
        let fileManager = FileManager.default
        let libraryDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let otaPath = libraryDir.appendingPathComponent("ota-main.jsbundle").path
        
        // ---- Check version ----
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let defaults = UserDefaults.standard
        let lastVersion = defaults.string(forKey: "last_version")
        
        if lastVersion == nil || lastVersion != currentVersion {
            if fileManager.fileExists(atPath: otaPath) {
                try? fileManager.removeItem(atPath: otaPath)
                print("[OtaHelper] Removed old OTA bundle after app update")
            }
            if let v = currentVersion {
                defaults.set(v, forKey: "last_version")
                defaults.synchronize()
            }
        }
        
        // ---- Return bundle path ----
        if fileManager.fileExists(atPath: otaPath) {
            print("[OtaHelper] Using OTA bundle at: \(otaPath)")
            return URL(fileURLWithPath: otaPath)
        } else {
            print("[OtaHelper] Using main bundle in app")
            return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        }
    }
}
