import AppKit

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            return holder
        }

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services

        main.addItem(submenu("Bridge", [
            item("About Bridge", Selector(("showBridgeAbout:"))),
            .separator(),
            item("Settings…", Selector(("showSettings:")), ","),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Bridge", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option]),
            .separator(),
            item("Quit Bridge", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New Tab", Selector(("newWindowForTab:")), "t"),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Refresh", Selector(("refresh:")), "r"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", mods: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", Selector(("focusSearch:")), "f"),
        ]))
        main.addItem(submenu("View", [item("Toggle Sidebar", Selector(("toggleSidebar:")), "s", mods: [.command, .control]), .separator()] + AppSection.destinations.enumerated().map { i, s in
            item(s.title, Selector(("selectSectionFromMenu:")), i < 9 ? String(i + 1) : "", tag: AppSection.allCases.firstIndex(of: s)!)
        } + [.separator(), item("AWS Command", Selector(("toggleAWSCommand:")), "j"), item("Jump to Service…", Selector(("showCommandPalette:")), "k"),
             item("Toggle Assistant", Selector(("toggleAssistant:")), "a", mods: [.command, .shift])]))
        main.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", mods: [.command, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", mods: [.command, .shift]),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
        ]))
        main.addItem(submenu("Help", [item("Bridge Help", Selector(("showBridgeHelp:")), "?")]))
        NSApp.windowsMenu = main.items.first { $0.title == "Window" }?.submenu
        NSApp.helpMenu = main.items.first { $0.title == "Help" }?.submenu
        return main
    }
}
