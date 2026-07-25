/// Module-identity marker for `iShrinkCore`.
///
/// U1 stands up the package/test scaffold with no feature logic yet; this
/// trivial public symbol exists so `SmokeTests` can prove the module actually
/// builds and links from the test target, rather than just performing a dead
/// `import`. Later units (U2+) add the real Permissions/Library/Scan/Classify/
/// etc. source groups described in the plan's Output Structure.
public enum iShrinkCoreModule {
    /// Human-readable module name, used only by `SmokeTests`.
    public static let name = "iShrinkCore"
}
