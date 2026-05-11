// RoomScanner.swift
// OBOIA - Complete LiDAR RoomPlan Scanner
// Replaces RoomScanController.swift. iOS 17+ LiDAR required.

import RoomPlan
import ARKit
import SceneKit

// MARK: - Data Models for Flutter Events

struct DetectedSurface: Codable {
    let id: String
    let type: String       // "wall", "door", "window", "opening"
    let width: Float
    let height: Float
    let area: Float
    var excluded: Bool = false
}

struct ScanSnapshot: Codable {
    let surfaces: [DetectedSurface]
    let objects: [DetectedObject]
}

struct DetectedObject: Codable {
    let id: String
    let type: String       // "furniture", "unknown"
    var excluded: Bool = false
}

// MARK: - RoomScanner Class

@available(iOS 17.0, *)
final class RoomScanner: NSObject, ObservableObject {

    // Dependencies
    private weak var arView: ARSCNView?
    private var messenger: FlutterBinaryMessenger?
    private var eventSink: ((Any) -> Void)?

    // RoomPlan
    private var captureSession: RoomCaptureSession?
    private var roomBuilder: RoomBuilder?

    // State
    private var isScanning = false
    private let lock = NSLock()
    private var lastUpdateTime: TimeInterval = 0
    private let updateDebounce: TimeInterval = 0.5 // 500ms debounce

    // Latest processed snapshot
    private var currentSurfaces: [DetectedSurface] = []
    private var currentObjects: [DetectedObject] = []

    init(arView: ARSCNView?, messenger: FlutterBinaryMessenger?) {
        self.arView = arView
        self.messenger = messenger
        super.init()
    }

    func setEventSink(_ sink: @escaping (Any) -> Void) {
        eventSink = sink
    }

    // MARK: - Start / Stop

    func start() {
        guard isScanning == false else { return }

        isScanning = true

        // Create a fresh RoomCaptureSession (no args → uses new ARSession)
        let session = RoomCaptureSession()

        // Configure for best results
        var config = RoomCaptureSession.Configuration()
        config.isTextured = true
        config.isCoachingEnabled = true
        session.run(configuration: config)

        // Attach to the shared ARSCNView for rendering
        if let arView = arView {
            arView.session = session.arSession
            arView.session.delegate = self
            arView.automaticallyUpdatesLighting = true

            // Ensure we render the point cloud and mesh
            arView.debugOptions = [.showFeaturePoints] // shows LiDAR points
        }

        // Set delegates
        session.delegate = self

        // Create builder for final model later
        roomBuilder = RoomBuilder(options: [])

        self.captureSession = session
    }

    func stop(completion: @escaping (ScanSnapshot?) -> Void) {
        guard isScanning else {
            completion(nil)
            return
        }
        isScanning = false

        guard let session = captureSession else {
            completion(nil)
            return
        }

        session.stop()
        roomBuilder = nil

        // Return the final snapshot immediately (already built during scan)
        let final = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        completion(final)

        // Clean up
        self.captureSession = nil
        if let arView = arView {
            arView.session.delegate = nil
        }
    }

    // MARK: - Exclusion Toggle

    func toggleSurfaceExclusion(id: String) -> Bool? {
        guard let idx = currentSurfaces.firstIndex(where: { $0.id == id }) else { return nil }
        currentSurfaces[idx].excluded.toggle()
        emitUpdate()
        return currentSurfaces[idx].excluded
    }

    func toggleObjectExclusion(id: String) -> Bool? {
        guard let idx = currentObjects.firstIndex(where: { $0.id == id }) else { return nil }
        currentObjects[idx].excluded.toggle()
        emitUpdate()
        return currentObjects[idx].excluded
    }

    // MARK: - Private: Process CapturedRoom into stable snapshot

    private func processRoom(_ capturedRoom: CapturedRoom) {
        var surfaces: [DetectedSurface] = []
        var objects: [DetectedObject] = []

        // Walls
        for wall in capturedRoom.walls {
            let id = wall.identifier.uuidString
            let w = wall.dimensions.x
            let h = wall.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "wall", width: w, height: h, area: w * h))
        }

        // Doors
        for door in capturedRoom.doors {
            let id = door.identifier.uuidString
            let w = door.dimensions.x
            let h = door.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "door", width: w, height: h, area: w * h))
        }

        // Windows
        for window in capturedRoom.windows {
            let id = window.identifier.uuidString
            let w = window.dimensions.x
            let h = window.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "window", width: w, height: h, area: w * h))
        }

        // Openings
        for opening in capturedRoom.openings {
            let id = opening.identifier.uuidString
            let w = opening.dimensions.x
            let h = opening.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "opening", width: w, height: h, area: w * h))
        }

        // Objects (furniture)
        for obj in capturedRoom.objects {
            let id = obj.identifier.uuidString
            objects.append(DetectedObject(id: id, type: obj.category == .storage ? "furniture" : "unknown"))
        }

        self.currentSurfaces = surfaces
        self.currentObjects = objects
    }

    private func emitUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.emitUpdate() }
            return
        }
        let snapshot = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        if let jsonData = try? JSONEncoder().encode(snapshot),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            eventSink?(["type": "scanUpdate", "data": jsonString])
        }
    }
}

// MARK: - RoomCaptureSessionDelegate

@available(iOS 17.0, *)
extension RoomScanner: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // Debounce: only process every 0.5s to avoid thrashing
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime > updateDebounce else { return }
        lastUpdateTime = now

        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error = error {
            eventSink?(["type": "scanFailed", "data": ["message": error.localizedDescription]])
        } else {
            // Final stable model will be delivered on stop()
            eventSink?(["type": "scanComplete", "data": "ok"])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        eventSink?(["type": "scanInstruction", "data": ["instruction": "\(instruction)"]])
    }
}

// MARK: - ARSessionDelegate (for rendering only)

@available(iOS 17.0, *)
extension RoomScanner: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // LiDAR point cloud automatically visible via debugOptions
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // Not used
    }
}
