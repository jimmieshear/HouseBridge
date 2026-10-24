import Foundation

/// Adds imported sections to a HouseBridge config without ever changing what is already there.
///
/// - No file: a new one is created.
/// - File present: only top-level sections it lacks (`unifi`, `homekit`) are appended at the end. The result is parsed
///   and validated *before* anything is written, every pre-existing section is checked to be unchanged, and a
///   timestamped backup of the original is kept.
public enum ConfigAppend {
    public struct Outcome: Sendable {
        public enum Action: Sendable { case created, appended, nothingToDo }
        public var action: Action
        /// Sections written by this run.
        public var added: [String] = []
        /// Sections the file already had; they were left exactly as they were.
        public var skipped: [String] = []
        public var backup: URL?
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static let managedSections = ["unifi", "homekit"]

    public static func apply(_ imported: HomebridgeImport, source: String, to url: URL, date: Date = Date()) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let text = imported.yaml(source: source, date: date)
            do { _ = try ConfigLoader.parse(text, baseDirectory: url.deletingLastPathComponent()) }
            catch { throw Failure(description: "the generated config did not validate (\(error)); nothing was written") }
            try write(text, to: url)
            return Outcome(action: .created, added: managedSections)
        }

        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(description: "could not read \(url.path) as UTF-8; it was not touched")
        }
        let base = url.deletingLastPathComponent()
        let before: [String: YAMLValue]
        do {
            guard case .map(let map) = try YAML.parse(original) else { throw Failure(description: "top level is not a map") }
            before = map
            _ = try ConfigLoader.parse(original, baseDirectory: base)
        } catch {
            throw Failure(description: "the existing \(url.path) does not load (\(error)). Fix that first; it was not touched.")
        }

        let missing = managedSections.filter { before[$0] == nil }
        let present = managedSections.filter { before[$0] != nil }
        guard !missing.isEmpty else { return Outcome(action: .nothingToDo, skipped: present) }

        var merged = original
        if !merged.hasSuffix("\n") { merged += "\n" }
        merged += "\n" + imported.appendix(sections: missing, source: source, date: date)

        // Verify before writing: it parses, it validates, and nothing that was already there changed.
        let after: [String: YAMLValue]
        do {
            guard case .map(let map) = try YAML.parse(merged) else { throw Failure(description: "top level is not a map") }
            after = map
            _ = try ConfigLoader.parse(merged, baseDirectory: base)
        } catch {
            throw Failure(description: "the merged config would not load (\(error)); nothing was written")
        }
        for (key, value) in before where after[key] != value {
            throw Failure(description: "appending would have changed the existing '\(key)' section; nothing was written")
        }
        for key in missing where after[key] == nil {
            throw Failure(description: "the appended '\(key)' section did not appear in the merged config; nothing was written")
        }

        let stampText = backupStamp(date)
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak-" + stampText)
        try fm.copyItem(at: url, to: backup)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try write(merged, to: url)
        return Outcome(action: .appended, added: missing, skipped: present, backup: backup)
    }

    private static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
