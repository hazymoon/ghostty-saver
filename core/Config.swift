import Foundation

/// Defaults read from `~/.config/ghostty-saver/config`.
///
/// The screensaver is started by tmux's `lock-command`, which is a single
/// string, so a long list of flags is awkward to keep there. This is where the
/// settings that are not about measurement live instead.
///
/// Every field is optional: nil means the file said nothing about it and the
/// built-in default stands. The command line is applied on top of whatever is
/// here, so the order is command line > config file > built-in default.
///
/// Read once, at startup. A fresh process is launched on every lock, so there
/// is nothing to reload into.
public struct SaverConfig: Equatable {
    public var fps: Double?
    public var shaderName: String?
    public var quiet: QuietLevel?
    /// The names `--shader random` draws from. nil means the whole catalog
    /// minus the fixtures, which is what it has always been.
    public var randomPool: [String]?

    public init(
        fps: Double? = nil,
        shaderName: String? = nil,
        quiet: QuietLevel? = nil,
        randomPool: [String]? = nil
    ) {
        self.fps = fps
        self.shaderName = shaderName
        self.quiet = quiet
        self.randomPool = randomPool
    }

    /// Where the config is read from, honouring `XDG_CONFIG_HOME` the way
    /// Ghostty's own config does.
    public static var defaultPath: String {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("ghostty-saver/config")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty-saver/config")
    }

    /// Reads the file at `path`. A file that is not there is not an error -
    /// most installations will never have one - but a file that cannot be read
    /// is, because it was meant to say something.
    public static func load(path: String) throws -> SaverConfig {
        guard FileManager.default.fileExists(atPath: path) else { return SaverConfig() }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(path: path, reason: "\(error.localizedDescription)")
        }
        return try parse(text, path: path)
    }

    /// Parses the `key = value` lines of a config.
    ///
    /// Nothing here is quietly tolerated. The screensaver runs unattended, so
    /// a key that was ignored or a value that did not parse would show up as
    /// "it kept running at 60" long after the file was written.
    public static func parse(_ text: String, path: String = "<config>") throws -> SaverConfig {
        var config = SaverConfig()
        var seen = Set<String>()

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A comment marker only counts at the start of a line, so a value
            // is taken exactly as written.
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let separator = line.firstIndex(of: "=") else {
                throw ConfigError.malformedLine(path: path, line: number, text: line)
            }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                throw ConfigError.malformedLine(path: path, line: number, text: line)
            }
            guard !seen.contains(key) else {
                throw ConfigError.duplicateKey(path: path, line: number, key: key)
            }
            seen.insert(key)
            guard !value.isEmpty else {
                throw ConfigError.emptyValue(path: path, line: number, key: key)
            }

            func bad(_ expected: String) -> ConfigError {
                .badValue(path: path, line: number, key: key, value: value, expected: expected)
            }

            switch key {
            case "fps":
                guard let fps = Double(value), fps.isFinite, fps >= 0 else {
                    throw bad("a frame rate of zero or more (0 for uncapped)")
                }
                config.fps = fps
            case "shader":
                config.shaderName = value
            case "quiet-level":
                guard let level = Int(value), let quiet = QuietLevel(rawValue: level) else {
                    throw bad("0, 1 or 2")
                }
                config.quiet = quiet
            case "random-pool":
                // Empty pieces are kept so `matrix,,tunnel` is refused rather
                // than silently read as two names.
                let names = value.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard !names.isEmpty, !names.contains(where: \.isEmpty) else {
                    throw bad("a comma-separated list of shader names")
                }
                config.randomPool = names
            default:
                throw ConfigError.unknownKey(path: path, line: number, key: key)
            }
        }

        return config
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case malformedLine(path: String, line: Int, text: String)
    case unknownKey(path: String, line: Int, key: String)
    case duplicateKey(path: String, line: Int, key: String)
    case emptyValue(path: String, line: Int, key: String)
    case badValue(path: String, line: Int, key: String, value: String, expected: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "could not read \(path): \(reason)"
        case .malformedLine(let path, let line, let text):
            return "\(path):\(line): expected `key = value`, got: \(text)"
        case .unknownKey(let path, let line, let key):
            return "\(path):\(line): unknown key `\(key)`; known keys are "
                + "\(SaverConfig.knownKeys.joined(separator: ", "))"
        case .duplicateKey(let path, let line, let key):
            return "\(path):\(line): `\(key)` was already set; one of the two would be ignored"
        case .emptyValue(let path, let line, let key):
            return "\(path):\(line): `\(key)` has no value"
        case .badValue(let path, let line, let key, let value, let expected):
            return "\(path):\(line): `\(key) = \(value)` is not \(expected)"
        }
    }
}

extension SaverConfig {
    /// The keys a config may set, for the error that lists them.
    public static let knownKeys = ["fps", "quiet-level", "random-pool", "shader"]
}
