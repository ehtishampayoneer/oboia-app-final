//
//  ARWallpaperView.swift
//  OBOIA
//
//  Photorealistic AR wallpaper placement using ARKit + SceneKit PBR.
//
//  Phase 1 (May 2026):
//   - Auto plane detection (works on textured walls)
//   - MANUAL 4-corner tap mode (works on ANY wall, blank or textured)
//   - Auto-fallback prompt: if plane detection finds nothing in 5 seconds
//     and no wallpaper has been placed, suggest manual mode to Flutter
//   - All previous Phase 0 features preserved (PBR, cut mode, lock,
//     multi-wall, environment lighting)
//

import UIKit
import ARKit
import SceneKit
import Vision
import Flutter

// MARK: - Shared wallpaper descriptor

struct WallpaperInfo {
    let albedoUrl: String
    let normalUrl: String
    let roughnessUrl: String
    let aoUrl: String
    let rollWidth: Float
    let rollLength: Float
    let pricePerRoll: Double
}

// MARK: - Per-wall state

final class WallData {
    /// nil for manual walls (they have no ARPlaneAnchor)
    let anchor: ARPlaneAnchor?
    /// For manual walls: the world-space center, normal, and corner points
    let manualCenter: SIMD3<Float>?
    let manualNormal: SIMD3<Float>?
    let manualCorners: [SIMD3<Float>]?

    var markerNode: SCNNode
    var wallpaperNode: SCNNode?
    var currentWallpaper: WallpaperInfo?
    var width: Float
    var height: Float
    var isSelected: Bool = false
    var isLocked: Bool = false
    let index: Int
    let isManual: Bool

    /// Stable identifier for the cut tool (UUID for either source)
    let id: UUID

    init(anchor: ARPlaneAnchor, markerNode: SCNNode, width: Float, height: Float, index: Int) {
        self.anchor = anchor
        self.manualCenter = nil
        self.manualNormal = nil
        self.manualCorners = nil
        self.markerNode = markerNode
        self.width = width
        self.height = height
        self.index = index
        self.isManual = false
        self.id = anchor.identifier
    }

    init(manualCenter: SIMD3<Float>, manualNormal: SIMD3<Float>, manualCorners: [SIMD3<Float>],
         markerNode: SCNNode, width: Float, height: Float, index: Int) {
        self.anchor = nil
        self.manualCenter = manualCenter
        self.manualNormal = manualNormal
        self.manualCorners = manualCorners
        self.markerNode = markerNode
        self.width = width
        self.height = height
        self.index = index
        self.isManual = true
        self.id = UUID()
    }
}

// MARK: - Main view

final class ARWallpaperView: NSObject, FlutterPlatformView,
                             ARSCNViewDelegate, ARSessionDelegate,
                             FlutterStreamHandler,
                             CutModeOverlayDelegate,
                             ManualWallSelectorDelegate {

    // Flutter plumbing
    private let _view: UIView
    private let arView: ARSCNView
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    // Wall tracking
    private var walls: [UUID: WallData] = [:]
    private var indexToWallId: [Int: UUID] = [:]
    private var nextWallIndex: Int = 0
    private var selectedWallId: UUID?

    // Cut tool + overlay
    private let cutTool = WallpaperCutTool()
    private let cutOverlay = CutModeOverlay(frame: .zero)
    private var cutModeWallIndex: Int? = nil

    // Manual selector
    private let manualSelector = ManualWallSelector(frame: .zero)
    private var inManualMode: Bool = false

    // Auto-fallback timer
    private var autoFallbackTimer: Timer?
    private var sessionStartTime: TimeInterval = 0
    private var hasEmittedManualSuggestion: Bool = false

    // Obstacle detection
    private var lastObstacleCheck: TimeInterval = 0
    private let obstacleCheckInterval: TimeInterval = 1.0

    // Light estimation smoothing
    private var smoothedIntensity: CGFloat = 1000.0
    private var smoothedTemperature: CGFloat = 6500.0

    // Brand color
    private let goldColor = UIColor(red: 1.0, green: 0.827, blue: 0.411, alpha: 1.0)

    // MARK: - Init

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
        self.arView = ARSCNView(frame: frame)
        self._view = UIView(frame: frame)
        self.methodChannel = FlutterMethodChannel(
            name: "com.oboia/ar",
            binaryMessenger: messenger
        )
        self.eventChannel = FlutterEventChannel(
            name: "com.oboia/ar_events",
            binaryMessenger: messenger
        )
        super.init()

        setupARView()
        setupScene()
        setupCutOverlay()
        setupManualSelector()
        setupChannels()
        setupGestures()
        startSession()
    }

    func view() -> UIView { return _view }

    // MARK: - Setup

    private func setupARView() {
        arView.frame = _view.bounds
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.delegate = self
        arView.session.delegate = self
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = false
        arView.antialiasingMode = .multisampling4X
        arView.preferredFramesPerSecond = 60
        arView.rendersContinuously = true
        arView.contentScaleFactor = UIScreen.main.scale
        _view.addSubview(arView)
    }

    private func setupScene() {
        arView.scene = SCNScene()
        arView.scene.lightingEnvironment.intensity = 1.0
    }

    private func setupCutOverlay() {
        cutOverlay.frame = _view.bounds
        cutOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cutOverlay.delegate = self
        cutOverlay.sceneView = arView
        cutOverlay.isHidden = true
        _view.addSubview(cutOverlay)
    }

    private func setupManualSelector() {
        manualSelector.frame = _view.bounds
        manualSelector.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        manualSelector.delegate = self
        manualSelector.sceneView = arView
        manualSelector.isHidden = true
        _view.addSubview(manualSelector)
    }

    private func setupChannels() {
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
        eventChannel.setStreamHandler(self)
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    private func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            sendError(code: "unsupported", message: "ARKit world tracking not supported on this device")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical, .horizontal]   // Both — helps tracking in featureless rooms
        config.isLightEstimationEnabled = true
        config.worldAlignment = .gravity
        config.maximumNumberOfTrackedImages = 0

        if #available(iOS 12.0, *) {
            config.environmentTexturing = .automatic
        }

        if #available(iOS 13.4, *),
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if #available(iOS 13.4, *),
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        sessionStartTime = CACurrentMediaTime()
        scheduleAutoFallback()
    }

    /// After 5 seconds, if no walls have been detected AND no wallpaper placed,
    /// suggest manual mode to Flutter so it can show a prompt.
    private func scheduleAutoFallback() {
        autoFallbackTimer?.invalidate()
        autoFallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.walls.isEmpty && !self.hasEmittedManualSuggestion {
                self.hasEmittedManualSuggestion = true
                self.sendEvent(type: "suggestManual", data: [
                    "reason": "no_planes_detected"
                ])
            }
        }
    }

    // MARK: - Flutter → native method calls

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initAR":
            result(true)

        case "placeWallpaper":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: "Expected map", details: nil)); return
            }
            placeWallpaperFromArgs(args, result: result)

        case "switchWallpaper":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: "Expected map", details: nil)); return
            }
            switchWallpaperFromArgs(args, result: result)

        case "selectWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "wallIndex required", details: nil)); return
            }
            selectWall(index: idx)
            result(true)

        case "clearWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "wallIndex required", details: nil)); return
            }
            clearWall(index: idx)
            result(true)

        case "getWallMeasurements":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  let id = indexToWallId[idx],
                  let wall = walls[id] else {
                result(nil); return
            }
            result([
                "width": Double(wall.width),
                "height": Double(wall.height),
                "sqm": Double(wall.width * wall.height)
            ])

        case "lockWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  let locked = args["locked"] as? Bool,
                  let id = indexToWallId[idx],
                  let wall = walls[id] else {
                result(false); return
            }
            wall.isLocked = locked
            sendEvent(type: "wallLockChanged", data: ["wallIndex": idx, "locked": locked])
            result(true)

        // ── Manual mode handlers ────────────────────────────────────────
        case "enterManualMode":
            DispatchQueue.main.async { [weak self] in
                self?.enterManualMode()
            }
            result(true)

        case "exitManualMode":
            DispatchQueue.main.async { [weak self] in
                self?.exitManualMode()
            }
            result(true)

        case "resetManual":
            DispatchQueue.main.async { [weak self] in
                self?.manualSelector.reset()
            }
            result(true)

        // ── Cut mode handlers ───────────────────────────────────────────
        case "enterCutMode":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  walls[indexToWallId[idx] ?? UUID()] != nil else {
                result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
            }
            cutModeWallIndex = idx
            DispatchQueue.main.async { [weak self] in
                self?.cutOverlay.isHidden = false
                self?.cutOverlay.showWithTool(.smart)
                self?.sendEvent(type: "cutToolChanged", data: ["tool": "smart"])
            }
            result(true)

        case "exitCutMode":
            cutModeWallIndex = nil
            DispatchQueue.main.async { [weak self] in
                self?.cutOverlay.hide()
                self?.cutOverlay.isHidden = true
                self?.sendEvent(type: "cutModeDone", data: [:])
            }
            result(true)

        case "smartCut":
            guard let args = call.arguments as? [String: Any],
                  let x = args["screenX"] as? Double,
                  let y = args["screenY"] as? Double,
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "smartCut args", details: nil)); return
            }
            performSmartCut(at: CGPoint(x: x, y: y), wallIndex: idx, result: result)

        case "rectangleCut":
            guard let args = call.arguments as? [String: Any],
                  let minX = args["screenMinX"] as? Double,
                  let minY = args["screenMinY"] as? Double,
                  let maxX = args["screenMaxX"] as? Double,
                  let maxY = args["screenMaxY"] as? Double,
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "rectangleCut args", details: nil)); return
            }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            performRectangleCut(screenRect: rect, wallIndex: idx, result: result)

        case "freehandCut":
            guard let args = call.arguments as? [String: Any],
                  let pts = args["screenPoints"] as? [[String: Any]],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "freehandCut args", details: nil)); return
            }
            let screenPoints: [CGPoint] = pts.compactMap {
                guard let x = $0["x"] as? Double, let y = $0["y"] as? Double else { return nil }
                return CGPoint(x: x, y: y)
            }
            performFreehandCut(screenPoints: screenPoints, wallIndex: idx, result: result)

        case "circleCut":
            guard let args = call.arguments as? [String: Any],
                  let cx = args["screenCenterX"] as? Double,
                  let cy = args["screenCenterY"] as? Double,
                  let r = args["screenRadius"] as? Double,
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "circleCut args", details: nil)); return
            }
            performCircleCut(screenCenter: CGPoint(x: cx, y: cy), screenRadius: CGFloat(r),
                             wallIndex: idx, result: result)

        case "undoCut":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "undoCut args", details: nil)); return
            }
            performUndoCut(wallIndex: idx, result: result)

        case "clearAllCuts":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "clearAllCuts args", details: nil)); return
            }
            performClearAllCuts(wallIndex: idx, result: result)

        case "disposeAR":
            disposeAR()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Manual mode

    private func enterManualMode() {
        inManualMode = true
        manualSelector.isHidden = false
        manualSelector.enter()
        sendEvent(type: "manualModeEntered", data: [:])
    }

    private func exitManualMode() {
        inManualMode = false
        manualSelector.exit()
        sendEvent(type: "manualModeExited", data: [:])
    }

    // MARK: - ManualWallSelectorDelegate

    func manualSelector(_ selector: ManualWallSelector,
                        didCompleteWithWorldPoints worldPoints: [SIMD3<Float>],
                        width: Float,
                        height: Float,
                        center: SIMD3<Float>,
                        normal: SIMD3<Float>) {
        // Hide the selector overlay; we have geometry now
        manualSelector.exit()
        inManualMode = false

        let index = nextWallIndex
        nextWallIndex += 1

        // Build the wallpaper plane node from corner points
        let wallNode = makeManualWallNode(
            corners: worldPoints,
            center: center,
            normal: normal,
            width: width,
            height: height
        )

        // Build a marker showing the wall outline
        let marker = makeManualWallMarker(
            corners: worldPoints,
            center: center,
            normal: normal,
            width: width,
            height: height,
            selected: true
        )

        let wall = WallData(
            manualCenter: center,
            manualNormal: normal,
            manualCorners: worldPoints,
            markerNode: marker,
            width: width,
            height: height,
            index: index
        )
        // Pre-attach the empty wall node — wallpaper will attach to it later
        wall.markerNode.addChildNode(wallNode)
        wall.wallpaperNode = wallNode  // placeholder; material set when wallpaper placed
        wall.wallpaperNode = nil       // reset — actually, keep the node empty until placement

        // Add marker to scene
        arView.scene.rootNode.addChildNode(marker)

        // Deselect previously selected wall, select this one
        if let prevId = selectedWallId, let prev = walls[prevId] {
            prev.isSelected = false
        }
        wall.isSelected = true
        selectedWallId = wall.id

        walls[wall.id] = wall
        indexToWallId[index] = wall.id

        sendEvent(type: "manualWallReady", data: [
            "wallIndex": index,
            "width": Double(width),
            "height": Double(height),
            "sqm": Double(width * height)
        ])

        // Also emit a wallDetected so the existing Flutter UI flows naturally
        sendEvent(type: "wallDetected", data: [
            "wallIndex": index,
            "width": Double(width),
            "height": Double(height),
            "sqm": Double(width * height)
        ])
    }

    func manualSelector(_ selector: ManualWallSelector, didAddCornerNumber n: Int) {
        sendEvent(type: "manualCornerAdded", data: ["corner": n, "total": 4])
    }

    func manualSelectorDidReset(_ selector: ManualWallSelector) {
        sendEvent(type: "manualReset", data: [:])
    }

    func manualSelector(_ selector: ManualWallSelector, didFailWithReason reason: String) {
        sendEvent(type: "manualWallFailed", data: ["reason": reason])
    }

    // MARK: - Manual wall geometry

    /// Build a SCNNode representing the user-defined wall.
    /// The wallpaper plane is positioned at the polygon center, oriented along its normal.
    private func makeManualWallNode(
        corners: [SIMD3<Float>],
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        width: Float,
        height: Float
    ) -> SCNNode {
        // Empty node that will receive the wallpaper material later
        let node = SCNNode()
        node.simdPosition = center

        // Orient: rotate so the plane's normal matches the computed wall normal.
        // SCNPlane lies in XY by default with normal pointing +Z.
        let up = SIMD3<Float>(0, 0, 1)
        let dot = simd_dot(up, normal)
        if abs(dot - 1.0) < 1e-4 {
            // already facing
        } else if abs(dot + 1.0) < 1e-4 {
            node.eulerAngles = SCNVector3(0, Float.pi, 0)
        } else {
            let axis = simd_normalize(simd_cross(up, normal))
            let angle = acos(dot)
            node.simdOrientation = simd_quaternion(angle, axis)
        }

        return node
    }

    /// Build a visual marker outlining the manual wall corners.
    private func makeManualWallMarker(
        corners: [SIMD3<Float>],
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        width: Float,
        height: Float,
        selected: Bool
    ) -> SCNNode {
        let node = SCNNode()
        let color = selected ? goldColor : goldColor.withAlphaComponent(0.55)

        // Draw lines between consecutive corners (forming the polygon outline)
        for i in 0..<corners.count {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            let segment = makeLineSegment(from: a, to: b, thickness: 0.006, color: color)
            node.addChildNode(segment)
        }

        // Subtle pulse
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.7
        pulse.toValue = 1.0
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        node.addAnimation(pulse, forKey: "pulse")

        return node
    }

    private func makeLineSegment(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                 thickness: CGFloat, color: UIColor) -> SCNNode {
        let v = b - a
        let len = CGFloat(simd_length(v))
        let box = SCNBox(width: thickness, height: len, length: thickness, chamferRadius: 0)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = color
        mat.emission.contents = color
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        box.materials = [mat]
        let node = SCNNode(geometry: box)
        node.renderingOrder = 100

        let mid = (a + b) / 2
        node.simdPosition = mid

        // Orient box height along the segment
        let up = SIMD3<Float>(0, 1, 0)
        let dir = simd_normalize(v)
        let dot = simd_dot(up, dir)
        if abs(dot - 1.0) < 1e-4 {
            // already aligned
        } else if abs(dot + 1.0) < 1e-4 {
            node.eulerAngles = SCNVector3(Float.pi, 0, 0)
        } else {
            let axis = simd_normalize(simd_cross(up, dir))
            let angle = acos(dot)
            node.simdOrientation = simd_quaternion(angle, axis)
        }
        return node
    }

    // MARK: - Wallpaper placement (works for both auto and manual walls)

    private func placeWallpaperFromArgs(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let info = parseWallpaperInfo(args),
              let wallIndex = args["wallIndex"] as? Int else {
            result(FlutterError(code: "bad_args", message: "Missing wallpaper fields", details: nil))
            return
        }

        let wallId: UUID? = {
            if wallIndex >= 0, let id = indexToWallId[wallIndex] { return id }
            if let sel = selectedWallId { return sel }
            return walls.values.first?.id
        }()

        guard let id = wallId, let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "No wall available to place on", details: nil))
            return
        }

        loadPBRTextures(info: info) { [weak self] textures in
            guard let self = self else { return }
            guard let t = textures else {
                DispatchQueue.main.async {
                    self.sendError(code: "texture_load", message: "Failed to load wallpaper image")
                    result(FlutterError(code: "texture_load", message: "Failed to load wallpaper image", details: nil))
                }
                return
            }
            DispatchQueue.main.async {
                self.attachWallpaper(to: wall, textures: t, info: info)
                self.sendEvent(type: "wallpaperPlaced", data: [
                    "wallIndex": wall.index,
                    "success": true
                ])
                result(true)
            }
        }
    }

    private func switchWallpaperFromArgs(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let info = parseWallpaperInfo(args),
              let wallIndex = args["wallIndex"] as? Int,
              let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil))
            return
        }

        loadPBRTextures(info: info) { [weak self] textures in
            guard let self = self, let t = textures else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "texture_load", message: "Failed to load wallpaper image", details: nil))
                }
                return
            }
            DispatchQueue.main.async {
                if wall.wallpaperNode == nil {
                    self.attachWallpaper(to: wall, textures: t, info: info)
                } else {
                    self.updateMaterial(on: wall, textures: t, info: info)
                }
                if let mat = wall.wallpaperNode?.geometry?.firstMaterial {
                    self.cutTool.reapplyMask(toMaterial: mat, wallId: wall.id)
                }
                self.sendEvent(type: "wallpaperPlaced", data: [
                    "wallIndex": wall.index,
                    "success": true
                ])
                result(true)
            }
        }
    }

    private func parseWallpaperInfo(_ args: [String: Any]) -> WallpaperInfo? {
        guard let albedo = args["albedoUrl"] as? String, !albedo.isEmpty else {
            return nil
        }
        let normal = (args["normalUrl"] as? String) ?? ""
        let roughness = (args["roughnessUrl"] as? String) ?? ""
        let ao = (args["aoUrl"] as? String) ?? ""
        let rollWidth = (args["rollWidth"] as? Double) ?? 0.53
        let rollLength = (args["rollLength"] as? Double) ?? 10.0
        let price = (args["pricePerRoll"] as? Double) ?? 0.0
        return WallpaperInfo(
            albedoUrl: albedo,
            normalUrl: normal,
            roughnessUrl: roughness,
            aoUrl: ao,
            rollWidth: Float(rollWidth),
            rollLength: Float(rollLength),
            pricePerRoll: price
        )
    }

    private struct PBRTextures {
        let albedo: UIImage
        let normal: UIImage?
        let roughness: UIImage?
        let ao: UIImage?
    }

    private func loadPBRTextures(info: WallpaperInfo,
                                 completion: @escaping (PBRTextures?) -> Void) {
        let group = DispatchGroup()
        var albedo: UIImage?
        var normal: UIImage?
        var rough: UIImage?
        var ao: UIImage?
        let cache = TextureCache.shared

        group.enter()
        cache.loadImage(from: info.albedoUrl) { img in
            albedo = img
            group.leave()
        }
        if !info.normalUrl.isEmpty {
            group.enter()
            cache.loadImage(from: info.normalUrl) { img in
                normal = img
                group.leave()
            }
        }
        if !info.roughnessUrl.isEmpty {
            group.enter()
            cache.loadImage(from: info.roughnessUrl) { img in
                rough = img
                group.leave()
            }
        }
        if !info.aoUrl.isEmpty {
            group.enter()
            cache.loadImage(from: info.aoUrl) { img in
                ao = img
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            guard let a = albedo else {
                completion(nil); return
            }
            completion(PBRTextures(albedo: a, normal: normal, roughness: rough, ao: ao))
        }
    }

    // MARK: - PBR material attach

    private func attachWallpaper(to wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        let geometry = SCNPlane(width: CGFloat(wall.width), height: CGFloat(wall.height))
        let material = buildPBRMaterial(textures: textures, info: info,
                                        wallWidth: wall.width, wallHeight: wall.height)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 10
        node.geometry?.firstMaterial?.writesToDepthBuffer = true
        node.geometry?.firstMaterial?.readsFromDepthBuffer = true

        if wall.isManual {
            // Position at wall center, oriented to face along the normal
            node.simdPosition = wall.manualCenter ?? SIMD3<Float>(0, 0, 0)
            if let n = wall.manualNormal {
                let up = SIMD3<Float>(0, 0, 1)
                let dot = simd_dot(up, n)
                if abs(dot - 1.0) < 1e-4 {
                    // already aligned
                } else if abs(dot + 1.0) < 1e-4 {
                    node.eulerAngles = SCNVector3(0, Float.pi, 0)
                } else {
                    let axis = simd_normalize(simd_cross(up, n))
                    let angle = acos(dot)
                    node.simdOrientation = simd_quaternion(angle, axis)
                }
            }
            arView.scene.rootNode.addChildNode(node)
        } else {
            // Auto-detected plane: child of the plane anchor's node so it tracks updates
            node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            if let anchor = wall.anchor, let planeNode = arView.node(for: anchor) {
                node.simdPosition = anchor.center
                planeNode.addChildNode(node)
            } else {
                arView.scene.rootNode.addChildNode(node)
            }
        }

        // Fade in
        node.opacity = 0.0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        node.opacity = 1.0
        SCNTransaction.commit()

        // If the wall already had a wallpaper node (replacing), remove the old one
        wall.wallpaperNode?.removeFromParentNode()
        wall.wallpaperNode = node
        wall.currentWallpaper = info

        cutTool.reapplyMask(toMaterial: material, wallId: wall.id)

        wall.markerNode.opacity = wall.isSelected ? 1.0 : 0.0
    }

    private func updateMaterial(on wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        guard let node = wall.wallpaperNode,
              let material = node.geometry?.firstMaterial else { return }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15

        material.diffuse.contents = textures.albedo
        material.normal.contents = textures.normal ?? flatNormalImage()
        material.roughness.contents = textures.roughness ?? UIColor(white: 0.7, alpha: 1.0)
        material.ambientOcclusion.contents = textures.ao ?? UIColor.white

        let transform = uvTransform(wallWidth: wall.width, wallHeight: wall.height,
                                    rollWidth: info.rollWidth, rollLength: info.rollLength)
        material.diffuse.contentsTransform = transform
        material.normal.contentsTransform = transform
        material.roughness.contentsTransform = transform
        material.ambientOcclusion.contentsTransform = transform

        SCNTransaction.commit()
        wall.currentWallpaper = info
    }

    private func buildPBRMaterial(textures: PBRTextures, info: WallpaperInfo,
                                  wallWidth: Float, wallHeight: Float) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased

        m.diffuse.contents = textures.albedo
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.maxAnisotropy = 16

        m.normal.contents = textures.normal ?? flatNormalImage()
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = textures.normal == nil ? 0.0 : 1.0
        m.normal.mipFilter = .linear
        m.normal.maxAnisotropy = 16

        m.roughness.contents = textures.roughness ?? UIColor(white: 0.7, alpha: 1.0)
        m.roughness.wrapS = .repeat
        m.roughness.wrapT = .repeat
        m.roughness.mipFilter = .linear
        m.roughness.maxAnisotropy = 16

        m.ambientOcclusion.contents = textures.ao ?? UIColor.white
        m.ambientOcclusion.wrapS = .repeat
        m.ambientOcclusion.wrapT = .repeat
        m.ambientOcclusion.mipFilter = .linear
        m.ambientOcclusion.maxAnisotropy = 16

        m.metalness.contents = 0.0

        let transform = uvTransform(wallWidth: wallWidth, wallHeight: wallHeight,
                                    rollWidth: info.rollWidth, rollLength: info.rollLength)
        m.diffuse.contentsTransform = transform
        m.normal.contentsTransform = transform
        m.roughness.contentsTransform = transform
        m.ambientOcclusion.contentsTransform = transform

        m.isDoubleSided = false
        return m
    }

    private func uvTransform(wallWidth: Float, wallHeight: Float,
                             rollWidth: Float, rollLength: Float) -> SCNMatrix4 {
        let repeatX = max(0.1, wallWidth / max(rollWidth, 0.01))
        let repeatY = max(0.1, wallHeight / max(rollWidth, 0.01))
        return SCNMatrix4MakeScale(repeatX, repeatY, 1)
    }

    private static var _flatNormalImage: UIImage = {
        let size = CGSize(width: 4, height: 4)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1.0).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }()
    private func flatNormalImage() -> UIImage { ARWallpaperView._flatNormalImage }

    private func planeWidth(of anchor: ARPlaneAnchor) -> Float {
        if #available(iOS 16.0, *) { return anchor.planeExtent.width }
        return anchor.extent.x
    }
    private func planeHeight(of anchor: ARPlaneAnchor) -> Float {
        if #available(iOS 16.0, *) { return anchor.planeExtent.height }
        return anchor.extent.z
    }

    // MARK: - Wall selection

    private func selectWall(index: Int) {
        guard let id = indexToWallId[index] else { return }
        selectedWallId = id
        for (wallId, wall) in walls {
            let sel = (wallId == id)
            wall.isSelected = sel
            updateMarkerAppearance(wall: wall, selected: sel)
        }
        sendEvent(type: "wallSelected", data: ["wallIndex": index])
    }

    private func clearWall(index: Int) {
        guard let id = indexToWallId[index],
              let wall = walls[id] else { return }
        wall.wallpaperNode?.removeFromParentNode()
        wall.wallpaperNode = nil
        wall.currentWallpaper = nil
        wall.markerNode.opacity = 1.0
        cutTool.clearAllCuts(fromWall: id)
    }

    // MARK: - Tap (auto plane mode)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if cutModeWallIndex != nil { return }
        if inManualMode { return }   // manual selector handles its own taps

        let point = gesture.location(in: arView)

        guard let query = arView.raycastQuery(from: point,
                                              allowing: .existingPlaneGeometry,
                                              alignment: .vertical) else { return }
        let results = arView.session.raycast(query)
        guard let hit = results.first,
              let anchor = hit.anchor as? ARPlaneAnchor,
              anchor.alignment == .vertical else { return }

        if let wall = walls[anchor.identifier] {
            selectWall(index: wall.index)
        }
    }

    // MARK: - Cut Mode handlers

    private func performSmartCut(at screenPoint: CGPoint, wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        cutTool.smartCut(screenPoint: screenPoint, sceneView: arView, wallData: wall, wallId: id) {
            [weak self] success in
            self?.applyMaskAndEmit(wall: wall, result: result, success: success)
        }
    }

    private func performRectangleCut(screenRect: CGRect, wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        guard
            let uvA = cutTool.screenPointToWallUV(screenPoint: CGPoint(x: screenRect.minX, y: screenRect.minY),
                                                  sceneView: arView, wallData: wall),
            let uvB = cutTool.screenPointToWallUV(screenPoint: CGPoint(x: screenRect.maxX, y: screenRect.maxY),
                                                  sceneView: arView, wallData: wall)
        else {
            result(FlutterError(code: "raycast_fail", message: "Could not project rectangle to wall", details: nil))
            return
        }
        let uvRect = CGRect(
            x: min(uvA.x, uvB.x), y: min(uvA.y, uvB.y),
            width: abs(uvB.x - uvA.x), height: abs(uvB.y - uvA.y)
        )
        cutTool.addRectangleCut(uvRect: uvRect, toWall: id)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performFreehandCut(screenPoints: [CGPoint], wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        var uvPoints: [CGPoint] = []
        uvPoints.reserveCapacity(screenPoints.count)
        for sp in screenPoints {
            if let uv = cutTool.screenPointToWallUV(screenPoint: sp, sceneView: arView, wallData: wall) {
                uvPoints.append(uv)
            }
        }
        guard uvPoints.count >= 3 else {
            result(FlutterError(code: "too_few_points", message: "Need at least 3 points on wall", details: nil))
            return
        }
        cutTool.addFreehandCut(uvPoints: uvPoints, toWall: id)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performCircleCut(screenCenter: CGPoint, screenRadius: CGFloat,
                                  wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        let edge = CGPoint(x: screenCenter.x + screenRadius, y: screenCenter.y)
        guard
            let uvCenter = cutTool.screenPointToWallUV(screenPoint: screenCenter, sceneView: arView, wallData: wall),
            let uvEdge = cutTool.screenPointToWallUV(screenPoint: edge, sceneView: arView, wallData: wall)
        else {
            result(FlutterError(code: "raycast_fail", message: "Could not project circle to wall", details: nil))
            return
        }
        let uvRadius = hypot(uvEdge.x - uvCenter.x, uvEdge.y - uvCenter.y)
        cutTool.addCircleCut(uvCenter: uvCenter, uvRadius: uvRadius, toWall: id)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performUndoCut(wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        let undone = cutTool.undoLastCut(fromWall: id)
        applyMaskAndEmit(wall: wall, result: result, success: undone)
    }

    private func performClearAllCuts(wallIndex: Int, result: @escaping FlutterResult) {
        guard let id = indexToWallId[wallIndex],
              let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        cutTool.clearAllCuts(fromWall: id)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func applyMaskAndEmit(wall: WallData, result: @escaping FlutterResult, success: Bool) {
        let id = wall.id
        let count = cutTool.cutCount(forWall: id)

        if let mat = wall.wallpaperNode?.geometry?.firstMaterial {
            cutTool.applyMask(toMaterial: mat, wallId: id) { [weak self] in
                self?.sendEvent(type: "cutUpdate", data: [
                    "wallIndex": wall.index,
                    "cutCount": count
                ])
                self?.cutOverlay.flashCutApplied()
                result(success)
            }
        } else {
            sendEvent(type: "cutUpdate", data: [
                "wallIndex": wall.index,
                "cutCount": count
            ])
            result(success)
        }
    }

    // MARK: - CutModeOverlayDelegate

    func cutOverlay(_ overlay: CutModeOverlay, didRequestSmartCutAt screenPoint: CGPoint) {
        guard let idx = cutModeWallIndex else { return }
        performSmartCut(at: screenPoint, wallIndex: idx) { _ in }
    }

    func cutOverlay(_ overlay: CutModeOverlay, didCompleteFreehand screenPoints: [CGPoint]) {
        guard let idx = cutModeWallIndex else { return }
        performFreehandCut(screenPoints: screenPoints, wallIndex: idx) { _ in }
    }

    func cutOverlay(_ overlay: CutModeOverlay, didCompleteRectangle screenRect: CGRect) {
        guard let idx = cutModeWallIndex else { return }
        performRectangleCut(screenRect: screenRect, wallIndex: idx) { _ in }
    }

    func cutOverlay(_ overlay: CutModeOverlay, didCompleteCircle screenCenter: CGPoint, radius: CGFloat) {
        guard let idx = cutModeWallIndex else { return }
        performCircleCut(screenCenter: screenCenter, screenRadius: radius, wallIndex: idx) { _ in }
    }

    func cutOverlayDidRequestUndo(_ overlay: CutModeOverlay) {
        guard let idx = cutModeWallIndex else { return }
        performUndoCut(wallIndex: idx) { _ in }
    }

    func cutOverlayDidRequestClear(_ overlay: CutModeOverlay) {
        guard let idx = cutModeWallIndex else { return }
        performClearAllCuts(wallIndex: idx) { _ in }
    }

    func cutOverlayDidRequestDone(_ overlay: CutModeOverlay) {
        cutModeWallIndex = nil
        cutOverlay.hide()
        cutOverlay.isHidden = true
        sendEvent(type: "cutModeDone", data: [:])
    }

    func cutOverlay(_ overlay: CutModeOverlay, didChangeTool tool: CutTool) {
        sendEvent(type: "cutToolChanged", data: ["tool": tool.rawValue])
    }

    // MARK: - ARSCNViewDelegate (auto plane lifecycle)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .vertical else { return }

        // Cancel manual fallback timer — we got a wall
        autoFallbackTimer?.invalidate()

        let index = nextWallIndex
        nextWallIndex += 1
        let w = planeWidth(of: plane)
        let h = planeHeight(of: plane)
        let marker = makeAutoCornerMarker(width: w, height: h, selected: false)
        node.addChildNode(marker)

        let wall = WallData(anchor: plane, markerNode: marker, width: w, height: h, index: index)
        walls[wall.id] = wall
        indexToWallId[index] = wall.id

        if selectedWallId == nil {
            selectedWallId = wall.id
            wall.isSelected = true
            updateMarkerAppearance(wall: wall, selected: true)
        }

        sendEvent(type: "wallDetected", data: [
            "wallIndex": index,
            "width": Double(w),
            "height": Double(h),
            "sqm": Double(w * h)
        ])
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .vertical,
              let wall = walls[plane.identifier] else { return }
        if wall.isLocked { return }
        if wall.isManual { return }   // manual walls don't track plane updates

        let w = planeWidth(of: plane)
        let h = planeHeight(of: plane)
        wall.width = w
        wall.height = h

        wall.markerNode.removeFromParentNode()
        let marker = makeAutoCornerMarker(width: w, height: h, selected: wall.isSelected)
        node.addChildNode(marker)
        wall.markerNode = marker
        if wall.wallpaperNode != nil {
            wall.markerNode.opacity = wall.isSelected ? 1.0 : 0.0
        }

        if let wpNode = wall.wallpaperNode,
           let geom = wpNode.geometry as? SCNPlane,
           let info = wall.currentWallpaper {
            geom.width = CGFloat(w)
            geom.height = CGFloat(h)
            wpNode.simdPosition = plane.center
            if let mat = geom.firstMaterial {
                let t = uvTransform(wallWidth: w, wallHeight: h,
                                    rollWidth: info.rollWidth, rollLength: info.rollLength)
                mat.diffuse.contentsTransform = t
                mat.normal.contentsTransform = t
                mat.roughness.contentsTransform = t
                mat.ambientOcclusion.contentsTransform = t
            }
        }

        sendEvent(type: "wallUpdated", data: [
            "wallIndex": wall.index,
            "width": Double(w),
            "height": Double(h),
            "sqm": Double(w * h)
        ])
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              let wall = walls.removeValue(forKey: plane.identifier) else { return }
        indexToWallId.removeValue(forKey: wall.index)
        cutTool.clearAllCuts(fromWall: wall.id)
        if selectedWallId == plane.identifier {
            selectedWallId = walls.values.first?.id
        }
    }

    // MARK: - Auto-detected plane corner marker

    private func makeAutoCornerMarker(width: Float, height: Float, selected: Bool) -> SCNNode {
        let parent = SCNNode()
        parent.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        let cornerLen: Float = min(0.15, min(width, height) * 0.25)
        let thickness: CGFloat = 0.008
        let color = selected ? goldColor : goldColor.withAlphaComponent(0.55)

        let halfW = width / 2
        let halfH = height / 2

        let corners: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(-halfW,  halfH, 0), SIMD3(-halfW + cornerLen,  halfH, 0), SIMD3(-halfW,  halfH - cornerLen, 0)),
            (SIMD3( halfW,  halfH, 0), SIMD3( halfW - cornerLen,  halfH, 0), SIMD3( halfW,  halfH - cornerLen, 0)),
            (SIMD3(-halfW, -halfH, 0), SIMD3(-halfW + cornerLen, -halfH, 0), SIMD3(-halfW, -halfH + cornerLen, 0)),
            (SIMD3( halfW, -halfH, 0), SIMD3( halfW - cornerLen, -halfH, 0), SIMD3( halfW, -halfH + cornerLen, 0))
        ]
        for (c, hEnd, vEnd) in corners {
            parent.addChildNode(makeLineSegment(from: c, to: hEnd, thickness: thickness, color: color))
            parent.addChildNode(makeLineSegment(from: c, to: vEnd, thickness: thickness, color: color))
        }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.7
        pulse.toValue = 1.0
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        parent.addAnimation(pulse, forKey: "pulse")

        return parent
    }

    private func updateMarkerAppearance(wall: WallData, selected: Bool) {
        let color = selected ? goldColor : goldColor.withAlphaComponent(0.55)
        wall.markerNode.enumerateChildNodes { node, _ in
            if let mat = node.geometry?.firstMaterial {
                mat.diffuse.contents = color
                mat.emission.contents = color
            }
        }
        if wall.wallpaperNode != nil {
            wall.markerNode.opacity = selected ? 1.0 : 0.0
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let est = frame.lightEstimate {
            let newI = est.ambientIntensity
            let newT = est.ambientColorTemperature
            smoothedIntensity = smoothedIntensity * 0.9 + newI * 0.1
            smoothedTemperature = smoothedTemperature * 0.9 + newT * 0.1
            arView.scene.lightingEnvironment.intensity = min(2.0, max(0.3, smoothedIntensity / 1000.0))
        }

        let now = CACurrentMediaTime()
        if now - lastObstacleCheck > obstacleCheckInterval {
            lastObstacleCheck = now
            detectObstacles(in: frame)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sendError(code: "session_failed", message: error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sendEvent(type: "sessionInterrupted", data: [:])
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sendEvent(type: "sessionResumed", data: [:])
        if let cfg = session.configuration {
            session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    private func detectObstacles(in frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let request = VNDetectRectanglesRequest { [weak self] req, _ in
            guard let self = self,
                  let results = req.results as? [VNRectangleObservation] else { return }
            var regions: [CGRect] = []
            for r in results {
                let box = r.boundingBox
                if box.width < 0.4 && box.height < 0.4 {
                    regions.append(box)
                }
            }
            if !regions.isEmpty {
                self.sendEvent(type: "obstacleHint", data: ["count": regions.count])
            }
        }
        request.minimumSize = 0.02
        request.maximumObservations = 20
        request.minimumAspectRatio = 0.3
        request.minimumConfidence = 0.7

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    // MARK: - Disposal

    private func disposeAR() {
        autoFallbackTimer?.invalidate()
        arView.session.pause()
        walls.removeAll()
        indexToWallId.removeAll()
        selectedWallId = nil
        arView.scene.rootNode.enumerateChildNodes { node, _ in node.removeFromParentNode() }
        eventSink = nil
    }

    deinit {
        arView.session.pause()
    }

    // MARK: - Event channel

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func sendEvent(type: String, data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([
                "type": type,
                "data": data
            ])
        }
    }

    private func sendError(code: String, message: String) {
        sendEvent(type: "error", data: ["code": code, "message": message])
    }
}
