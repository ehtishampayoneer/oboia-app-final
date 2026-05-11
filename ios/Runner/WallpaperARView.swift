// WallpaperARView.swift
// OBOIA — Clean AR Wallpaper Viewer
// Replaces ARWallpaperView.swift completely.
// iOS 17+ LiDAR. Uses RoomScanner for scanning, ARKit planes for fallback.

import ARKit
import SceneKit
import Flutter
import UIKit

// MARK: - AR Mode

enum ARViewMode: String {
    case scanning = "scanning"
    case preview  = "preview"
    case legacy   = "legacy"
}

// MARK: - WallpaperARView (FlutterPlatformView)

final class WallpaperARView: NSObject, FlutterPlatformView {

    // ── Public dependencies ──────────────────────────────────────
    private let sceneView: ARSCNView
    private let messenger: FlutterBinaryMessenger
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    // ── AR State ──────────────────────────────────────────────────
    private var currentMode: ARViewMode = .preview
    private var roomScanner: RoomScanner?
    private var wallTextureCache = TextureCache()

    // Wallpaper nodes
    private var wallNodes: [String: SCNNode] = [:]   // surfaceID → SCNNode

    // Manual wall selection state (fallback)
    // TODO: Phase 2

    // Cut / eraser stubs — will be replaced by EraserTool later
    private var eraserTool: (() -> Void)? = nil // placeholder

    // ── Event Sink ───────────────────────────────────────────────
    private var eventSink: ((Any) -> Void)?

    // ── Init ─────────────────────────────────────────────────────
    init(frame: CGRect,
         viewId: Int64,
         messenger: FlutterBinaryMessenger,
         args: Any?) {
        self.sceneView = ARSCNView(frame: frame)
        self.messenger = messenger

        // Method channel
        self.channel = FlutterMethodChannel(
            name: "com.oboia/ar",
            binaryMessenger: messenger
        )
        // Event channel
        self.eventChannel = FlutterEventChannel(
            name: "com.oboia/ar_events",
            binaryMessenger: messenger
        )

        super.init()

        // AR setup
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true

        // Show feature points for LiDAR magic (will be disabled in preview mode)
        sceneView.debugOptions = [.showFeaturePoints]

        // Method call handler
        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result)
        }
    }

    func view() -> UIView {
        return sceneView
    }

    // MARK: - Method Handler

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "initAR":
            initAR(result: result)
        case "disposeAR":
            disposeAR(result: result)
        case "setARMode":
            if let modeStr = call.arguments as? String {
                setARMode(modeStr, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "mode required", details: nil))
            }
        case "startScan":
            startScan(result: result)
        case "stopScan":
            stopScan(result: result)
        case "placeWallpaper":
            placeWallpaper(call, result: result)
        case "switchWallpaper":
            switchWallpaper(call, result: result)
        case "selectWall":
            selectWall(call, result: result)
        case "clearWall":
            clearWall(call, result: result)
        case "lockWall":
            lockWall(call, result: result)
        case "getWallMeasurements":
            getWallMeasurements(call, result: result)
        // Cut mode stubs (will be implemented with EraserTool later)
        case "enterCutMode", "exitCutMode", "smartCut", "rectangleCut",
             "freehandCut", "circleCut", "undoCut", "clearAllCuts":
            result(nil) // no-op for now
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ──────────────── INIT / DISPOSE ─────────────────────────────

    private func initAR(result: @escaping FlutterResult) {
        // Boot the AR session with a standard configuration
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical]
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "ready"])
        result(nil)
    }

    private func disposeAR(result: @escaping FlutterResult) {
        sceneView.session.pause()
        result(nil)
    }

    // ──────────────── MODE SWITCHING ─────────────────────────────

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        guard let newMode = ARViewMode(rawValue: mode) else {
            result(FlutterError(code: "INVALID_MODE", message: "Unknown mode: \(mode)", details: nil))
            return
        }
        currentMode = newMode

        switch newMode {
        case .scanning:
            // Disable plane detection during scan
            sceneView.debugOptions = [.showFeaturePoints]
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = []   // no auto-plane
            sceneView.session.run(config, options: [.resetTracking])
        case .preview:
            // Enable plane detection for fallback walls
            sceneView.debugOptions = []  // clean view
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            sceneView.session.run(config, options: [])
        case .legacy:
            sceneView.debugOptions = [.showFeaturePoints]
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            sceneView.session.run(config, options: [])
        }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // ──────────────── ROOM SCANNING ──────────────────────────────

    private func startScan(result: @escaping FlutterResult) {
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "UNSUPPORTED", message: "iOS 17+ required", details: nil))
            return
        }
        // Ensure we are in scanning mode
        setARMode("scanning") { _ in }

        let scanner = RoomScanner(arView: sceneView, messenger: messenger)
        scanner.setEventSink { [weak self] (event) in
            self?.eventSink?(event)
        }
        scanner.start()
        self.roomScanner = scanner
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        guard let scanner = roomScanner else {
            result(nil)
            return
        }
        scanner.stop { [weak self] snapshot in
            // Emit scanComplete with snapshot
            if let snapshot = snapshot,
               let jsonData = try? JSONEncoder().encode(snapshot),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self?.emit("scanComplete", data: ["snapshot": jsonString])
            } else {
                self?.emit("scanComplete", data: ["snapshot": ""])
            }
            // Clean up
            self?.roomScanner = nil
            // Switch to preview mode to view results
            self?.setARMode("preview") { _ in }
        }
        result(nil)
    }

    // ──────────────── WALLPAPER PLACEMENT ────────────────────────

    private func placeWallpaper(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let albedoUrl = args["albedoUrl"] as? String,
              let wallIndex = args["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "albedoUrl & wallIndex required", details: nil))
            return
        }

        let normalUrl = args["normalUrl"] as? String
        let roughnessUrl = args["roughnessUrl"] as? String
        let aoUrl = args["aoUrl"] as? String

        // Load wallpaper texture (async)
        wallTextureCache.loadPBRTextures(
            albedoURL: albedoUrl,
            normalURL: normalUrl,
            roughnessURL: roughnessUrl,
            aoURL: aoUrl
        ) { [weak self] material in
            guard let self = self else { return }
            // Find the wall node for this index (using ARKit fallback for now)
            if let node = self.wallNodes[String(wallIndex)] {
                node.geometry?.firstMaterial = material
                self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": true])
            } else {
                self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": false])
            }
            result(nil)
        }
    }

    private func switchWallpaper(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Reuse placeWallpaper logic
        placeWallpaper(call, result: result)
    }

    private func selectWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Placeholder: highlight the selected wall
        guard let wallIndex = (call.arguments as? [String: Any])?["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex required", details: nil))
            return
        }
        // Emit event (UI will reflect selection)
        emit("wallSelected", data: ["wallIndex": wallIndex])
        result(nil)
    }

    private func clearWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let wallIndex = (call.arguments as? [String: Any])?["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex required", details: nil))
            return
        }
        if let node = wallNodes[String(wallIndex)] {
            node.geometry?.firstMaterial = nil
            emit("wallCleared", data: ["wallIndex": wallIndex])
        }
        result(nil)
    }

    private func lockWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let wallIndex = args["wallIndex"] as? Int,
              let locked = args["locked"] as? Bool else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex & locked required", details: nil))
            return
        }
        emit("wallLockChanged", data: ["wallIndex": wallIndex, "locked": locked])
        result(nil)
    }

    private func getWallMeasurements(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // For now return dummy data; later will come from captured room surfaces
        guard let wallIndex = (call.arguments as? [String: Any])?["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex required", details: nil))
            return
        }
        // TODO: use room scanner's last snapshot to get dimensions
        result([
            "width": 0.0,
            "height": 0.0,
            "sqm": 0.0
        ])
    }

    // ──────────────── HELPERS ────────────────────────────────────

    private func emit(_ type: String, data: [String: Any] = [:]) {
        eventSink?(["type": type, "data": data])
    }
}

// MARK: - ARSCNViewDelegate / ARSessionDelegate

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Not used currently
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        // Auto-wallpaper on detected vertical planes (legacy mode)
        guard currentMode == .legacy || currentMode == .preview,
              let planeAnchor = anchor as? ARPlaneAnchor,
              planeAnchor.alignment == .vertical else { return }

        let plane = SCNPlane(width: CGFloat(planeAnchor.extent.x),
                             height: CGFloat(planeAnchor.extent.z))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.3)
        plane.materials = [material]

        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3(planeAnchor.center.x, planeAnchor.center.y, planeAnchor.center.z)
        planeNode.eulerAngles = SCNVector3(-Float.pi/2, 0, 0) // rotate to vertical
        node.addChildNode(planeNode)

        let wallId = planeAnchor.identifier.uuidString
        wallNodes[wallId] = planeNode
        emit("wallDetected", data: ["wallIndex": wallId, "type": "vertical"])
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        // Update plane geometry if needed
    }
}
