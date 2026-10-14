import AppKit

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    // `FoxlumeQuery --export-icon <file.png> <size>` renders the icon for the bundle script.
    if let index = arguments.firstIndex(of: "--export-icon"), arguments.count > index + 2, let size = Int(arguments[index + 2]) {
        do {
            try AppIcon.writePNG(to: URL(fileURLWithPath: arguments[index + 1]), size: size)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
