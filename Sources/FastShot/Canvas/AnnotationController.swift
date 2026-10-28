import AppKit
import FastShotCore

/// Where a video canvas is on its timeline.
struct TimeContext {
    var current: Double
    var duration: Double
    /// How long a newly drawn mark stays on screen; `nil` keeps it to the end.
    var defaultLength: Double?
    /// While recording, marks stay open until cleared and only open ones are shown.
    var live: Bool
}

/// Owns a document's annotations and turns mouse gestures into edits: drawing,
/// selecting, moving, reshaping, restyling, deleting, undo and redo. Canvases
/// only translate events into canvas points and paint what this reports.
@MainActor
final class AnnotationController {
    private(set) var annotations: [Annotation] = []
    private(set) var selectedID: UUID?
    let tools: ToolState
    var time: TimeContext?
    /// Precise "now" for live recordings, read the moment a mark is started.
    var clock: (() -> Double)?
    var allowedTools: [EditorTool] = EditorTool.allCases
    /// Hidden from painting while its text field is open.
    var editingID: UUID?

    var onChange: (() -> Void)?
    var onDisplay: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onBeginTextEditing: ((UUID) -> Void)?

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var drag: Drag = .none
    /// A text mark created by a click; removing it on empty commit also drops its undo step.
    private var freshTextID: UUID?

    private enum Drag {
        case none
        case creating(UUID, CGPoint)
        case moving(UUID, CGPoint, registered: Bool)
        case resizing(UUID, AnnotationHandle, Annotation)
    }

    init(tools: ToolState) {
        self.tools = tools
        tools.onStyleChange = { [weak self] change in self?.applyStyle(change) }
    }

    // MARK: Reading

    var selected: Annotation? { selectedID.flatMap(annotation) }

    func annotation(_ id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    var isDragging: Bool { if case .none = drag { return false } else { return true } }

    /// Marks to paint now: on a video canvas only those alive at the playhead.
    var visible: [Annotation] {
        guard let time else { return annotations }
        return annotations.filter { a in
            if a.id == editingID { return true }
            if case .creating(let id, _) = drag, id == a.id { return true }
            return time.live ? a.end == nil : a.isVisible(at: time.current)
        }
    }

    var nextStepNumber: Int { (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    // MARK: Editing

    func load(_ items: [Annotation]) {
        annotations = items
        undoStack.removeAll()
        redoStack.removeAll()
        select(nil)
        updateUndoState()
        onDisplay?()
    }

    func select(_ id: UUID?) {
        let previous = selectedID
        selectedID = id
        if let selected { tools.sync(with: selected) }
        tools.hasSelection = id != nil
        if previous != id { onSelectionChange?() }
        onDisplay?()
    }

    func registerUndo() {
        undoStack.append(annotations)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoState()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        freshTextID = nil
        if selectedID.flatMap(annotation) == nil { select(nil) }
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        if selectedID.flatMap(annotation) == nil { select(nil) }
        changed()
    }

    func update(_ id: UUID, notify: Bool = true, _ body: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&annotations[index])
        if notify { changed() } else { onDisplay?() }
    }

    func add(_ annotation: Annotation) {
        registerUndo()
        annotations.append(annotation)
        select(annotation.id)
        changed()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        registerUndo()
        annotations.removeAll { $0.id == id }
        select(nil)
        changed()
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        registerUndo()
        annotations.removeAll()
        select(nil)
        changed()
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID else { return }
        registerUndo()
        update(id) { $0.translate(dx: dx, dy: dy) }
    }

    /// Shifts every mark, history included, so they stay put while the canvas origin moves.
    func translateAll(dx: CGFloat, dy: CGFloat) {
        func shifted(_ items: [Annotation]) -> [Annotation] {
            items.map { var a = $0; a.translate(dx: dx, dy: dy); return a }
        }
        annotations = shifted(annotations)
        undoStack = undoStack.map(shifted)
        redoStack = redoStack.map(shifted)
        onDisplay?()
    }

    /// Ends every mark still open on a live recording, as the "clear" button does.
    func closeOpenAnnotations(at time: Double) {
        guard annotations.contains(where: { $0.end == nil }) else { return }
        registerUndo()
        for index in annotations.indices where annotations[index].end == nil { annotations[index].end = max(time, annotations[index].start ?? 0) }
        select(nil)
        changed()
    }

    func finishTextEditing(_ id: UUID, text: String) {
        editingID = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.removeAll { $0.id == id }
            if freshTextID == id, !undoStack.isEmpty { undoStack.removeLast() }
            select(nil)
        } else {
            update(id, notify: false) { $0.text = text }
        }
        freshTextID = nil
        changed()
    }

    private func applyStyle(_ change: StyleChange) {
        guard let id = selectedID else { return }
        registerUndo()
        update(id) { a in
            switch change {
            case .color: a.color = tools.color
            case .size:
                a.lineWidth = tools.lineWidth
                a.fontSize = tools.fontSize
            case .filled: a.filled = tools.filled
            }
        }
    }

    private func changed() {
        updateUndoState()
        onChange?()
        onDisplay?()
    }

    private func updateUndoState() {
        tools.canUndo = !undoStack.isEmpty
        tools.canRedo = !redoStack.isEmpty
    }

    // MARK: Hit testing

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> UUID? {
        visible.last { $0.contains(p, tolerance: tolerance) }?.id
    }

    func handle(at p: CGPoint, tolerance: CGFloat) -> AnnotationHandle? {
        guard let selected, visible.contains(where: { $0.id == selected.id }) else { return nil }
        return selected.handles.first { Geometry.distance($0.1, p) <= tolerance }?.0
    }

    // MARK: Mouse

    enum MouseResult { case handled, background }

    func mouseDown(at p: CGPoint, clickCount: Int, shift: Bool, tolerance: CGFloat) -> MouseResult {
        let hit = hitTest(p, tolerance: tolerance)
        if clickCount >= 2, let hit, annotation(hit)?.kind == .text {
            select(hit)
            beginTextEditing(hit)
            return .handled
        }
        if let selected, let handle = handle(at: p, tolerance: tolerance * 1.5) {
            registerUndo()
            drag = .resizing(selected.id, handle, selected)
            return .handled
        }
        if tools.tool == .select {
            guard let hit else {
                select(nil)
                return .background
            }
            select(hit)
            drag = .moving(hit, p, registered: false)
            return .handled
        }
        guard let kind = tools.tool.kind, allowedTools.contains(tools.tool) else { return .background }
        if kind == .text, let hit, annotation(hit)?.kind == .text {
            select(hit)
            beginTextEditing(hit)
            return .handled
        }
        if let hit, hit == selectedID {
            drag = .moving(hit, p, registered: false)
            return .handled
        }
        registerUndo()
        let annotation = makeAnnotation(kind, at: p)
        annotations.append(annotation)
        select(annotation.id)
        switch kind {
        case .text:
            freshTextID = annotation.id
            beginTextEditing(annotation.id)
        case .step:
            drag = .moving(annotation.id, p, registered: true)
        default:
            drag = .creating(annotation.id, p)
        }
        changed()
        return .handled
    }

    func mouseDragged(to p: CGPoint, shift: Bool) {
        switch drag {
        case .none:
            break
        case .creating(let id, let origin):
            update(id, notify: false) { a in
                switch a.kind {
                case .pen, .marker:
                    if let last = a.points.last, Geometry.distance(last, p) >= 0.75 { a.points.append(p) }
                case .line, .arrow:
                    a.points = [origin, shift ? Geometry.snapAngle(from: origin, to: p) : p]
                case .rectangle, .ellipse, .pixelate:
                    a.points = [origin, shift ? Geometry.squareCorner(from: origin, to: p) : p]
                case .text, .step:
                    break
                }
            }
        case .moving(let id, let last, let registered):
            if !registered { registerUndo() }
            update(id, notify: false) { $0.translate(dx: p.x - last.x, dy: p.y - last.y) }
            drag = .moving(id, p, registered: true)
        case .resizing(let id, let handle, let original):
            let reshaped = Annotation.resized(original, handle: handle, to: p, constrain: shift)
            update(id, notify: false) { $0 = reshaped }
        }
    }

    func mouseUp() {
        if case .creating(let id, _) = drag, let a = annotation(id) {
            if a.isDegenerate && a.kind != .pen && a.kind != .marker {
                annotations.removeAll { $0.id == id }
                if !undoStack.isEmpty { undoStack.removeLast() }
                select(nil)
            } else if a.usesBox {
                let box = a.box
                update(id, notify: false) { $0.points = [box.origin, CGPoint(x: box.maxX, y: box.maxY)] }
            }
        }
        let wasDragging = isDragging
        drag = .none
        if wasDragging { changed() }
    }

    private func makeAnnotation(_ kind: AnnotationKind, at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, points: [p, p], color: tools.color, lineWidth: tools.lineWidth,
                           fontSize: tools.fontSize, filled: tools.filled)
        switch kind {
        case .pen, .marker, .text, .step: a.points = [p]
        default: break
        }
        if kind == .step { a.number = nextStepNumber }
        if let time {
            let now = clock?() ?? time.current
            a.start = now
            a.end = time.live ? nil : time.defaultLength.map { min(time.duration, now + $0) }
        }
        return a
    }

    private func beginTextEditing(_ id: UUID) {
        editingID = id
        drag = .none
        onBeginTextEditing?(id)
        onDisplay?()
    }

    // MARK: Cursor

    func cursor(at p: CGPoint, tolerance: CGFloat) -> NSCursor? {
        if let handle = handle(at: p, tolerance: tolerance * 1.5) { return Self.cursor(for: handle) }
        if let hit = hitTest(p, tolerance: tolerance) {
            if tools.tool == .text, annotation(hit)?.kind == .text { return .iBeam }
            if tools.tool == .select || hit == selectedID { return .openHand }
        }
        switch tools.tool {
        case .select: return nil
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    static func cursor(for handle: AnnotationHandle) -> NSCursor {
        switch handle {
        case .start, .end: return .crosshair
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .top: return .frameResize(position: .top, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .right: return .frameResize(position: .right, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .bottom: return .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .left: return .frameResize(position: .left, directions: .all)
        }
    }
}

/// Keys every editing surface understands.
@MainActor
enum EditorShortcuts {
    static func handle(_ event: NSEvent, controller: AnnotationController) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == [.command], key == "z" { controller.undo(); return true }
        if modifiers == [.command, .shift], key == "z" { controller.redo(); return true }
        if modifiers == [.command], key == "y" { controller.redo(); return true }
        if modifiers.isEmpty || modifiers == [.shift] {
            let step: CGFloat = modifiers == [.shift] ? 10 : 1
            switch Int(event.keyCode) {
            case 51, 117: // delete, forward delete
                guard controller.selected != nil else { return false }
                controller.deleteSelected()
                return true
            case 123 where controller.selected != nil: controller.nudgeSelected(dx: -step, dy: 0); return true
            case 124 where controller.selected != nil: controller.nudgeSelected(dx: step, dy: 0); return true
            case 125 where controller.selected != nil: controller.nudgeSelected(dx: 0, dy: step); return true
            case 126 where controller.selected != nil: controller.nudgeSelected(dx: 0, dy: -step); return true
            default: break
            }
        }
        if modifiers.isEmpty, let tool = controller.allowedTools.first(where: { String($0.shortcut) == key }) {
            controller.tools.tool = tool
            return true
        }
        return false
    }
}
