import AppKit
import GhosttyKit

/// Owns the native tabs belonging to each tmux attach.
final class TmuxWindows {
    var isTerminating = false
    private var sessions: [UInt64: Session] = [:]

    private final class Session {
        let gateway: BaseTerminalController?
        var windows: [UInt: TmuxTerminalController] = [:]
        var panes: [UInt: Ghostty.SurfaceView] = [:]
        var selected: UInt?
        var frame: NSRect?
        var requestFocus = false

        init(parent: ghostty_surface_t?) {
            if let parent, let userdata = ghostty_surface_userdata(parent) {
                let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                gateway = BaseTerminalController.controller(owning: view)
            } else {
                gateway = nil
            }
            frame = gateway?.window?.frame
            requestFocus = gateway?.suspendPresentation() ?? false
        }
    }

    func apply(_ batch: ghostty_action_tmux_window_s, app: Ghostty.App) -> Bool {
        var touched: Set<UInt64> = []
        defer { for id in touched { finishUpdate(id) } }
        var handled = true
        for index in 0..<batch.count {
            guard let spec = ghostty_tmux_window_at(batch, index) else { return false }
            let info = ghostty_tmux_window_info(spec)
            let session: Session
            if let existing = sessions[info.session] {
                session = existing
            } else if info.node_count > 0 {
                session = Session(parent: info.parent)
                sessions[info.session] = session
            } else {
                continue
            }
            touched.insert(info.session)
            if !applyWindow(spec, info: info, session: session, app: app) { handled = false }
        }
        return handled
    }

    private func finishUpdate(_ id: UInt64) {
        guard let session = sessions[id] else { return }
        var live: Set<UUID> = []
        for controller in session.windows.values {
            for view in controller.surfaceTree { live.insert(view.id) }
        }
        session.panes = session.panes.filter { live.contains($0.value.id) }
        if session.windows.isEmpty {
            sessions.removeValue(forKey: id)
            if !isTerminating, let gateway = session.gateway {
                if let frame = session.frame { gateway.window?.setFrame(frame, display: false) }
                gateway.resumePresentation(focus: session.requestFocus)
            }
            return
        }
        if !isTerminating, session.requestFocus, let selected = session.selected,
           let controller = session.windows[selected] {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        for controller in session.windows.values where !isTerminating && controller.window?.isKeyWindow == true {
            if let view = controller.focusedSurface { Ghostty.moveFocus(to: view) }
        }
        Ghostty.logger.debug("tmux presentation session=\(id) windows=\(session.windows.count) focus=\(session.requestFocus)")
        session.frame = nil
        session.requestFocus = false
    }

    private func applyWindow(_ spec: UnsafeRawPointer, info: ghostty_tmux_window_info_s,
                             session: Session, app: Ghostty.App) -> Bool {
        let id = TmuxTerminalController.ID(session: info.session, window: info.window)
        if info.node_count == 0 {
            let controller = session.windows.removeValue(forKey: id.window)
            session.frame = controller?.window?.frame ?? session.frame
            session.requestFocus = session.requestFocus || controller?.window?.isKeyWindow == true
            controller?.closeFromServer()
            return true
        }
        if info.select { session.selected = id.window }
        session.requestFocus = session.requestFocus || info.present

        guard let ghosttyApp = app.app else { return false }
        var config = info.parent.map {
            Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_TAB))
        } ?? Ghostty.SurfaceConfiguration()
        config.tmuxSession = info.session
        config.tmuxWindow = info.window

        typealias Tree = SplitTree<Ghostty.SurfaceView>
        var nodes = [Tree.Node?](repeating: nil, count: Int(info.node_count))
        var firstLeaves = [UUID?](repeating: nil, count: nodes.count)
        var splitHandles: [UUID: UInt16] = [:]
        for index in nodes.indices.reversed() {
            var value = ghostty_tmux_node_s()
            guard ghostty_tmux_window_node(spec, UInt(index), &value) else { return false }
            if value.split {
                guard let left = nodes[Int(value.left)], let right = nodes[Int(value.right)] else { return false }
                nodes[index] = .split(.init(
                    direction: value.horizontal ? .horizontal : .vertical,
                    ratio: value.ratio,
                    left: left,
                    right: right
                ))
                firstLeaves[index] = firstLeaves[Int(value.left)]
                if let divider = firstLeaves[Int(value.right)] {
                    splitHandles[divider] = UInt16(index)
                }
            } else {
                let view: Ghostty.SurfaceView
                if let surface = value.surface, let userdata = ghostty_surface_userdata(surface) {
                    view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                } else {
                    config.tmuxPane = value.pane
                    view = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
                    guard view.surface != nil else { return false }
                }
                session.panes[value.pane] = view
                nodes[index] = .leaf(view: view)
                firstLeaves[index] = view.id
            }
        }

        let layout = TmuxTerminalController.Layout(
            tree: Tree(root: nodes[0], zoomed: info.zoomed >= 0 ? nodes[Int(info.zoomed)] : nil),
            focused: info.focused >= 0 ? nodes[Int(info.focused)]?.leftmostLeaf() : nil,
            splitHandles: splitHandles
        )
        let controller: TmuxTerminalController
        let created: Bool
        let first = session.windows.isEmpty
        if let existing = session.windows[id.window] {
            controller = existing
            created = false
        } else {
            controller = TmuxTerminalController(app, id: id, config: config, layout: layout)
            session.windows[id.window] = controller
            created = true
        }
        let sibling = info.has_beside
            ? session.windows[info.beside]?.window
            : nil
        let after = info.has_after
            ? session.windows[info.after]?.window
            : nil
        controller.apply(info, layout: layout,
                         sibling: sibling, after: after, created: created,
                         frame: first ? session.frame : nil)
        return true
    }
}
