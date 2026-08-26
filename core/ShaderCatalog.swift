import Foundation
import GeneratedShaders

/// Picks which shader to run.
public enum ShaderCatalog {
    /// The shader this screensaver is for.
    ///
    /// Named explicitly rather than taken from the head of the list: the list
    /// comes out in file name order, so "the first one" quietly means
    /// whichever shader happens to sort first.
    public static let defaultName = "matrix"

    /// Resolves a shader by name, or the default when no name was given.
    /// Falls back to the first entry if the default is not in the catalog.
    public static func select(
        named name: String?,
        from programs: [ShaderProgram]
    ) -> ShaderProgram? {
        guard let name else {
            return programs.first { $0.name == defaultName } ?? programs.first
        }
        return programs.first { $0.name == name }
    }
}
