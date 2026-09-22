import AppKit
import Combine
import SwiftUI

@MainActor
final class UtilityWindows: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var statusView: StatusLabel?
    private var subscription: AnyCancellable?
    private var mainWindow: NSWindow?
    private var projectWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(showProcesses)
        updateStatus()
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PortsKiller", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        subscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatus() }
        }
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let root = MenuBarIcon(resources: model.systemResources, metric: model.menuBarMetric,
                               hasWarning: model.unknownProcessCount > 0, recovery: model.sessionRecoverySnapshot)
        let label = statusView ?? StatusLabel(rootView: root)
        label.rootView = root
        if statusView == nil { button.addSubview(label); statusView = label }
        let width = label.fittingSize.width + 12
        statusItem?.length = width
        label.frame = NSRect(x: 6, y: 0, width: width - 12, height: button.bounds.height)
        button.toolTip = "PortsKiller"
    }

    @objc private func showProcesses() {
        if mainWindow == nil {
            let content = MenuContentView(addProjectAction: { [weak self] process in self?.showProject(process) })
                .environmentObject(model)
            mainWindow = makeWindow("Processes", role: .processes, content: content)
        }
        reveal(mainWindow!)
    }

    private func showProject(_ process: DevProcess? = nil) {
        if let projectWindow, projectWindow.isVisible {
            reveal(projectWindow)
            return
        }
        let content = AddProjectView(process: process) { [weak self] in self?.projectWindow?.close() }
            .environmentObject(model)
        projectWindow = makeWindow("Add Project", role: .project, content: content)
        reveal(projectWindow!)
    }

    private func makeWindow<Content: View>(_ title: String, role: UtilityPanelSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: role.initialSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content)
        window.contentMinSize = role.minimumSize
        window.setContentSize(role.initialSize)
        window.center()
        window.setFrameAutosaveName("PortsKiller.\(title)")
        window.setFrameUsingName("PortsKiller.\(title)")
        return window
    }

    private func reveal(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showProcesses()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let remaining = [mainWindow, projectWindow].compactMap { $0 }.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized)
        }
        if !remaining { NSApp.setActivationPolicy(.accessory) }
    }
}

private final class StatusLabel: NSHostingView<MenuBarIcon> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
