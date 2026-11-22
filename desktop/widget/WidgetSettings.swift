import Darwin
import Foundation
import WidgetKit

enum WidgetSettings {
    static let kind = "WorldClock.Widget"

    private static var file: URL? {
        let bundle = Bundle.main
        let manager = FileManager.default
        if let group = bundle.object(forInfoDictionaryKey: "WorldClockAppGroup") as? String {
            return manager.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("widget-settings.json")
        }
        guard let path = bundle.object(forInfoDictionaryKey: "WorldClockLocalWidgetSettings") as? String,
              let home = accountHomeDirectory() else { return nil }
        return home.appendingPathComponent(path)
    }

    // Foundation resolves home directories relative to the widget's sandbox.
    private static func accountHomeDirectory() -> URL? {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let size = max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        var buffer = [CChar](repeating: 0, count: size)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &account, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let directory = account.pw_dir else { return nil }
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
    }

    static func read() -> Preferences? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    static func publish(_ preferences: Preferences) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let file, let data = try? encoder.encode(preferences),
              data != (try? Data(contentsOf: file)) else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: file, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } catch {
            NSLog("Could not share WorldClock widget settings: %@", error.localizedDescription)
        }
    }
}
