import AppKit
import GhosttyKit

/// Owns the native tabs belonging to each tmux attach.
final class TmuxWindows {
    var isTerminating = false
    private var sessions: [UInt64: Session] = [:]

    private final class Session {
        let gateway: BaseTerminalController?
        var windows: [UInt: TmuxTerminalController] = [:]

        init(parent: ghostty_surface_t?) {
            if let parent, let userdata = ghostty_surface_userdata(parent) {
                let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                gateway = BaseTerminalController.controller(owning: view)
            } else {
                gateway = nil
            }
        }
    }

    func apply(_ spec: UnsafeRawPointer, app: Ghostty.App) -> Bool {
        let info = ghostty_tmux_window_info(spec)
        let id = TmuxTerminalController.ID(session: info.session, window: info.window)
        if info.node_count == 0 {
            guard let session = sessions[id.session] else { return true }
            let controller = session.windows.removeValue(forKey: id.window)
            let frame = controller?.window?.frame
            let wasKey = controller?.window?.isKeyWindow ?? false
            controller?.closeFromServer()
            if session.windows.isEmpty {
                sessions.removeValue(forKey: id.session)
                if !isTerminating, let gateway = session.gateway {
                    if let frame { gateway.window?.setFrame(frame, display: false) }
                    gateway.resumePresentation(focus: wasKey)
                }
            }
            return true
        }

        let session = sessions[id.session] ?? Session(parent: info.parent)
        sessions[id.session] = session

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
                nodes[index] = .leaf(view: view)
                firstLeaves[index] = view.id
            }
        }

        let tree = Tree(root: nodes[0], zoomed: info.zoomed >= 0 ? nodes[Int(info.zoomed)] : nil)
        let controller: TmuxTerminalController
        let created: Bool
        let first = session.windows.isEmpty
        if let existing = session.windows[id.window] {
            controller = existing
            created = false
        } else {
            controller = TmuxTerminalController(app, id: id, config: config, tree: tree)
            session.windows[id.window] = controller
            created = true
        }
        let focused = info.focused >= 0 ? nodes[Int(info.focused)]?.leftmostLeaf() : nil
        let sibling = info.has_beside
            ? session.windows[info.beside]?.window
            : nil
        let after = info.has_after
            ? session.windows[info.after]?.window
            : nil
        controller.apply(info, layout: .init(tree: tree, focused: focused, splitHandles: splitHandles),
                         sibling: sibling, after: after, created: created,
                         gateway: first ? session.gateway : nil)
        return true
    }
}
