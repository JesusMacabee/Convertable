import AppKit
import ConvertableCore
import ConvertableWeb

// Phase 0 placeholder: proves the app target links AppKit + Core + Web. Menu bar UI arrives in Phase 5.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("Convertable app placeholder — menu bar UI is Phase 5. Settings at \(Settings.defaultURL.path)")
