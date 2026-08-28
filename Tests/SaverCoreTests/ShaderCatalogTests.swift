import Foundation
import GeneratedShaders
import Testing

@testable import SaverCore

@Suite("shader selection")
struct ShaderCatalogTests {
    /// The screensaver starts as the Matrix rain. gradient.glsl only exists to
    /// prove the GLSL to MSL conversion works, and picking it by default is
    /// what happened when the default was "whichever shader sorts first".
    @Test("the default is the Matrix shader, not the conversion fixture")
    func defaultIsMatrix() throws {
        let program = try #require(ShaderCatalog.select(named: nil, from: GeneratedShaders.all))
        #expect(program.name == "matrix")
    }

    @Test("a name selects that shader")
    func nameSelects() throws {
        let program = try #require(ShaderCatalog.select(named: "gradient", from: GeneratedShaders.all))
        #expect(program.name == "gradient")
    }

    @Test("an unknown name selects nothing")
    func unknownNameFails() {
        #expect(ShaderCatalog.select(named: "no-such-shader", from: GeneratedShaders.all) == nil)
    }

    @Test("an empty catalog selects nothing")
    func emptyCatalog() {
        #expect(ShaderCatalog.select(named: nil, from: []) == nil)
    }

    @Test("random picks something from the catalog")
    func randomPicks() throws {
        let program = try #require(
            ShaderCatalog.select(named: ShaderCatalog.randomName, from: GeneratedShaders.all)
        )
        #expect(GeneratedShaders.all.contains { $0.name == program.name })
    }

    /// The point of keeping the fixture out of the pool: nobody locked their
    /// terminal to watch a test pattern.
    @Test("random never picks the conversion fixture")
    func randomSkipsFixtures() throws {
        for _ in 0..<200 {
            let program = try #require(
                ShaderCatalog.select(named: ShaderCatalog.randomName, from: GeneratedShaders.all)
            )
            #expect(!ShaderCatalog.fixtureNames.contains(program.name))
        }
    }

    /// With enough draws a working random picks more than one thing. Two
    /// hundred draws over a catalog this size makes a false failure about as
    /// likely as being struck by lightning indoors.
    @Test("random does not always pick the same shader")
    func randomVaries() {
        let pool = ShaderCatalog.screensavers(in: GeneratedShaders.all)
        guard pool.count > 1 else { return }

        var seen = Set<String>()
        for _ in 0..<200 {
            if let program = ShaderCatalog.select(named: ShaderCatalog.randomName, from: GeneratedShaders.all) {
                seen.insert(program.name)
            }
        }
        #expect(seen.count > 1)
    }

    /// A shader actually called "random" has to win the name, or adding
    /// random.glsl would quietly make it unreachable.
    @Test("a shader named random wins over the keyword")
    func realShaderBeatsKeyword() throws {
        let pretender = ShaderProgram(
            name: ShaderCatalog.randomName,
            summary: "not really random",
            entryPoint: "main0",
            source: ""
        )
        let program = try #require(
            ShaderCatalog.select(named: ShaderCatalog.randomName, from: [pretender])
        )
        #expect(program.summary == "not really random")
    }

    /// Everything but the fixture is something worth locking the screen for.
    @Test("the screensavers are the catalog without the fixtures")
    func screensaversExcludeFixtures() {
        let pool = ShaderCatalog.screensavers(in: GeneratedShaders.all)
        #expect(pool.count == GeneratedShaders.all.count - ShaderCatalog.fixtureNames.count)
        #expect(!pool.contains { ShaderCatalog.fixtureNames.contains($0.name) })
    }

    /// A catalog with nothing but fixtures in it still has to answer, or
    /// `--shader random` would fail on a checkout mid-rename.
    @Test("a catalog of nothing but fixtures still answers")
    func fixtureOnlyCatalog() throws {
        let onlyFixture = GeneratedShaders.all.filter { ShaderCatalog.fixtureNames.contains($0.name) }
        try #require(!onlyFixture.isEmpty)
        #expect(ShaderCatalog.select(named: ShaderCatalog.randomName, from: onlyFixture) != nil)
    }

    /// `random-pool` in the config file narrows what `random` draws from.
    @Test("random only draws from the pool it was given")
    func randomHonoursPool() throws {
        let pool = ShaderCatalog.resolvePool(["tunnel", "aurora"], in: GeneratedShaders.all).pool
        try #require(pool.count == 2)

        for _ in 0..<200 {
            let program = try #require(ShaderCatalog.select(
                named: ShaderCatalog.randomName, from: GeneratedShaders.all, randomPool: pool
            ))
            #expect(["tunnel", "aurora"].contains(program.name))
        }
    }

    /// The pool says what `random` picks, not what a name may ask for.
    @Test("a pool does not stop a shader being named")
    func poolDoesNotRestrictNames() throws {
        let pool = ShaderCatalog.resolvePool(["tunnel"], in: GeneratedShaders.all).pool
        let program = try #require(ShaderCatalog.select(
            named: "matrix", from: GeneratedShaders.all, randomPool: pool
        ))
        #expect(program.name == "matrix")
    }

    @Test("no pool leaves random drawing from the screensavers")
    func noPoolKeepsTheDefault() throws {
        for _ in 0..<50 {
            let program = try #require(ShaderCatalog.select(
                named: ShaderCatalog.randomName, from: GeneratedShaders.all, randomPool: nil
            ))
            #expect(!ShaderCatalog.fixtureNames.contains(program.name))
        }
    }

    @Test("resolving a pool reports the names that match nothing")
    func poolReportsUnknownNames() {
        let resolved = ShaderCatalog.resolvePool(["matrix", "nope", "tunnel"], in: GeneratedShaders.all)
        #expect(resolved.pool.map(\.name) == ["matrix", "tunnel"])
        #expect(resolved.unknown == ["nope"])
    }

    /// Naming a shader twice is one entry, not two chances of being drawn.
    @Test("a repeated name resolves once")
    func poolDeduplicates() {
        let resolved = ShaderCatalog.resolvePool(["matrix", "matrix"], in: GeneratedShaders.all)
        #expect(resolved.pool.map(\.name) == ["matrix"])
    }

    /// The fixture is kept out of the pool `random` builds for itself, but
    /// asking for it by name in `random-pool` is a deliberate choice.
    @Test("a pool may name the fixture")
    func poolMayNameTheFixture() {
        let resolved = ShaderCatalog.resolvePool(["gradient"], in: GeneratedShaders.all)
        #expect(resolved.pool.map(\.name) == ["gradient"])
        #expect(resolved.unknown.isEmpty)
    }

    /// The names in `fixtureNames` are matched against the catalog, so a
    /// renamed shader would leave the set pointing at nothing.
    @Test("every named fixture is in the catalog")
    func fixturesExist() {
        for name in ShaderCatalog.fixtureNames {
            #expect(GeneratedShaders.all.contains { $0.name == name }, "no shader named \(name)")
        }
    }
}
