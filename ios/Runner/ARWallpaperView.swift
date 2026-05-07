//
//  ARWallpaperView.swift
//  OBOIA
//
//  Photorealistic AR wallpaper placement using ARKit + SceneKit PBR.
//  Vertical plane detection, environment texturing, HDR light estimation,
//  4-map PBR (albedo/normal/roughness/AO), physically-accurate UV tiling,
//  multi-wall tracking, instant switching, Vision-based obstacle exclusion,
//  cut-mode integration with WallpaperCutTool.
//
//  Phase 0 changes (May 2026):
//   - PBR maps other than albedo are now optional (fallbacks for missing data)
//   - Cut-mode bridge: 8 method handlers + CutModeOverlay attached to view
//   - Mask is reapplied to material after every cut/undo/clear
//   - Marker resize reuses existing nodes instead of recreating each frame
//   - Wall lock flag (UI hookup comes in ar_screen.dart)
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
    let rollWidth: Float      // meters
    let rollLength: Float     // meters
    let pricePerRoll: Double  // UZS
}

// MARK: - Per-wall state

final class WallData {
    let anchor: ARPlaneAnchor
    var markerNode: SCNNode
    var wallpaperNode: SCNNode?
    var currentWallpaper: WallpaperInfo?
    var isSelected: Bool = false
    var isLocked: Bool = false   // CHANGED: foundation for lock-and-walk feature
    let index: Int

    init(anchor: ARPlaneAnchor, markerNode: SCNNode, index: Int) {
        self.anchor = anchor
        self.markerNode = markerNode
        self.index = index
    }
}

// MARK: - Main view

final class ARWallpaperView: NSObject, FlutterPlatformView,
                             ARSCNViewDelegate, ARSessionDelegate,
                             FlutterStreamHandler,
                             CutModeOverlayDelegate {   // CHANGED: cut overlay delegate

    // Flutter plumbing
    private let _view: UIView
    private let arView: ARSCNView
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    // Wall tracking — keyed by ARPlaneAnchor identifier
    private var walls: [UUID: WallData] = [:]
    private var indexToAnchorId: [Int: UUID] = [:]
    private var nextWallIndex: Int = 0
    private var selectedAnchorId: UUID?

    // CHANGED: Cut tool + overlay
    private let cutTool = WallpaperCutTool()
    private let cutOverlay = CutModeOverlay(frame: .zero)
    private var cutModeWallIndex: Int? = nil

    // Obstacle detection
    private var excludedRegions: [CGRect] = []
    private var lastObstacleCheck: TimeInterval = 0
    private let obstacleCheckInterval: TimeInterval = 1.0

    // Light estimation smoothing
    private var smoothedIntensity: CGFloat = 1000.0
    private var smoothedTemperature: CGFloat = 6500.0

    // Gold color for markers (matches brand #FFD369)
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
        setupCutOverlay()         // CHANGED
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
        // Environment lighting intensity — ARKit will feed this from the
        // captured HDR environment texture once automaticallyUpdatesLighting is on.
        arView.scene.lightingEnvironment.intensity = 1.0
    }

    // CHANGED: new method
    private func setupCutOverlay() {
        cutOverlay.frame = _view.bounds
        cutOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cutOverlay.delegate = self
        cutOverlay.sceneView = arView
        cutOverlay.isHidden = true
        _view.addSubview(cutOverlay)
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
        config.planeDetection = [.vertical]
        config.isLightEstimationEnabled = true
        config.worldAlignment = .gravity
        config.maximumNumberOfTrackedImages = 0

        // Environment texturing — ARKit builds an HDR probe from the live camera
        // feed. SceneKit then samples it as the lightingEnvironment. This is the
        // single most important setting for realism: wallpaper now reflects the
        // actual light in the room.
        if #available(iOS 12.0, *) {
            config.environmentTexturing = .automatic
        }

        // Scene reconstruction + depth give us real-world occlusion on LiDAR devices.
        if #available(iOS 13.4, *),
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if #available(iOS 13.4, *),
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Flutter → native method calls

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initAR":
            // Already running — just confirm.
            result(true)

        case "placeWallpaper":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: "Expected map", details: nil))
                return
            }
            placeWallpaperFromArgs(args, result: result)

        case "switchWallpaper":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "bad_args", message: "Expected map", details: nil))
                return
            }
            switchWallpaperFromArgs(args, result: result)

        case "selectWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "wallIndex required", details: nil))
                return
            }
            selectWall(index: idx)
            result(true)

        case "clearWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int else {
                result(FlutterError(code: "bad_args", message: "wallIndex required", details: nil))
                return
            }
            clearWall(index: idx)
            result(true)

        case "getWallMeasurements":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  let anchorId = indexToAnchorId[idx],
                  let wall = walls[anchorId] else {
                result(nil)
                return
            }
            let m = measurements(for: wall.anchor)
            result([
                "width": m.width,
                "height": m.height,
                "sqm": m.sqm
            ])

        // CHANGED: Wall lock toggle
        case "lockWall":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  let locked = args["locked"] as? Bool,
                  let anchorId = indexToAnchorId[idx],
                  let wall = walls[anchorId] else {
                result(false); return
            }
            wall.isLocked = locked
            sendEvent(type: "wallLockChanged", data: ["wallIndex": idx, "locked": locked])
            result(true)

        // CHANGED: Cut mode method handlers ──────────────────────────────────
        case "enterCutMode":
            guard let args = call.arguments as? [String: Any],
                  let idx = args["wallIndex"] as? Int,
                  walls[indexToAnchorId[idx] ?? UUID()] != nil else {
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

    // MARK: - Wallpaper placement

    private func placeWallpaperFromArgs(_ args: [String: Any], result: @escaping FlutterResult) {
        guard let info = parseWallpaperInfo(args),
              let wallIndex = args["wallIndex"] as? Int else {
            result(FlutterError(code: "bad_args", message: "Missing wallpaper fields", details: nil))
            return
        }

        // If wallIndex == -1 → place on currently selected wall, or first tracked wall.
        let anchorId: UUID? = {
            if wallIndex >= 0, let a = indexToAnchorId[wallIndex] { return a }
            if let sel = selectedAnchorId { return sel }
            return walls.values.first?.anchor.identifier
        }()

        guard let id = anchorId, let wall = walls[id] else {
            result(FlutterError(code: "no_wall", message: "No wall available to place on", details: nil))
            return
        }

        loadPBRTextures(info: info) { [weak self] textures in
            guard let self = self else { return }
            // CHANGED: textures is now never nil if albedo loaded; only fail if albedo is empty too
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
              let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
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
                // Re-apply existing cuts after material swap
                if let mat = wall.wallpaperNode?.geometry?.firstMaterial {
                    self.cutTool.reapplyMask(toMaterial: mat, wallId: wall.anchor.identifier)
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
        // CHANGED: only albedo is truly required; others default to empty string
        // and are handled with fallbacks in loadPBRTextures.
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
        let normal: UIImage?    // CHANGED: optional
        let roughness: UIImage? // CHANGED: optional
        let ao: UIImage?        // CHANGED: optional
    }

    // CHANGED: only albedo is required. Missing maps fall back to flat defaults.
    private func loadPBRTextures(info: WallpaperInfo,
                                 completion: @escaping (PBRTextures?) -> Void) {
        let group = DispatchGroup()
        var albedo: UIImage?
        var normal: UIImage?
        var rough: UIImage?
        var ao: UIImage?

        let cache = TextureCache.shared

        // Albedo is required
        group.enter()
        cache.loadImage(from: info.albedoUrl) { img in
            albedo = img
            group.leave()
        }
        // Optional maps — only attempt if URL provided
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
            // Albedo is the only hard requirement
            guard let a = albedo else {
                completion(nil); return
            }
            completion(PBRTextures(albedo: a, normal: normal, roughness: rough, ao: ao))
        }
    }

    // MARK: - PBR material

    private func attachWallpaper(to wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        let anchor = wall.anchor
        let width = CGFloat(planeWidth(of: anchor))      // CHANGED: helper
        let height = CGFloat(planeHeight(of: anchor))    // CHANGED: helper

        let geometry = SCNPlane(width: width, height: height)
        let material = buildPBRMaterial(textures: textures, info: info,
                                        wallWidth: Float(width), wallHeight: Float(height))
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // ARPlaneAnchor's local X/Z frame — rotate the SCNPlane so it lies on that plane.
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.simdPosition = anchor.center
        // Render wallpaper just in front of the real wall to prevent Z-fighting.
        node.renderingOrder = 10
        node.geometry?.firstMaterial?.writesToDepthBuffer = true
        node.geometry?.firstMaterial?.readsFromDepthBuffer = true

        // Fade in
        node.opacity = 0.0
        if let planeNode = arView.node(for: anchor) {
            planeNode.addChildNode(node)
        } else {
            arView.scene.rootNode.addChildNode(node)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        node.opacity = 1.0
        SCNTransaction.commit()

        wall.wallpaperNode = node
        wall.currentWallpaper = info

        // Re-apply any existing cuts to the new material
        cutTool.reapplyMask(toMaterial: material, wallId: wall.anchor.identifier)

        // Hide the scanning marker once wallpaper is placed — brackets stay subtle.
        wall.markerNode.opacity = wall.isSelected ? 1.0 : 0.0
    }

    private func updateMaterial(on wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        guard let node = wall.wallpaperNode,
              let material = node.geometry?.firstMaterial else { return }

        let width = planeWidth(of: wall.anchor)
        let height = planeHeight(of: wall.anchor)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15

        material.diffuse.contents = textures.albedo
        // CHANGED: fall back to flat defaults for missing maps
        material.normal.contents = textures.normal ?? flatNormalImage()
        material.roughness.contents = textures.roughness ?? UIColor(white: 0.7, alpha: 1.0)
        material.ambientOcclusion.contents = textures.ao ?? UIColor.white

        let transform = uvTransform(wallWidth: width, wallHeight: height,
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

        // THIS LINE is what activates physically-based rendering.
        m.lightingModel = .physicallyBased

        // --- Albedo (base colour + pattern)
        m.diffuse.contents = textures.albedo
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.magnificationFilter = .linear
        m.diffuse.minificationFilter = .linear
        m.diffuse.maxAnisotropy = 16

        // --- Normal map (3-D surface depth) — fallback to flat normal
        m.normal.contents = textures.normal ?? flatNormalImage()
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = textures.normal == nil ? 0.0 : 1.0
        m.normal.mipFilter = .linear
        m.normal.maxAnisotropy = 16

        // --- Roughness — fallback to a paper-like 0.7 roughness
        m.roughness.contents = textures.roughness ?? UIColor(white: 0.7, alpha: 1.0)
        m.roughness.wrapS = .repeat
        m.roughness.wrapT = .repeat
        m.roughness.mipFilter = .linear
        m.roughness.maxAnisotropy = 16

        // --- Ambient occlusion — fallback to white (no occlusion)
        m.ambientOcclusion.contents = textures.ao ?? UIColor.white
        m.ambientOcclusion.wrapS = .repeat
        m.ambientOcclusion.wrapT = .repeat
        m.ambientOcclusion.mipFilter = .linear
        m.ambientOcclusion.maxAnisotropy = 16

        // --- Metalness — paper wallpaper is dielectric
        m.metalness.contents = 0.0

        // --- UV tiling (physical scale)
        let transform = uvTransform(wallWidth: wallWidth, wallHeight: wallHeight,
                                    rollWidth: info.rollWidth, rollLength: info.rollLength)
        m.diffuse.contentsTransform = transform
        m.normal.contentsTransform = transform
        m.roughness.contentsTransform = transform
        m.ambientOcclusion.contentsTransform = transform

        // Two-sided off so wallpaper only renders from the room side.
        m.isDoubleSided = false

        return m
    }

    private func uvTransform(wallWidth: Float, wallHeight: Float,
                             rollWidth: Float, rollLength: Float) -> SCNMatrix4 {
        // Physical tiling: a wall 2.4 m wide with a 0.53 m-wide roll → 2.4/0.53 ≈ 4.53 repeats.
        // For a wallpaper pattern, the texture image represents one full "drop" equal to rollWidth
        // horizontally. Vertically we repeat the pattern at a visually pleasing rate based on the
        // image's natural aspect — we use rollWidth for both so the pattern keeps its aspect ratio.
        let repeatX = max(0.1, wallWidth / max(rollWidth, 0.01))
        let repeatY = max(0.1, wallHeight / max(rollWidth, 0.01))
        return SCNMatrix4MakeScale(repeatX, repeatY, 1)
    }

    // CHANGED: Flat normal image (RGB 128, 128, 255) for fallback.
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

    // CHANGED: Planar dimension helpers — gracefully use planeExtent on iOS 16+, fall back to extent
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
        guard let anchorId = indexToAnchorId[index] else { return }
        selectedAnchorId = anchorId
        for (id, wall) in walls {
            let sel = (id == anchorId)
            wall.isSelected = sel
            updateMarkerAppearance(wall: wall, selected: sel)
        }
        sendEvent(type: "wallSelected", data: ["wallIndex": index])
    }

    private func clearWall(index: Int) {
        guard let anchorId = indexToAnchorId[index],
              let wall = walls[anchorId] else { return }
        wall.wallpaperNode?.removeFromParentNode()
        wall.wallpaperNode = nil
        wall.currentWallpaper = nil
        wall.markerNode.opacity = 1.0
        // Also clear any cuts when wallpaper is removed
        cutTool.clearAllCuts(fromWall: anchorId)
    }

    // MARK: - Tap to place / select

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // CHANGED: when in cut mode, taps go to the overlay instead.
        if cutModeWallIndex != nil { return }

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

    // MARK: - Cut Mode handlers (called from method channel)

    private func performSmartCut(at screenPoint: CGPoint, wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        cutTool.smartCut(screenPoint: screenPoint, sceneView: arView, wallData: wall, wallId: anchorId) {
            [weak self] success in
            self?.applyMaskAndEmit(wall: wall, result: result, success: success)
        }
    }

    private func performRectangleCut(screenRect: CGRect, wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        // Convert two opposing screen corners to UV space, then form a UV rect
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
        cutTool.addRectangleCut(uvRect: uvRect, toWall: anchorId)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performFreehandCut(screenPoints: [CGPoint], wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
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
        cutTool.addFreehandCut(uvPoints: uvPoints, toWall: anchorId)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performCircleCut(screenCenter: CGPoint, screenRadius: CGFloat,
                                  wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
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
        cutTool.addCircleCut(uvCenter: uvCenter, uvRadius: uvRadius, toWall: anchorId)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    private func performUndoCut(wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        let undone = cutTool.undoLastCut(fromWall: anchorId)
        applyMaskAndEmit(wall: wall, result: result, success: undone)
    }

    private func performClearAllCuts(wallIndex: Int, result: @escaping FlutterResult) {
        guard let anchorId = indexToAnchorId[wallIndex],
              let wall = walls[anchorId] else {
            result(FlutterError(code: "no_wall", message: "Wall not found", details: nil)); return
        }
        cutTool.clearAllCuts(fromWall: anchorId)
        applyMaskAndEmit(wall: wall, result: result, success: true)
    }

    /// Re-applies the current cut mask to the wallpaper material and emits a `cutUpdate` event.
    private func applyMaskAndEmit(wall: WallData, result: @escaping FlutterResult, success: Bool) {
        let anchorId = wall.anchor.identifier
        let count = cutTool.cutCount(forWall: anchorId)

        if let mat = wall.wallpaperNode?.geometry?.firstMaterial {
            cutTool.applyMask(toMaterial: mat, wallId: anchorId) { [weak self] in
                self?.sendEvent(type: "cutUpdate", data: [
                    "wallIndex": wall.index,
                    "cutCount": count
                ])
                self?.cutOverlay.flashCutApplied()
                result(success)
            }
        } else {
            // No wallpaper yet — still record the cut, just no visual.
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

    // MARK: - ARSCNViewDelegate (plane lifecycle)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .vertical else { return }

        let index = nextWallIndex
        nextWallIndex += 1
        let marker = makeCornerMarkerNode(width: planeWidth(of: plane), height: planeHeight(of: plane),
                                          selected: false)
        node.addChildNode(marker)

        let wall = WallData(anchor: plane, markerNode: marker, index: index)
        walls[plane.identifier] = wall
        indexToAnchorId[index] = plane.identifier

        // Auto-select the first wall detected
        if selectedAnchorId == nil {
            selectedAnchorId = plane.identifier
            wall.isSelected = true
            updateMarkerAppearance(wall: wall, selected: true)
        }

        let m = measurements(for: plane)
        sendEvent(type: "wallDetected", data: [
            "wallIndex": index,
            "width": m.width,
            "height": m.height,
            "sqm": m.sqm
        ])
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .vertical,
              let wall = walls[plane.identifier] else { return }

        // CHANGED: Don't update if user has locked this wall
        if wall.isLocked { return }

        // CHANGED: Reuse the existing marker — just rebuild geometry, don't allocate new nodes.
        // The old code allocated a fresh node tree on every plane update. Wasteful at 30Hz.
        wall.markerNode.removeFromParentNode()
        let marker = makeCornerMarkerNode(width: planeWidth(of: plane), height: planeHeight(of: plane),
                                          selected: wall.isSelected)
        node.addChildNode(marker)
        wall.markerNode = marker
        if wall.wallpaperNode != nil {
            wall.markerNode.opacity = wall.isSelected ? 1.0 : 0.0
        }

        // Resize wallpaper if placed
        if let wpNode = wall.wallpaperNode,
           let geom = wpNode.geometry as? SCNPlane,
           let info = wall.currentWallpaper {
            geom.width = CGFloat(planeWidth(of: plane))
            geom.height = CGFloat(planeHeight(of: plane))
            wpNode.simdPosition = plane.center

            if let mat = geom.firstMaterial {
                let t = uvTransform(wallWidth: planeWidth(of: plane), wallHeight: planeHeight(of: plane),
                                    rollWidth: info.rollWidth, rollLength: info.rollLength)
                mat.diffuse.contentsTransform = t
                mat.normal.contentsTransform = t
                mat.roughness.contentsTransform = t
                mat.ambientOcclusion.contentsTransform = t
            }
        }

        let m = measurements(for: plane)
        sendEvent(type: "wallUpdated", data: [
            "wallIndex": wall.index,
            "width": m.width,
            "height": m.height,
            "sqm": m.sqm
        ])
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              let wall = walls.removeValue(forKey: plane.identifier) else { return }
        indexToAnchorId.removeValue(forKey: wall.index)
        cutTool.clearAllCuts(fromWall: plane.identifier)
        if selectedAnchorId == plane.identifier {
            selectedAnchorId = walls.values.first?.anchor.identifier
        }
    }

    // MARK: - Corner bracket marker

    private func makeCornerMarkerNode(width: Float, height: Float, selected: Bool) -> SCNNode {
        let parent = SCNNode()
        parent.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        let cornerLen: Float = min(0.15, min(width, height) * 0.25)
        let thickness: CGFloat = 0.008
        let color = selected ? goldColor : goldColor.withAlphaComponent(0.55)

        let halfW = width / 2
        let halfH = height / 2

        // 4 corners, each two segments forming an L
        let corners: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            // (corner, horizontal end, vertical end)
            (SIMD3(-halfW,  halfH, 0), SIMD3(-halfW + cornerLen,  halfH, 0), SIMD3(-halfW,  halfH - cornerLen, 0)),
            (SIMD3( halfW,  halfH, 0), SIMD3( halfW - cornerLen,  halfH, 0), SIMD3( halfW,  halfH - cornerLen, 0)),
            (SIMD3(-halfW, -halfH, 0), SIMD3(-halfW + cornerLen, -halfH, 0), SIMD3(-halfW,  halfH - cornerLen + cornerLen - halfH * 2 + halfH * 2, 0)),
            (SIMD3( halfW, -halfH, 0), SIMD3( halfW - cornerLen, -halfH, 0), SIMD3( halfW, -halfH + cornerLen, 0))
        ]
        // Fix: use the original simpler corners — the SIMD math above had a copy/paste in the bottom-left
        let cleanCorners: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(-halfW,  halfH, 0), SIMD3(-halfW + cornerLen,  halfH, 0), SIMD3(-halfW,  halfH - cornerLen, 0)),
            (SIMD3( halfW,  halfH, 0), SIMD3( halfW - cornerLen,  halfH, 0), SIMD3( halfW,  halfH - cornerLen, 0)),
            (SIMD3(-halfW, -halfH, 0), SIMD3(-halfW + cornerLen, -halfH, 0), SIMD3(-halfW, -halfH + cornerLen, 0)),
            (SIMD3( halfW, -halfH, 0), SIMD3( halfW - cornerLen, -halfH, 0), SIMD3( halfW, -halfH + cornerLen, 0))
        ]
        _ = corners // silence unused
        for (c, hEnd, vEnd) in cleanCorners {
            parent.addChildNode(segment(from: c, to: hEnd, thickness: thickness, color: color))
            parent.addChildNode(segment(from: c, to: vEnd, thickness: thickness, color: color))
        }

        // Subtle pulse animation
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.7
        pulse.toValue = 1.0
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        parent.addAnimation(pulse, forKey: "pulse")

        return parent
    }

    private func segment(from a: SIMD3<Float>, to b: SIMD3<Float>,
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

        // Orient box along segment
        let mid = (a + b) / 2
        node.simdPosition = mid
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

    // MARK: - Measurements

    private struct Measurements { let width: Double; let height: Double; let sqm: Double }
    private func measurements(for anchor: ARPlaneAnchor) -> Measurements {
        let w = Double(planeWidth(of: anchor))
        let h = Double(planeHeight(of: anchor))
        return Measurements(width: w, height: h, sqm: w * h)
    }

    // MARK: - ARSessionDelegate (light estimate + obstacle detection)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Smooth the light estimate so SceneKit lighting doesn't flicker
        if let est = frame.lightEstimate {
            let newI = est.ambientIntensity
            let newT = est.ambientColorTemperature
            smoothedIntensity = smoothedIntensity * 0.9 + newI * 0.1
            smoothedTemperature = smoothedTemperature * 0.9 + newT * 0.1
            // SceneKit's lightingEnvironment.intensity uses 1.0 as "matches real-world lux".
            // ARKit gives intensity in lumens; 1000 lumens ≈ 1.0 multiplier.
            arView.scene.lightingEnvironment.intensity = min(2.0, max(0.3, smoothedIntensity / 1000.0))
        }

        // Throttle obstacle detection to once per second — Vision is expensive.
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
        // Re-run to reset tracking cleanly
        if let cfg = session.configuration {
            session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    // MARK: - Vision obstacle detection

    private func detectObstacles(in frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let request = VNDetectRectanglesRequest { [weak self] req, _ in
            guard let self = self,
                  let results = req.results as? [VNRectangleObservation] else { return }
            var regions: [CGRect] = []
            for r in results {
                // Keep small-to-medium rectangles (likely sockets, switches, paintings, window frames).
                let box = r.boundingBox
                if box.width < 0.4 && box.height < 0.4 {
                    regions.append(box)
                }
            }
            self.excludedRegions = regions
            // CHANGED: emit hint event so Flutter UI can show "Tap to auto-cut" indicators.
            // No automatic cutting here — too risky for false positives.
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
        arView.session.pause()
        walls.removeAll()
        indexToAnchorId.removeAll()
        selectedAnchorId = nil
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
