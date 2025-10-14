import BoxCommandParser

/// Entry point for the `box` executable that delegates to the Swift argument parser.
@main
struct BoxMain {
    /// Boots the async command parser and never returns unless the process exits.
    static func main() async {
        await BoxCommandParser.main()
    }
}
