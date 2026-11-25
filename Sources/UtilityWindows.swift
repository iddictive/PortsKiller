import AppKit
import Combine
import SwiftUI

@MainActor
final class UtilityWindows: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let model = AppModel()
    private let showAgentsAtLaunch: Bool
    private var statusItem: NSStatusItem?
    private var statusView: StatusLabel?
    private var quickAppsPopover: NSPopover?
    private var quickAppsFocus: QuickAppsFocus?
    private var quickAppsKeyMonitor: Any?
    private weak var quickAppsPreviousWindow: NSWindow?
    private var quickAppsPreviousApplication: NSRunningApplication?
    private var restoreFocusAfterQuickApps = false
    private var closingQuickApps = false
    private var subscription: AnyCancellable?
    private var mainWindow: NSWindow?
    private var projectWindow: NSWindow?

    init(showAgentsAtLaunch: Bool = false) {
        self.showAgentsAtLaunch = showAgentsAtLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if showAgentsAtLaunch { showProcesses() }
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
        button.toolTip = "PortsKiller · Right-click for running apps"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            showQuickApps()
        } else {
            showProcesses()
        }
    }

    private func showQuickApps() {
        guard let button = statusItem?.button, button.window?.isVisible == true else { return }
        if let quickAppsPopover, quickAppsPopover.isShown {
            dismissQuickApps(restoreFocus: true)
            return
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        quickAppsPreviousApplication = previousApp?.processIdentifier != NSRunningApplication.current.processIdentifier
            ? previousApp : nil
        quickAppsPreviousWindow = quickAppsPreviousApplication == nil ? NSApp.keyWindow : nil
        restoreFocusAfterQuickApps = false
        closingQuickApps = false

        let panel = NSPopover()
        let focus = QuickAppsFocus()
        let visibleHeight = button.window?.screen?.visibleFrame.height
        let maxBodyHeight = min(QuickAppsView.maxBodyHeight, max(52, (visibleHeight ?? 700) - 142))
        panel.delegate = self
        panel.behavior = .transient
        panel.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: QuickAppsView(
            focusRequest: focus,
            maximumBodyHeight: maxBodyHeight,
            onSizeChange: { [weak self, weak panel] size in
                guard let self, let panel else { return }
                self.updateQuickAppsSize(panel, to: size)
            },
            onOpenWorkspace: { [weak self] in self?.showProcesses() }
        ))
        // The SwiftUI view owns its intrinsic size; AppKit owns screen placement.
        host.sizingOptions = []
        panel.contentViewController = host
        let size = host.sizeThatFits(in: NSSize(width: QuickAppsView.width, height: maxBodyHeight + 142))
        panel.contentSize = NSSize(width: QuickAppsView.width, height: ceil(size.height))

        quickAppsPopover = panel
        quickAppsFocus = focus
        NSApp.activate(ignoringOtherApps: true)
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
        if panel.isShown {
            installQuickAppsKeyboardMonitor()
        } else {
            clearQuickAppsState()
        }
    }

    private func updateQuickAppsSize(_ panel: NSPopover, to size: NSSize) {
        guard quickAppsPopover === panel, panel.isShown, !closingQuickApps,
              size.width > 0, size.height > 0, panel.contentSize != size else { return }
        // Keep the native entrance/exit transition, not a second animation for
        // every keystroke or when an app exits from the list.
        let animated = panel.animates
        panel.animates = false
        panel.contentSize = size
        panel.animates = animated
    }

    private func installQuickAppsKeyboardMonitor() {
        quickAppsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.quickAppsPopover, panel.isShown,
                  let window = panel.contentViewController?.view.window, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && modifiers.isEmpty { // Escape
                // First Escape belongs to an active IME candidate composition.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                self.dismissQuickApps(restoreFocus: true)
                return nil
            }
            if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.quickAppsFocus?.focusSearch()
                return nil
            }
            return event
        }
    }

    private func dismissQuickApps(restoreFocus: Bool) {
        guard let panel = quickAppsPopover, panel.isShown else { return }
        if closingQuickApps {
            if !restoreFocus { restoreFocusAfterQuickApps = false }
            return
        }
        restoreFocusAfterQuickApps = restoreFocus
        closingQuickApps = true
        panel.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        guard let panel = notification.object as? NSPopover, panel === quickAppsPopover, !closingQuickApps else { return }
        panel.contentViewController?.view.window?.makeKey()
        quickAppsFocus?.focusSearch()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPopover, panel === quickAppsPopover else { return }
        let shouldRestore = restoreFocusAfterQuickApps
        let previousWindow = quickAppsPreviousWindow
        let previousApplication = quickAppsPreviousApplication
        clearQuickAppsState()
        guard shouldRestore, NSApp.isActive else { return }
        if let previousWindow, previousWindow.isVisible, !previousWindow.isMiniaturized {
            previousWindow.makeKey()
        } else if let previousApplication, !previousApplication.isTerminated {
            _ = previousApplication.activate(options: [])
        }
    }

    private func clearQuickAppsState() {
        if let monitor = quickAppsKeyMonitor { NSEvent.removeMonitor(monitor) }
        quickAppsKeyMonitor = nil
        quickAppsPopover = nil
        quickAppsFocus = nil
        quickAppsPreviousWindow = nil
        quickAppsPreviousApplication = nil
        restoreFocusAfterQuickApps = false
        closingQuickApps = false
    }

    @objc private func showProcesses() {
        dismissQuickApps(restoreFocus: false)
        if let mainWindow {
            reveal(mainWindow)
            return
        }
        let content = MenuContentView(addProjectAction: { [weak self] process in self?.showProject(process) })
            .environmentObject(model)
        let window = makeWindow("PortsKiller", role: .processes, content: content)
        mainWindow = window
        reveal(window)
        // A fresh workspace opens for viewing, not editing. Native Tab and
        // explicit shortcuts still focus real controls; reopening keeps focus.
        window.makeFirstResponder(nil)
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
        let host = NSHostingView(rootView: content)
        if role == .processes {
            // Let the same glass extend behind the real traffic lights and
            // title. Keep all application controls below the native titlebar.
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: role.initialSize))
            material.blendingMode = .behindWindow
            material.material = .hudWindow
            material.state = .followsWindowActiveState
            window.contentView = material
            let veil = MaterialVeilHost(rootView: WindowMaterialVeil())
            veil.frame = material.bounds
            veil.autoresizingMask = [.width, .height]
            material.addSubview(veil)
            material.addSubview(host)
            host.translatesAutoresizingMaskIntoConstraints = false
            let top = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? material.safeAreaLayoutGuide.topAnchor
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: top),
                host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
        } else {
            window.contentView = host
        }
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

private struct WindowMaterialVeil: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WorkspaceStyle.canvas(solid: reduceTransparency || contrast == .increased)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

private final class MaterialVeilHost: NSHostingView<WindowMaterialVeil> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
