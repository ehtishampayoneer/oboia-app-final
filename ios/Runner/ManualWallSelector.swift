//
//  ManualWallSelector.swift
//  OBOIA
//
//  Universal wall selection for any surface — including completely blank
//  walls where ARKit's vertical plane detection fails. User taps 4 corners
//  of the wall, we raycast each tap into world space, fit a plane to the
//  4 points, and build a quad geometry. Works on any device that supports
//  ARKit (iOS 12+), no LiDAR required.
//
//  Visual: gold numbered dots appear at each tap. Lines draw between
//  consecutive points. After 4 taps the polygon closes and the wall is
//  ready for wallpaper placement.
//

import UIKit
import ARKit
import SceneKit

// MARK: - Delegate protocol

protocol ManualWallSelectorDelegate: AnyObject {
    /// Fired when the user has tapped enough corners to define a wall.
    /// `worldPoints` is in world space, ordered: TL, TR, BR, BL.
    /// `width` and `height` are the wall extent in meters.
    func manualSelector(
        _ selector: ManualWallSelector,
        didCompleteWithWorldPoints worldPoints: [SIMD3<Float>],
        width: Float,
        height: Float,
        center: SIMD3<Float>,
        normal: SIMD3<Float>
    )

    /// Fired on each successful tap (1, 2, 3, 4).
    func manualSelector(_ selector: ManualWallSelector, didAddCornerNumber n: Int)

    /// Fired when user cancels or restarts.
    func manualSelectorDidReset(_ selector: ManualWallSelector)

    /// Fired when a tap fails to hit the world (e.g. tap on sky).
    func manualSelector(_ selector: ManualWallSelector, didFailWithReason reason: String)
}

// MARK: - Selector view

final class ManualWallSelector: UIView {

    weak var delegate: ManualWallSelectorDelegate?
    weak var sceneView: ARSCNView?

    // Captured world points (max 4)
    private(set) var worldPoints: [SIMD3<Float>] = []
    // Captured screen points (parallel array, used for drawing UI)
    private(set) var screenPoints: [CGPoint] = []

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
        isHidden = true   // shown only when manual mode is entered

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
        reset()
        isHidden = false
        UIView.animate(withDuration: 0.22) {
            self.instructionPill.alpha = 1
            self.restartButton.alpha = 1
        }
        updateInstruction()
    }

    func exit() {
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
        screenPoints.removeAll()
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

    // MARK: - Tap handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard worldPoints.count < 4 else { return }
        guard let sceneView = sceneView else { return }
        let screenPoint = gesture.location(in: self)

        // Try several raycast strategies, in order of robustness:
        //   1) Existing plane (if user is on a textured wall, this just works)
        //   2) Estimated plane (works without detected geometry)
        //   3) Feature point (last resort, may be inaccurate)
        var hitWorldPoint: SIMD3<Float>? = nil
        var hitNormal: SIMD3<Float>? = nil

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
        } else {
            // Feature points fallback (for completely textureless surfaces)
            let hitTestResults = sceneView.hitTest(screenPoint, types: [.featurePoint])
            if let r = hitTestResults.first {
                hitWorldPoint = SIMD3<Float>(r.worldTransform.columns.3.x,
                                             r.worldTransform.columns.3.y,
                                             r.worldTransform.columns.3.z)
            }
        }

        guard let world = hitWorldPoint else {
            delegate?.manualSelector(self, didFailWithReason: "Tap closer to the wall — point camera at it directly")
            flashRedDot(at: screenPoint)
            return
        }

        worldPoints.append(world)
        screenPoints.append(screenPoint)

        // Visual feedback
        addDot(at: screenPoint, number: worldPoints.count)
        rebuildPolygonPath()
        delegate?.manualSelector(self, didAddCornerNumber: worldPoints.count)
        updateInstruction()

        // Light haptic
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()

        // 4th tap → finalize
        if worldPoints.count == 4 {
            finalizePolygon(suggestedNormal: hitNormal)
        }
    }

    // MARK: - Polygon finalization

    private func finalizePolygon(suggestedNormal: SIMD3<Float>?) {
        guard worldPoints.count == 4 else { return }

        // Center = average of 4 corners
        let center = (worldPoints[0] + worldPoints[1] + worldPoints[2] + worldPoints[3]) / 4

        // Compute width & height from corner distances:
        // worldPoints are ordered TL, TR, BR, BL.
        let widthTop = simd_distance(worldPoints[0], worldPoints[1])
        let widthBottom = simd_distance(worldPoints[3], worldPoints[2])
        let heightLeft = simd_distance(worldPoints[0], worldPoints[3])
        let heightRight = simd_distance(worldPoints[1], worldPoints[2])
        let width = (widthTop + widthBottom) / 2
        let height = (heightLeft + heightRight) / 2

        // Compute normal: cross product of two edges
        let edge1 = simd_normalize(worldPoints[1] - worldPoints[0])  // TL -> TR
        let edge2 = simd_normalize(worldPoints[3] - worldPoints[0])  // TL -> BL
        var normal = simd_normalize(simd_cross(edge1, edge2))

        // If the suggested normal exists and points roughly the same way, use it
        // (it tends to be more accurate than computed from points)
        if let suggested = suggestedNormal,
           simd_dot(normal, suggested) < 0 {
            normal = -normal
        }

        // Strong success haptic
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

        // Animate the polygon's success state
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

        // Spawn animation
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

    private func rebuildPolygonPath() {
        guard !screenPoints.isEmpty else {
            polygonLayer.path = nil
            dashedPreviewLayer.path = nil
            return
        }

        // Solid stroke for the lines we have
        let path = UIBezierPath()
        path.move(to: screenPoints[0])
        for i in 1..<screenPoints.count {
            path.addLine(to: screenPoints[i])
        }
        // Close the polygon visually only when we have all 4 corners
        if screenPoints.count == 4 {
            path.close()
            polygonLayer.path = path.cgPath
            dashedPreviewLayer.path = nil
        } else {
            polygonLayer.path = path.cgPath
            // Hint where to tap next: dashed preview to the first dot
            // to suggest the closing edge they're working toward
            if screenPoints.count == 3 {
                let preview = UIBezierPath()
                preview.move(to: screenPoints.last!)
                preview.addLine(to: screenPoints[0])
                dashedPreviewLayer.path = preview.cgPath
            } else {
                dashedPreviewLayer.path = nil
            }
        }
    }

    private func flashPolygonSuccess() {
        // Brief pulse — fill goes brighter then back
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
        // Let restart button receive its taps
        if !restartButton.isHidden,
           restartButton.alpha > 0,
           restartButton.frame.contains(point) {
            return restartButton
        }
        // Everything else: this view captures the tap
        if isHidden { return nil }
        return self
    }
}
