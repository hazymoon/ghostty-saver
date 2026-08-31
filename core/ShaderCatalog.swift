import Foundation
import GeneratedShaders

/// Picks which shader to run.
public enum ShaderCatalog {
    /// The shader this screensaver starts with.
    ///
    /// Named explicitly rather than taken from the head of the list: the list
    /// comes out in file name order, so "the first one" quietly means
    /// whichever shader happens to sort first.
    public static let defaultName = "matrix"

    /// Shaders that exist for the build rather than for looking at.
    ///
    /// `gradient.glsl` is there to prove the GLSL to MSL conversion works. It
    /// can still be asked for by name, but it is not a screensaver, so it is
    /// kept out of the pool `random` draws from.
    public static let fixtureNames: Set<String> = ["gradient"]

    /// Shaders that are being reworked and are not ready to be shown.
    ///
    /// They still compile, still run under their name, and are still tested,
    /// so the work on them stays in the tree rather than on a branch that
    /// drifts. But `random` does not draw them and `--list-shaders` does not
    /// offer them: a screensaver that comes up unasked for has to be one that
    /// is finished, and a list is a recommendation.
    public static let draftNames: Set<String> = ["moire", "raindrops", "raster", "toasters"]

    /// Ask for this instead of a name to get one of the screensavers at random.
    /// A shader actually called this would win the name, so the keyword can
    /// never shadow a real one.
    public static let randomName = "random"

    /// Everything `--list-shaders` should offer, in catalog order: the
    /// fixture included, since it is documented and there for anyone checking
    /// the conversion, but nothing that is still being reworked.
    public static func listable(in programs: [ShaderProgram]) -> [ShaderProgram] {
        programs.filter { !draftNames.contains($0.name) }
    }

    /// Everything worth watching, in catalog order.
    public static func screensavers(in programs: [ShaderProgram]) -> [ShaderProgram] {
        let watchable = programs.filter {
            !fixtureNames.contains($0.name) && !draftNames.contains($0.name)
        }
        // A catalog of nothing but fixtures and drafts is still better
        // answered with one of those than with nothing at all.
        return watchable.isEmpty ? programs : watchable
    }

    /// Resolves a shader by name, or the default when no name was given.
    /// Falls back to the first entry if the default is not in the catalog.
    ///
    /// `randomPool` narrows what `random` draws from - the config file's
    /// `random-pool` key. Nil leaves it as the whole catalog minus the
    /// fixtures.
    public static func select(
        named name: String?,
        from programs: [ShaderProgram],
        randomPool: [ShaderProgram]? = nil
    ) -> ShaderProgram? {
        guard let name else {
            return programs.first { $0.name == defaultName } ?? programs.first
        }
        if let named = programs.first(where: { $0.name == name }) {
            return named
        }
        if name == randomName {
            let pool = randomPool.flatMap { $0.isEmpty ? nil : $0 } ?? screensavers(in: programs)
            return pool.randomElement()
        }
        return nil
    }

    /// Turns the names a `random-pool` setting lists into programs.
    ///
    /// Names that match nothing come back separately rather than being
    /// dropped: a pool with a typo in it would otherwise quietly become a
    /// smaller pool.
    public static func resolvePool(
        _ names: [String],
        in programs: [ShaderProgram]
    ) -> (pool: [ShaderProgram], unknown: [String]) {
        var pool: [ShaderProgram] = []
        var unknown: [String] = []
        for name in names {
            if let program = programs.first(where: { $0.name == name }) {
                // A name written twice is one entry, not two chances of being
                // drawn.
                if !pool.contains(where: { $0.name == program.name }) { pool.append(program) }
            } else {
                unknown.append(name)
            }
        }
        return (pool, unknown)
    }
}
