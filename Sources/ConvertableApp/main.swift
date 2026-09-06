import AppKit

// Menu bar app entry point. No Dock icon, no main window: the status item and the web dashboard are the UI.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
