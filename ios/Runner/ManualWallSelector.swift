//
//  ManualWallSelector.swift
//  OBOIA
//
//  Universal wall selection for any surface — including completely blank
//  walls where ARKit's vertical plane detection fails.
//
//  v1.3 (May 2026): Dots now PROJECT from stored world points every frame,
//  so they stay locked to real wall positions as the camera moves.
//  Previously dots were UIView subviews glued to screen pixels — they did
//  not track the world. Fixed by adding a CADisplayLink that re-projects
//  each frame using the AR scene's camera.
//

import UIKit
import ARKit
import SceneKit

// MARK: - Delegate protocol

protocol ManualWallSelectorDelegate: AnyObject {
    func manualSelector(
        _ selector: ManualWallSelector,
        didCompleteWithWorldPoints worldPoints: [SIMD3<Float>],
        width: Float,
        height: Float,
        center: SIMD3<Float>,
        normal: SIMD3<Float>
    )
    func manualSelector(_ selector: ManualWallSelector, didAddCornerNumber n: Int)
    func manualSelectorDidReset(_ selector: ManualWallSelector)
    func manualSelector(_ selector: ManualWallSelector, didFailWithReason reason: String)
}

// MARK: - Selector view

final class ManualWallSelector: UIView {

    weak var delegate: ManualWallSelectorDelegate?
    weak var sceneView: ARSCNView?

    /// World-space points (the source of truth — never lose these)
    private(set) var worldPoints: [SIMD3<Float>] = []

    /// Current screen-space positions (recomputed every frame from worldPoints)
    private var currentScreenPoints: [CGPoint] = []

    /// Track which world points are visible in front of the camera
    private var visibilityFlags: [Bool] = []

    // Drawing layers
    private let polygonLayer = CAShapeLayer()
    private let dashedPreviewLayer = CAShapeLayer()
    private var dotViews: [UIView] = []

    // Visual styling
    private let goldColor = UIColor(red: 1.0, green: 0.827, blue: 0.412, alpha: 1.0)
    private let dotSize: CGFloat = 28

    // Instruction pill
    private let instructionPill = UIView()
    private let instructionLabel = UILabel()

    // Restart button
    private let restartButton = UIButton(type: .system)

    // Per-frame projection driver
    private var displayLink: CADisplayLink?

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
        isHidden = true

        setupPolygonLayers()
        setupInstruction()
        setupRestartButton()
        addTapRecognizer()
    }

    // MARK: - Subview setup

    private func setupPolygonLayers() {
        polygonLayer.fillColor = goldColor.withAlphaComponent(0.10).cgColor
        polygonLayer.strokeColor = goldColor.cgColor
        polygonLayer.lineWidth = 2.5
        polygonLayer.lineJoin = .round
        layer.addSublayer(polygonLayer)

        dashedPreviewLayer.fillColor = nil
        dashedPreviewLayer.strokeColor = goldColor.withAlphaComponent(0.6).cgColor
        dashedPreviewLayer.lineWidth = 1.5
        dashedPreviewLayer.lineDashPattern = [6, 4]
        layer.addSublayer(dashedPreviewLayer)
    }

    private func setupInstruction() {
        instructionPill.backgroundColor = goldColor
        instructionPill.layer.cornerRadius = 18
        instructionPill.alpha = 0
        addSubview(instructionPill)

        instructionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        instructionLabel.textColor = UIColor(white: 0.08, alpha: 1)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 1
        instructionPill.addSubview(instructionLabel)

        instructionPill.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            instructionPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructionPill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 90),
            instructionPill.heightAnchor.constraint(equalToConstant: 44),
            instructionPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            instructionLabel.leadingAnchor.constraint(equalTo: instructionPill.leadingAnchor, constant: 18),
            instructionLabel.trailingAnchor.constraint(equalTo: instructionPill.trailingAnchor, constant: -18),
            instructionLabel.centerYAnchor.constraint(equalTo: instructionPill.centerYAnchor)
        ])
    }

    private func setupRestartButton() {
        restartButton.setTitle("  Restart  ", for: .normal)
        restartButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        restartButton.setTitleColor(.white, for: .normal)
        restartButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        restartButton.layer.cornerRadius = 14
        restartButton.layer.borderWidth = 1
        restartButton.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        restartButton.alpha = 0
        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        addSubview(restartButton)

        restartButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            restartButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            restartButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -180),
            restartButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func addTapRecognizer() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    // MARK: - Public API

    func enter() {
        slog("MANUAL", "enter() — sceneView=\(sceneView == nil ? "NIL" : "ok")")
        reset()
        isHidden = false
        UIView.animate(withDuration: 0.22) {
            self.instructionPill.alpha = 1
            self.restartButton.alpha = 1
        }
        updateInstruction()
        startDisplayLink()
    }

    func exit() {
        slog("MANUAL", "exit() — worldPoints captured=\(worldPoints.count)")
        stopDisplayLink()
        UIView.animate(withDuration: 0.18, animations: {
            self.instructionPill.alpha = 0
            self.restartButton.alpha = 0
        }) { _ in
            self.isHidden = true
            self.reset()
        }
    }

    func reset() {
        worldPoints.removeAll()
        currentScreenPoints.removeAll()
        visibilityFlags.removeAll()
        dotViews.forEach { $0.removeFromSuperview() }
        dotViews.removeAll()
        polygonLayer.path = nil
        dashedPreviewLayer.path = nil
        delegate?.manualSelectorDidReset(self)
        updateInstruction()
    }

    @objc private func restartTapped() {
        reset()
    }

    // MARK: - CADisplayLink — re-projects worldPoints every frame

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NSLog("[AR] manual selector display link started")
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        // Project every world point to current screen coords.
        // sceneView.projectPoint converts world → screen pixels using the live camera.
        guard let sceneView = sceneView, !worldPoints.isEmpty else { return }

        // Ensure parallel arrays are sized correctly
        if currentScreenPoints.count != worldPoints.count {
            currentScreenPoints = Array(repeating: .zero, count: worldPoints.count)
        }
        if visibilityFlags.count != worldPoints.count {
            visibilityFlags = Array(repeating: true, count: worldPoints.count)
        }

        for i in 0..<worldPoints.count {
            let world = worldPoints[i]
            let projected = sceneView.projectPoint(SCNVector3(world.x, world.y, world.z))
            // projectPoint.z is depth in clip space. z > 1 means BEHIND the camera.
            let isVisible = projected.z < 1.0 && projected.z > 0.0
            visibilityFlags[i] = isVisible

            let screen = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            currentScreenPoints[i] = screen

            if i < dotViews.count {
                let dot = dotViews[i]
                if isVisible {
                    if dot.isHidden { dot.isHidden = false }
                    dot.center = screen
                } else {
                    // Point is behind the camera — hide it.
                    if !dot.isHidden { dot.isHidden = true }
                }
            }
        }

        rebuildPolygonPath()
    }

    // MARK: - Tap handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let screenPoint = gesture.location(in: self)
        slog("MANUAL", "handleTap at screen=(\(Int(screenPoint.x)),\(Int(screenPoint.y))) — current corners=\(worldPoints.count)/4")

        guard worldPoints.count < 4 else {
            slog("MANUAL", "handleTap IGNORED — already have 4 corners")
            return
        }
        guard let sceneView = sceneView else {
            slog("MANUAL", "handleTap FAILED — sceneView is nil")
            return
        }

        // Three-tier raycast strategy: existing plane → estimated plane → feature point
        var hitWorldPoint: SIMD3<Float>? = nil
        var hitNormal: SIMD3<Float>? = nil
        var hitMethod: String = "none"

        if let q = sceneView.raycastQuery(from: screenPoint,
                                          allowing: .existingPlaneGeometry,
                                          alignment: .any),
           let r = sceneView.session.raycast(q).first {
            hitWorldPoint = SIMD3<Float>(r.worldTransform.columns.3.x,
                                         r.worldTransform.columns.3.y,
                                         r.worldTransform.columns.3.z)
            hitNormal = SIMD3<Float>(r.worldTransform.columns.2.x,
                                     r.worldTransform.columns.2.y,
                                     r.worldTransform.columns.2.z)
            hitMethod = "existingPlane"
        } else if let q = sceneView.raycastQuery(from: screenPoint,
                                                 allowing: .estimatedPlane,
                                                 alignment: .any),
                  let r = sceneView.session.raycast(q).first {
            hitWorldPoint = SIMD3<Float>(r.worldTransform.columns.3.x,
                                         r.worldTransform.columns.3.y,
                                         r.worldTransform.columns.3.z)
            hitNormal = SIMD3<Float>(r.worldTransform.columns.2.x,
                                     r.worldTransform.columns.2.y,
                                     r.worldTransform.columns.2.z)
            hitMethod = "estimatedPlane"
        } else {
            let hitTestResults = sceneView.hitTest(screenPoint, types: [.featurePoint])
            if let r = hitTestResults.first {
                hitWorldPoint = SIMD3<Float>(r.worldTransform.columns.3.x,
                                             r.worldTransform.columns.3.y,
                                             r.worldTransform.columns.3.z)
                hitMethod = "featurePoint"
            }
        }

        guard let world = hitWorldPoint else {
            slog("MANUAL", "handleTap MISSED — no surface found via any raycast strategy")
            delegate?.manualSelector(self, didFailWithReason: "Tap closer to the wall — point camera at it directly")
            flashRedDot(at: screenPoint)
            return
        }

        slog("MANUAL", "handleTap HIT via \(hitMethod) world=(\(world.x),\(world.y),\(world.z))")

        worldPoints.append(world)
        currentScreenPoints.append(screenPoint)
        visibilityFlags.append(true)

        addDot(at: screenPoint, number: worldPoints.count)
        rebuildPolygonPath()
        delegate?.manualSelector(self, didAddCornerNumber: worldPoints.count)
        updateInstruction()

        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()

        slog("MANUAL", "corner \(worldPoints.count)/4 captured")

        if worldPoints.count == 4 {
            slog("MANUAL", "all 4 corners captured — calling finalizePolygon")
            finalizePolygon(suggestedNormal: hitNormal)
        }
    }

    // MARK: - Polygon finalization

    private func finalizePolygon(suggestedNormal: SIMD3<Float>?) {
        slog("MANUAL", "finalizePolygon BEGIN — worldPoints.count=\(worldPoints.count)")
        guard worldPoints.count == 4 else {
            slog("MANUAL", "finalizePolygon ABORT — not 4 points")
            return
        }

        let center = (worldPoints[0] + worldPoints[1] + worldPoints[2] + worldPoints[3]) / 4

        let widthTop = simd_distance(worldPoints[0], worldPoints[1])
        let widthBottom = simd_distance(worldPoints[3], worldPoints[2])
        let heightLeft = simd_distance(worldPoints[0], worldPoints[3])
        let heightRight = simd_distance(worldPoints[1], worldPoints[2])
        let width = (widthTop + widthBottom) / 2
        let height = (heightLeft + heightRight) / 2

        let edge1 = simd_normalize(worldPoints[1] - worldPoints[0])  // TL→TR
        let edge2 = simd_normalize(worldPoints[3] - worldPoints[0])  // TL→BL
        var normal = simd_normalize(simd_cross(edge1, edge2))

        if let suggested = suggestedNormal,
           simd_dot(normal, suggested) < 0 {
            normal = -normal
        }

        slog("MANUAL", "finalizePolygon DIMS w=\(width) h=\(height)")
        slog("MANUAL", "finalizePolygon CENTER=(\(center.x),\(center.y),\(center.z))")
        slog("MANUAL", "finalizePolygon NORMAL=(\(normal.x),\(normal.y),\(normal.z))")
        slog("MANUAL", "finalizePolygon — calling delegate didCompleteWithWorldPoints")

        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)

        delegate?.manualSelector(
            self,
            didCompleteWithWorldPoints: worldPoints,
            width: width,
            height: height,
            center: center,
            normal: normal
        )

        slog("MANUAL", "finalizePolygon END — delegate returned")
        flashPolygonSuccess()
    }

    // MARK: - Visuals

    private func addDot(at point: CGPoint, number: Int) {
        let container = UIView(frame: CGRect(
            x: point.x - dotSize / 2,
            y: point.y - dotSize / 2,
            width: dotSize, height: dotSize
        ))
        container.backgroundColor = goldColor
        container.layer.cornerRadius = dotSize / 2
        container.layer.borderColor = UIColor.white.cgColor
        container.layer.borderWidth = 2
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.4
        container.layer.shadowRadius = 4
        container.layer.shadowOffset = CGSize(width: 0, height: 2)

        let label = UILabel(frame: container.bounds)
        label.text = "\(number)"
        label.textAlignment = .center
        label.textColor = UIColor(white: 0.08, alpha: 1)
        label.font = .systemFont(ofSize: 13, weight: .heavy)
        container.addSubview(label)

        container.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        container.alpha = 0
        addSubview(container)
        UIView.animate(withDuration: 0.22, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4,
                       options: [], animations: {
            container.transform = .identity
            container.alpha = 1
        })
        dotViews.append(container)
    }

    private func flashRedDot(at point: CGPoint) {
        let dot = UIView(frame: CGRect(
            x: point.x - 16, y: point.y - 16,
            width: 32, height: 32
        ))
        dot.backgroundColor = UIColor.red.withAlphaComponent(0.6)
        dot.layer.cornerRadius = 16
        addSubview(dot)
        UIView.animate(withDuration: 0.5, animations: {
            dot.transform = CGAffineTransform(scaleX: 2, y: 2)
            dot.alpha = 0
        }) { _ in dot.removeFromSuperview() }
    }

    /// Rebuild the polygon outline using the CURRENT projected screen points.
    /// Called every frame from tick() AND immediately after each tap.
    private func rebuildPolygonPath() {
        guard !currentScreenPoints.isEmpty else {
            polygonLayer.path = nil
            dashedPreviewLayer.path = nil
            return
        }

        // Build path through visible points only
        let visiblePoints: [CGPoint] = zip(currentScreenPoints, visibilityFlags)
            .compactMap { $0.1 ? $0.0 : nil }

        guard !visiblePoints.isEmpty else {
            polygonLayer.path = nil
            dashedPreviewLayer.path = nil
            return
        }

        let path = UIBezierPath()
        path.move(to: visiblePoints[0])
        for i in 1..<visiblePoints.count {
            path.addLine(to: visiblePoints[i])
        }

        if currentScreenPoints.count == 4 && visibilityFlags.allSatisfy({ $0 }) {
            path.close()
            polygonLayer.path = path.cgPath
            dashedPreviewLayer.path = nil
        } else {
            polygonLayer.path = path.cgPath
            // Show dashed preview from last placed point back to first when 3 placed
            if currentScreenPoints.count == 3 && visibilityFlags.allSatisfy({ $0 }) {
                let preview = UIBezierPath()
                preview.move(to: currentScreenPoints[2])
                preview.addLine(to: currentScreenPoints[0])
                dashedPreviewLayer.path = preview.cgPath
            } else {
                dashedPreviewLayer.path = nil
            }
        }
    }

    private func flashPolygonSuccess() {
        polygonLayer.fillColor = goldColor.withAlphaComponent(0.30).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        polygonLayer.fillColor = goldColor.withAlphaComponent(0.10).cgColor
        CATransaction.commit()
    }

    // MARK: - Instruction text

    private func updateInstruction() {
        let text: String
        switch worldPoints.count {
        case 0: text = "Tap the TOP-LEFT corner of the wall"
        case 1: text = "Tap the TOP-RIGHT corner"
        case 2: text = "Tap the BOTTOM-RIGHT corner"
        case 3: text = "Tap the BOTTOM-LEFT corner"
        default: text = "Wall captured ✓"
        }

        UIView.transition(with: instructionLabel,
                          duration: 0.18,
                          options: .transitionCrossDissolve) {
            self.instructionLabel.text = text
        }
    }

    // MARK: - HitTest passthrough for restart button

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !restartButton.isHidden,
           restartButton.alpha > 0,
           restartButton.frame.contains(point) {
            return restartButton
        }
        if isHidden { return nil }
        return self
    }

    deinit {
        stopDisplayLink()
    }
}
