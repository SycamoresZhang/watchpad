import AppKit

setvbuf(stdout, nil, _IONBF, 0) // show log lines immediately

let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
    print("Grant Accessibility access to your terminal app (System Settings › Privacy & Security › Accessibility), then rerun.")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular) // Dock icon + ⌘Q so it behaves like a normal Mac app

// Minimal main menu so ⌘Q quits the receiver.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit WatchPointer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

let live = Live()
let receiver = Receiver(live: live)
let notch = NotchController(live: live)
app.run()
