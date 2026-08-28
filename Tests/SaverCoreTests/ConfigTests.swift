import Foundation
import Testing

@testable import SaverCore

@Suite("config file")
struct ConfigTests {
    @Test("a key = value line sets the key")
    func setsKeys() throws {
        let config = try SaverConfig.parse("""
        fps = 30
        shader = starwars
        quiet-level = 2
        random-pool = matrix, starwars
        """)
        #expect(config.fps == 30)
        #expect(config.shaderName == "starwars")
        #expect(config.quiet == .silent)
        #expect(config.randomPool == ["matrix", "starwars"])
    }

    @Test("an empty file sets nothing")
    func emptyFile() throws {
        #expect(try SaverConfig.parse("") == SaverConfig())
    }

    @Test("comments and blank lines are skipped")
    func commentsSkipped() throws {
        let config = try SaverConfig.parse("""
        # the screensaver runs at half rate on battery

          # indented comment
        fps = 30
        """)
        #expect(config.fps == 30)
        #expect(config.shaderName == nil)
    }

    /// A comment marker only counts at the start of a line, so nothing has to
    /// be escaped to put one in a value.
    @Test("a hash inside a value is part of the value")
    func hashInValue() throws {
        let config = try SaverConfig.parse("shader = matrix#1")
        #expect(config.shaderName == "matrix#1")
    }

    @Test("whitespace around the key and the value is ignored")
    func whitespaceIgnored() throws {
        let config = try SaverConfig.parse("   fps   =   24   ")
        #expect(config.fps == 24)
    }

    @Test("zero fps is the uncapped setting, not a bad value")
    func zeroFPS() throws {
        #expect(try SaverConfig.parse("fps = 0").fps == 0)
    }

    /// The whole point of the file is that a setting is not quietly dropped:
    /// nobody watches a lock screen closely enough to notice `fps = 30` having
    /// no effect.
    @Test("an unknown key fails")
    func unknownKeyFails() {
        #expect(throws: ConfigError.unknownKey(path: "<config>", line: 1, key: "framerate")) {
            try SaverConfig.parse("framerate = 30")
        }
    }

    @Test("a line without an equals sign fails")
    func malformedLineFails() {
        #expect(throws: ConfigError.malformedLine(path: "<config>", line: 2, text: "fps 30")) {
            try SaverConfig.parse("shader = matrix\nfps 30")
        }
    }

    @Test("a key with no value fails")
    func emptyValueFails() {
        #expect(throws: ConfigError.emptyValue(path: "<config>", line: 1, key: "shader")) {
            try SaverConfig.parse("shader =")
        }
    }

    @Test("a line that is only an equals sign fails")
    func emptyKeyFails() {
        #expect(throws: ConfigError.malformedLine(path: "<config>", line: 1, text: "= 30")) {
            try SaverConfig.parse("= 30")
        }
    }

    @Test(
        "a value that does not parse fails",
        arguments: ["fps = fast", "fps = -1", "fps = nan", "quiet-level = 3", "quiet-level = two"]
    )
    func badValueFails(line: String) {
        #expect(throws: ConfigError.self) { try SaverConfig.parse(line) }
    }

    /// Setting the same key twice means one of them does nothing, which is the
    /// silent drop this file exists to avoid.
    @Test("the same key twice fails")
    func duplicateKeyFails() {
        #expect(throws: ConfigError.duplicateKey(path: "<config>", line: 2, key: "fps")) {
            try SaverConfig.parse("fps = 30\nfps = 60")
        }
    }

    @Test("an empty name in the pool fails")
    func emptyPoolEntryFails() {
        #expect(throws: ConfigError.self) { try SaverConfig.parse("random-pool = matrix,,tunnel") }
    }

    @Test("the error names the file and the line")
    func errorLocatesItself() {
        let error = ConfigError.unknownKey(path: "/tmp/config", line: 7, key: "colour")
        #expect(error.description.hasPrefix("/tmp/config:7:"))
        #expect(error.description.contains("colour"))
    }

    @Test("a missing file is not an error")
    func missingFileIsFine() throws {
        let path = NSTemporaryDirectory() + "/ghostty-saver-no-such-config-\(UUID().uuidString)"
        #expect(try SaverConfig.load(path: path) == SaverConfig())
    }

    @Test("a file on disk is read")
    func readsFromDisk() throws {
        let path = NSTemporaryDirectory() + "/ghostty-saver-config-\(UUID().uuidString)"
        try "shader = tunnel\nfps = 30\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try SaverConfig.load(path: path)
        #expect(config.shaderName == "tunnel")
        #expect(config.fps == 30)
    }

    @Test("the default path is under ~/.config unless XDG_CONFIG_HOME says otherwise")
    func defaultPathShape() {
        let path = SaverConfig.defaultPath
        #expect(path.hasSuffix("/ghostty-saver/config"))
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            #expect(path.hasPrefix(xdg))
        } else {
            #expect(path.hasPrefix(NSHomeDirectory() + "/.config/"))
        }
    }
}
