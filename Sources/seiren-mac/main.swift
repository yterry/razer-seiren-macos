import AppKit

// Menu-bar agent: no Dock icon, no main window. `.accessory` keeps us out of the
// Dock and the ⌘-Tab switcher while still allowing a status item and menus.
//
// We don't use @main / @NSApplicationMain here because this is a plain SwiftPM
// executable (no Info.plist principal-class wiring); building the NSApplication
// by hand is the robust, build-system-agnostic way to launch a menu-bar agent.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
