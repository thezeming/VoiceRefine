import AppKit

PrefDefaults.registerAll()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
