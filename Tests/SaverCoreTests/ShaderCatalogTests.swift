import Foundation
import GeneratedShaders
import Testing

@testable import SaverCore

@Suite("shader selection")
struct ShaderCatalogTests {
    /// The screensaver is the Matrix rain. gradient.glsl only exists to prove
    /// the GLSL to MSL conversion works, and picking it by default is what
    /// happened when the default was "whichever shader sorts first".
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
}
