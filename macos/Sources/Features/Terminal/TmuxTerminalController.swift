import AppKit
import GhosttyKit

/// A native tab whose panes and layout are owned by the tmux server.
final class TmuxTerminalController: TerminalController {
    struct ID: Hashable {
        let session: UInt64
        let window: UInt
    }

    private let id: ID
    private var serial: UInt64 = 0
    private var splitHandles: [UUID: UInt16] = [:]
    private var contentSize: NSSize = .zero
    private var applying = false
    private var closingFromServer = false

    init(_ app: Ghostty.App, id: ID, config: Ghostty.SurfaceConfiguration,
         tree: SplitTree<Ghostty.SurfaceView>) {
        self.id = id
        super.init(app, withBaseConfig: config, withSurfaceTree: tree)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    private var surface: ghostty_surface_t? {
        focusedSurface?.surface ?? surfaceTree.root?.leftmostLeaf().surface
    }

    func apply(_ info: ghostty_tmux_window_info_s,
               tree: SplitTree<Ghostty.SurfaceView>,
               focused: Ghostty.SurfaceView?, splitHandles: [UUID: UInt16],
               sibling: NSWindow?, after: NSWindow?, created: Bool, gateway: NSWindow?) {
        applying = true
        defer {
            applying = false
            reportSize()
        }
        serial = info.serial
        self.splitHandles = splitHandles
        surfaceTree = tree
        titleOverride = String(cString: info.title)
        focusedSurface = focused
        guard let window else { return }
        let gatewayWasKey = gateway?.isKeyWindow ?? false
        if let gateway {
            window.setFrame(gateway.frame, display: false)
            gateway.orderOut(nil)
        }
        if created {
            if let sibling {
                _ = sibling.addTabbedWindowSafely(window, ordered: .above)
            } else {
                window.orderFront(nil)
            }
        }
        if let group = window.tabGroup {
            let siblings = group.windows.filter { $0 !== window }
            let index = after.flatMap { siblings.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            if group.windows.firstIndex(of: window) != index {
                group.insertWindow(window, at: min(index, group.windows.count))
            }
            if info.select { group.selectedWindow = window }
        }
        if info.present || gatewayWasKey {
            window.makeKeyAndOrderFront(nil)
            if let focused { Ghostty.moveFocus(to: focused) }
        }
    }

    func closeFromServer() {
        closingFromServer = true
        splitHandles.removeAll()
        surfaceTree = .init()
        window?.close()
    }

    private func reportSize() {
        guard !applying, let surface, let content = window?.contentView else { return }
        let pixels = content.convertToBacking(NSRect(origin: .zero, size: contentSize)).size
        guard pixels.width > 0, pixels.height > 0 else { return }
        _ = ghostty_surface_tmux_size(surface, id.session, id.window,
                                     UInt32(pixels.width), UInt32(pixels.height))
    }

    override func terminalSizeDidChange(to size: NSSize) {
        contentSize = size
        reportSize()
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        guard !applying, let surface else { return }
        _ = ghostty_surface_tmux_select(surface, id.session, id.window)
        reportSize()
    }

    override func cellSizeDidChange(to: NSSize) {
        super.cellSizeDidChange(to: to)
        reportSize()
    }

    override func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            guard let surface, case .split(let split) = resize.node,
                  let handle = splitHandles[split.right.leftmostLeaf().id] else { return }
            _ = ghostty_surface_tmux_resize_split(surface, id.session, id.window,
                                                 serial, handle, resize.ratio)
        case .drop(let drop):
            guard let source = drop.payload.surface, let destination = drop.destination.surface else { return }
            let direction: ghostty_action_split_direction_e = switch drop.zone {
            case .top: GHOSTTY_SPLIT_DIRECTION_UP
            case .bottom: GHOSTTY_SPLIT_DIRECTION_DOWN
            case .left: GHOSTTY_SPLIT_DIRECTION_LEFT
            case .right: GHOSTTY_SPLIT_DIRECTION_RIGHT
            }
            _ = ghostty_surface_tmux_move_pane(destination, source, direction)
        }
    }

    override func relabelTabs() {
        super.relabelTabs()
        guard !applying, !closingFromServer, let surface, let window else { return }
        let peers = (window.tabGroup?.windows ?? [window]).compactMap {
            $0.windowController as? TmuxTerminalController
        }.filter { $0.id.session == id.session }
        let sibling = peers.first { $0 !== self }
        _ = ghostty_surface_tmux_regroup(surface, id.session, id.window,
                                        sibling != nil, sibling?.id.window ?? 0)
        let order = peers.map { $0.id.window }
        order.withUnsafeBufferPointer {
            if let base = $0.baseAddress {
                _ = ghostty_surface_tmux_reorder(surface, id.session, base, UInt($0.count))
            }
        }
    }

    override func closeSurface(_ node: SplitTree<Ghostty.SurfaceView>.Node,
                               withConfirmation: Bool = true) {
        guard !closingFromServer else { return }
        let close = { [weak self] in
            guard let self else { return }
            for view in node {
                if let surface = view.surface {
                    _ = ghostty_surface_tmux_close_pane(surface, self.id.session)
                }
            }
        }
        if withConfirmation && node.contains(where: { $0.needsConfirmQuit }) {
            confirmClose(messageText: "Close Terminal?",
                         informativeText: "Closing this pane ends its running programs.", completion: close)
        } else {
            close()
        }
    }

    override func closeTabImmediately(registerRedo: Bool = true) {
        guard !closingFromServer, let surface else { return }
        _ = ghostty_surface_tmux_close(surface, id.session, id.window)
    }

    @IBAction override func closeTab(_ sender: Any?) {
        if surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            confirmClose(messageText: "Close Tab?",
                         informativeText: "Closing this server tab ends its running programs.") { [weak self] in
                self?.closeTabImmediately()
            }
        } else {
            closeTabImmediately()
        }
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard !closingFromServer, let surface else { return }
        let action = "close_all_windows"
        action.withCString { _ = ghostty_surface_tmux_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
}
