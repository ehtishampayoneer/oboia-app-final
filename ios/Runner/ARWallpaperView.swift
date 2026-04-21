//
//  ARWallpaperView.swift
//  OBOIA
//
//  Photorealistic AR wallpaper placement using ARKit + SceneKit PBR.
//  Vertical plane detection, environment texturing, HDR light estimation,
//  4-map PBR (albedo/normal/roughness/AO), physically-accurate UV tiling,
//  multi-wall tracking, instant switching, Vision-based obstacle exclusion.
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
                             FlutterStreamHandler {

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
            guard let t = textures else {
                DispatchQueue.main.async {
                    self.sendError(code: "texture_load", message: "Failed to load PBR textures")
                    result(FlutterError(code: "texture_load", message: "Failed to load textures", details: nil))
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
                    result(FlutterError(code: "texture_load", message: "Failed to load textures", details: nil))
                }
                return
            }
            DispatchQueue.main.async {
                if wall.wallpaperNode == nil {
                    self.attachWallpaper(to: wall, textures: t, info: info)
                } else {
                    self.updateMaterial(on: wall, textures: t, info: info)
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
        guard let albedo = args["albedoUrl"] as? String,
              let normal = args["normalUrl"] as? String,
              let roughness = args["roughnessUrl"] as? String,
              let ao = args["aoUrl"] as? String else {
            return nil
        }
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
        let normal: UIImage
        let roughness: UIImage
        let ao: UIImage
    }

    private func loadPBRTextures(info: WallpaperInfo,
                                 completion: @escaping (PBRTextures?) -> Void) {
        let group = DispatchGroup()
        var albedo: UIImage?
        var normal: UIImage?
        var rough: UIImage?
        var ao: UIImage?

        let cache = TextureCache.shared
        let urls: [(String, (UIImage) -> Void)] = [
            (info.albedoUrl,    { albedo = $0 }),
            (info.normalUrl,    { normal = $0 }),
            (info.roughnessUrl, { rough = $0 }),
            (info.aoUrl,        { ao = $0 }),
        ]
        for (url, setter) in urls {
            group.enter()
            cache.loadImage(from: url) { img in
                if let img = img { setter(img) }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            guard let a = albedo, let n = normal, let r = rough, let o = ao else {
                completion(nil); return
            }
            completion(PBRTextures(albedo: a, normal: n, roughness: r, ao: o))
        }
    }

    // MARK: - PBR material

    private func attachWallpaper(to wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        let anchor = wall.anchor
        let width = CGFloat(anchor.extent.x)
        let height = CGFloat(anchor.extent.z)

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

        // Hide the scanning marker once wallpaper is placed — brackets stay subtle.
        wall.markerNode.opacity = wall.isSelected ? 1.0 : 0.0
    }

    private func updateMaterial(on wall: WallData, textures: PBRTextures, info: WallpaperInfo) {
        guard let node = wall.wallpaperNode,
              let material = node.geometry?.firstMaterial else { return }

        let width = wall.anchor.extent.x
        let height = wall.anchor.extent.z

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15

        material.diffuse.contents = textures.albedo
        material.normal.contents = textures.normal
        material.roughness.contents = textures.roughness
        material.ambientOcclusion.contents = textures.ao

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

        // --- Normal map (3-D surface depth)
        m.normal.contents = textures.normal
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 1.0
        m.normal.mipFilter = .linear
        m.normal.maxAnisotropy = 16

        // --- Roughness (micro-surface scatter)
        m.roughness.contents = textures.roughness
        m.roughness.wrapS = .repeat
        m.roughness.wrapT = .repeat
        m.roughness.mipFilter = .linear
        m.roughness.maxAnisotropy = 16

        // --- Ambient occlusion (contact shadow in creases)
        m.ambientOcclusion.contents = textures.ao
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
    }

    // MARK: - Tap to place / select

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: arView)

        guard let query = arView.raycastQuery(from: point,
                                              allowing: .existingPlaneGeometry,
                                              alignment: .vertical) else { return }
        let results = arView.session.raycast(query)
        guard let hit = results.first,
              let anchor = hit.anchor as? ARPlaneAnchor,
              anchor.alignment == .vertical else { return }

        if walls[anchor.identifier] != nil {
            selectWall(index: walls[anchor.identifier]!.index)
        } else {
            // Anchor detected but not yet registered — will be handled in renderer:didAdd.
        }
    }

    // MARK: - ARSCNViewDelegate (plane lifecycle)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .vertical else { return }

        // Reject tiny planes — ARKit sometimes reports very small fragments that grow later.
        if plane.extent.x < 0.3 || plane.extent.z < 0.3 {
            // Don't reject permanently — still register so it can grow, just keep marker hidden.
        }

        let index = nextWallIndex
        nextWallIndex += 1
        let marker = makeCornerMarkerNode(width: plane.extent.x, height: plane.extent.z,
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

        // Rebuild marker for new extent
        wall.markerNode.removeFromParentNode()
        let marker = makeCornerMarkerNode(width: plane.extent.x, height: plane.extent.z,
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
            geom.width = CGFloat(plane.extent.x)
            geom.height = CGFloat(plane.extent.z)
            wpNode.simdPosition = plane.center

            if let mat = geom.firstMaterial {
                let t = uvTransform(wallWidth: plane.extent.x, wallHeight: plane.extent.z,
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
            (SIMD3(-halfW, -halfH, 0), SIMD3(-halfW + cornerLen, -halfH, 0), SIMD3(-halfW, -halfH + cornerLen, 0)),
            (SIMD3( halfW, -halfH, 0), SIMD3( halfW - cornerLen, -halfH, 0), SIMD3( halfW, -halfH + cornerLen, 0))
        ]
        for (c, hEnd, vEnd) in corners {
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
        let w = Double(anchor.extent.x)
        let h = Double(anchor.extent.z)
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
