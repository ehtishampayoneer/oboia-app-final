// RoomScanner.swift
// OBOIA - Complete LiDAR RoomPlan Scanner

import RoomPlan
import ARKit
import SceneKit

struct DetectedSurface: Codable {
    let id: String
    let type: String
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
    let type: String
    var excluded: Bool = false
}

@available(iOS 17.0, *)
final class RoomScanner: NSObject {

    private weak var arView: ARSCNView?
    private var messenger: FlutterBinaryMessenger?
    private var eventSink: ((Any) -> Void)?

    private var captureSession: RoomCaptureSession?
    private var roomBuilder: RoomBuilder?

    private var isScanning = false
    private let lock = NSLock()
    private var lastUpdateTime: TimeInterval = 0
    private let updateDebounce: TimeInterval = 0.5

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

    func start() {
        guard isScanning == false else { return }

        isScanning = true

        let session = RoomCaptureSession()

        var config = RoomCaptureSession.Configuration()
        config.textured = true
        config.isCoachingEnabled = true
        session.run(configuration: config)

        if let arView = arView {
            arView.session = session.arSession
            arView.session.delegate = self
            arView.automaticallyUpdatesLighting = true
            arView.debugOptions = [.showFeaturePoints]
        }

        session.delegate = self

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

        let final = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        completion(final)

        self.captureSession = nil
        if let arView = arView {
            arView.session.delegate = nil
        }
    }

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

    private func processRoom(_ capturedRoom: CapturedRoom) {
        var surfaces: [DetectedSurface] = []
        var objects: [DetectedObject] = []

        for wall in capturedRoom.walls {
            let id = wall.identifier.uuidString
            let w = wall.dimensions.x
            let h = wall.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "wall", width: w, height: h, area: w * h))
        }

        for door in capturedRoom.doors {
            let id = door.identifier.uuidString
            let w = door.dimensions.x
            let h = door.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "door", width: w, height: h, area: w * h))
        }

        for window in capturedRoom.windows {
            let id = window.identifier.uuidString
            let w = window.dimensions.x
            let h = window.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "window", width: w, height: h, area: w * h))
        }

        for opening in capturedRoom.openings {
            let id = opening.identifier.uuidString
            let w = opening.dimensions.x
            let h = opening.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "opening", width: w, height: h, area: w * h))
        }

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

@available(iOS 17.0, *)
extension RoomScanner: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
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
            eventSink?(["type": "scanComplete", "data": "ok"])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        eventSink?(["type": "scanInstruction", "data": ["instruction": "\(instruction)"]])
    }
}

@available(iOS 17.0, *)
extension RoomScanner: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {}
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {}
}
