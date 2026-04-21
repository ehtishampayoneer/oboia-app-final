import UIKit
import ARKit

// MARK: - Tool Enum

enum CutTool: String {
    case smart     = "smart"
    case freehand  = "draw"
    case rectangle = "rect"
    case circle    = "circle"
}

// MARK: - Delegate

protocol CutModeOverlayDelegate: AnyObject {
    func cutOverlay(_ overlay: CutModeOverlay, didRequestSmartCutAt screenPoint: CGPoint)
    func cutOverlay(_ overlay: CutModeOverlay, didCompleteFreehand uvPoints: [CGPoint])
    func cutOverlay(_ overlay: CutModeOverlay, didCompleteRectangle screenRect: CGRect)
    func cutOverlay(_ overlay: CutModeOverlay, didCompleteCircle screenCenter: CGPoint, radius: CGFloat)
    func cutOverlayDidRequestUndo(_ overlay: CutModeOverlay)
    func cutOverlayDidRequestClear(_ overlay: CutModeOverlay)
    func cutOverlayDidRequestDone(_ overlay: CutModeOverlay)
    func cutOverlay(_ overlay: CutModeOverlay, didChangeTool tool: CutTool)
}

// MARK: - CutModeOverlay

final class CutModeOverlay: UIView {

    // MARK: - Public
    weak var delegate: CutModeOverlayDelegate?
    var sceneView: ARSCNView?

    private(set) var activeTool: CutTool = .smart

    // MARK: - Drawing state
    private var touchPoints: [CGPoint] = []
    private var dragStart:   CGPoint   = .zero
    private var dragCurrent: CGPoint   = .zero
    private var isDrawing = false

    // MARK: - UI
    private let drawLayer     = CAShapeLayer()
    private let instructionPill = UIView()
    private let instructionLabel = UILabel()
    private var marchTimer: CADisplayLink?
    private var dashPhase: CGFloat = 0

    private let goldColor = UIColor(red: 1.0, green: 0.827, blue: 0.412, alpha: 1)  // #FFD369
    private let bgColor   = UIColor(white: 0.04, alpha: 0.92)

    // Tool buttons
    private var toolButtons: [CutTool: UIButton] = [:]
    private var undoButton: UIButton!
    private var clearButton: UIButton!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        setupDrawLayer()
        setupInstructionPill()
        setupMarchTimer()
    }

    // MARK: - Setup Subviews

    private func setupDrawLayer() {
        drawLayer.fillColor       = nil
        drawLayer.strokeColor     = goldColor.cgColor
        drawLayer.lineWidth       = 2.5
        drawLayer.lineDashPattern = [8, 4]
        drawLayer.lineDashPhase   = 0
        drawLayer.lineJoin        = .round
        drawLayer.lineCap         = .round
        layer.addSublayer(drawLayer)
    }

    private func setupInstructionPill() {
        instructionPill.backgroundColor    = goldColor
        instructionPill.layer.cornerRadius = 14
        instructionPill.alpha              = 0
        addSubview(instructionPill)

        instructionLabel.font          = .systemFont(ofSize: 13, weight: .semibold)
        instructionLabel.textColor     = UIColor(white: 0.08, alpha: 1)
        instructionLabel.textAlignment = .center
        instructionPill.addSubview(instructionLabel)

        // Layout
        instructionPill.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            instructionPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructionPill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 72),
            instructionPill.heightAnchor.constraint(equalToConstant: 36),
            instructionLabel.centerXAnchor.constraint(equalTo: instructionPill.centerXAnchor),
            instructionLabel.centerYAnchor.constraint(equalTo: instructionPill.centerYAnchor),
            instructionLabel.leadingAnchor.constraint(equalTo: instructionPill.leadingAnchor, constant: 16),
            instructionLabel.trailingAnchor.constraint(equalTo: instructionPill.trailingAnchor, constant: -16)
        ])
    }

    private func setupMarchTimer() {
        marchTimer = CADisplayLink(target: self, selector: #selector(tickMarch))
        marchTimer?.preferredFramesPerSecond = 30
        marchTimer?.add(to: .main, forMode: .common)
        marchTimer?.isPaused = true
    }

    @objc private func tickMarch() {
        dashPhase -= 1.5
        drawLayer.lineDashPhase = dashPhase
    }

    // MARK: - Public API

    func showWithTool(_ tool: CutTool) {
        activeTool = tool
        updateInstruction()
        UIView.animate(withDuration: 0.22) {
            self.instructionPill.alpha = 1
        }
        marchTimer?.isPaused = false
    }

    func hide() {
        marchTimer?.isPaused = true
        UIView.animate(withDuration: 0.18) {
            self.instructionPill.alpha = 0
            self.drawLayer.path = nil
        }
    }

    func setActiveTool(_ tool: CutTool) {
        activeTool = tool
        clearDrawState()
        updateInstruction()
    }

    func flashCutApplied() {
        let flash = CABasicAnimation(keyPath: "opacity")
        flash.fromValue = 0.0
        flash.toValue   = 1.0
        flash.duration  = 0.08
        flash.autoreverses = true
        flash.repeatCount  = 2
        drawLayer.add(flash, forKey: "flash")
    }

    // MARK: - Touch Handling

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass touches through to Flutter in top toolbar zone
        let safeTop       = safeAreaInsets.top
        let toolbarHeight = safeTop + 56
        if point.y < toolbarHeight { return nil }
        // Pass through when not drawing and not smart-tapping
        if !isDrawing && activeTool == .smart { return self }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self) else { return }

        switch activeTool {
        case .smart:
            delegate?.cutOverlay(self, didRequestSmartCutAt: pt)

        case .freehand:
            touchPoints = [pt]
            isDrawing   = true
            updateFreehandPath()

        case .rectangle, .circle:
            dragStart   = pt
            dragCurrent = pt
            isDrawing   = true
            updateDragPath()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self), isDrawing else { return }

        switch activeTool {
        case .freehand:
            touchPoints.append(pt)
            // Downsample for performance: keep every 3rd point during move
            if touchPoints.count > 3 && touchPoints.count % 3 != 0 {
                touchPoints.removeLast()
            }
            updateFreehandPath()

        case .rectangle, .circle:
            dragCurrent = pt
            updateDragPath()

        case .smart:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self), isDrawing else { return }
        isDrawing = false

        switch activeTool {
        case .freehand:
            touchPoints.append(pt)
            guard touchPoints.count >= 3 else { clearDrawState(); return }

            // Convert screen points to UV via raycast
            guard let sv = sceneView else { clearDrawState(); return }
            var uvPts: [CGPoint] = []
            let cutTool = WallpaperCutTool()
            // Note: UV conversion is done in ARWallpaperView after receiving points
            // We send raw screen points; ARWallpaperView converts them
            delegate?.cutOverlay(self, didCompleteFreehand: touchPoints)
            clearDrawState()

        case .rectangle:
            let rect = normalizedRect(from: dragStart, to: pt)
            guard rect.width > 10, rect.height > 10 else { clearDrawState(); return }
            delegate?.cutOverlay(self, didCompleteRectangle: rect)
            clearDrawState()

        case .circle:
            let radius = hypot(pt.x - dragStart.x, pt.y - dragStart.y)
            guard radius > 10 else { clearDrawState(); return }
            delegate?.cutOverlay(self, didCompleteCircle: dragStart, radius: radius)
            clearDrawState()

        case .smart:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDrawing = false
        clearDrawState()
    }

    // MARK: - Path Drawing

    private func updateFreehandPath() {
        guard touchPoints.count >= 2 else { return }
        let path = UIBezierPath()
        path.move(to: touchPoints[0])
        for i in 1..<touchPoints.count {
            if i == 1 {
                path.addLine(to: touchPoints[i])
            } else {
                let prev = touchPoints[i-1]
                let curr = touchPoints[i]
                let cp   = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                path.addQuadCurve(to: curr, controlPoint: cp)
            }
        }
        drawLayer.path = path.cgPath
    }

    private func updateDragPath() {
        switch activeTool {
        case .rectangle:
            let rect = normalizedRect(from: dragStart, to: dragCurrent)
            drawLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath

        case .circle:
            let radius = hypot(dragCurrent.x - dragStart.x, dragCurrent.y - dragStart.y)
            let rect   = CGRect(
                x: dragStart.x - radius, y: dragStart.y - radius,
                width: radius * 2, height: radius * 2
            )
            drawLayer.path = UIBezierPath(ovalIn: rect).cgPath

        default: break
        }
    }

    private func clearDrawState() {
        touchPoints  = []
        isDrawing    = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        drawLayer.path = nil
        CATransaction.commit()
    }

    // MARK: - Instruction Updates

    private func updateInstruction() {
        let text: String
        switch activeTool {
        case .smart:     text = "Tap on socket or switch"
        case .freehand:  text = "Draw around area to cut"
        case .rectangle: text = "Drag to draw rectangle"
        case .circle:    text = "Drag to draw circle"
        }

        UIView.transition(with: instructionLabel,
                          duration: 0.2,
                          options: .transitionCrossDissolve) {
            self.instructionLabel.text = text
        }
    }

    // MARK: - Helpers

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x:      min(a.x, b.x),
            y:      min(a.y, b.y),
            width:  abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    deinit {
        marchTimer?.invalidate()
    }
}