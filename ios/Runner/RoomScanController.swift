//
//  RoomScanController.swift
//  OBOIA
//
//  Wraps Apple's RoomCaptureSession (RoomPlan) to detect real walls, doors,
//  windows, openings, and furniture using LiDAR.
//
//  IMPORTANT ARCHITECTURE NOTE (Patch 2.1):
//  This controller OWNS its ARSession. It creates RoomCaptureSession() with
//  no parameters (default init), which gives it an internal ARSession that
//  RoomPlan fully controls. Callers (e.g. ARWallpaperView) should ADOPT this
//  ARSession by assigning it to their ARSCNView.session property. This avoids
//  the "Capture scene exceeded limit" error that happens when RoomPlan
//  receives a pre-configured external ARSession.
//
//  Requires: iOS 17.0+
//  Requires: LiDAR-capable device (iPhone 12 Pro and later)
//

import Foundation
import ARKit
import RoomPlan
import simd

// MARK: - Public data model

struct DetectedSurface {
    enum Kind: String {
        case wall
        case door
        case window
        case opening
    }

    let id: UUID
    let kind: Kind
    let width: Float
    let height: Float
    let transform: simd_float4x4
    let confidence: Float
    var isExcluded: Bool

    var sqm: Float { width * height }
}

struct DetectedObject {
    let id: UUID
    let category: String
    let dimensions: SIMD3<Float>
    let transform: simd_float4x4
    let confidence: Float
    var isExcluded: Bool
}

struct ScanSnapshot {
    let surfaces: [DetectedSurface]
    let objects: [DetectedObject]
    let isFinal: Bool
}

// MARK: - Delegate protocol

protocol RoomScanControllerDelegate: AnyObject {
    func roomScanDidStart(_ controller: RoomScanController)
    func roomScan(_ controller: RoomScanController, didUpdate snapshot: ScanSnapshot)
    func roomScan(_ controller: RoomScanController, didFinishWith snapshot: ScanSnapshot)
    func roomScan(_ controller: RoomScanController, didFailWith error: Error)
    func roomScan(_ controller: RoomScanController,
                  instructionChangedTo instruction: RoomCaptureSession.Instruction)
}

// MARK: - Controller

@available(iOS 17.0, *)
final class RoomScanController: NSObject {

    // MARK: Public

    weak var delegate: RoomScanControllerDelegate?

    private(set) var isScanning: Bool = false
    private(set) var latestSnapshot: ScanSnapshot?

    static var isDeviceSupported: Bool {
        return RoomCaptureSession.isSupported
    }

    /// The ARSession that RoomPlan owns. Callers should adopt this on their
    /// ARSCNView while scanning is active (e.g. `arView.session = controller.arSession`).
    var arSession: ARSession {
        return captureSession.arSession
    }

    // MARK: Private — RoomPlan

    /// IMPORTANT: created with NO arguments. Default init() means RoomPlan
    /// creates and fully controls its own internal ARSession. This is what
    /// makes the scan work — RoomPlan needs to own the ARSession, not adopt
    /// an externally-configured one.
    private let captureSession = RoomCaptureSession()

    private let roomBuilder = RoomBuilder(options: [.beautifyObjects])

    private let captureConfig: RoomCaptureSession.Configuration = {
        var cfg = RoomCaptureSession.Configuration()
        cfg.isCoachingEnabled = false
        return cfg
    }()

    private var surfaceExclusionOverrides: [UUID: Bool] = [:]
    private var objectExclusionOverrides: [UUID: Bool] = [:]

    // MARK: Lifecycle

    override init() {
        super.init()
        captureSession.delegate = self
        slog("ROOMPLAN", "RoomScanController init — supported=\(Self.isDeviceSupported)")
    }

    deinit {
        if isScanning {
            captureSession.stop(pauseARSession: true)
        }
        slog("ROOMPLAN", "RoomScanController deinit")
    }

    // MARK: Public API

    /// Start the scan. The caller MUST have already pointed its ARSCNView's
    /// session to `controller.arSession` BEFORE calling this — otherwise the
    /// camera feed will go black during scan.
    func startScan() {
        guard !isScanning else {
            slog("ROOMPLAN", "startScan called but already scanning — ignoring")
            return
        }
        guard Self.isDeviceSupported else {
            let err = NSError(
                domain: "RoomScanController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "This device doesn't support room scanning. OBOIA requires an iPhone Pro with LiDAR."]
            )
            delegate?.roomScan(self, didFailWith: err)
            return
        }

        slog("ROOMPLAN", "startScan — RoomPlan owns its own ARSession")
        surfaceExclusionOverrides.removeAll()
        objectExclusionOverrides.removeAll()
        latestSnapshot = nil
        isScanning = true

        captureSession.run(configuration: captureConfig)
        delegate?.roomScanDidStart(self)
    }

    /// Stop the scan. Pass pauseARSession: false so the underlying ARSession
    /// keeps running — the caller's ARSCNView can keep rendering camera feed
    /// even after RoomPlan stops detecting.
    func stopScan() {
        guard isScanning else { return }
        slog("ROOMPLAN", "stopScan requested")
        captureSession.stop(pauseARSession: false)
    }

    func toggleSurfaceExclusion(id: UUID) {
        let current = surfaceExclusionOverrides[id]
            ?? defaultExclusionForSurface(id: id)
        surfaceExclusionOverrides[id] = !current
        slog("ROOMPLAN", "toggleSurfaceExclusion id=\(id) -> \(!current)")
        emitSnapshotIfAvailable(isFinal: latestSnapshot?.isFinal ?? false)
    }

    func toggleObjectExclusion(id: UUID) {
        let current = objectExclusionOverrides[id] ?? true
        objectExclusionOverrides[id] = !current
        slog("ROOMPLAN", "toggleObjectExclusion id=\(id) -> \(!current)")
        emitSnapshotIfAvailable(isFinal: latestSnapshot?.isFinal ?? false)
    }

    // MARK: Snapshot building

    private func defaultExclusionForSurface(id: UUID) -> Bool {
        guard let snap = latestSnapshot,
              let surf = snap.surfaces.first(where: { $0.id == id }) else {
            return false
        }
        return surf.kind != .wall
    }

    private func buildSnapshot(from room: CapturedRoom,
                               isFinal: Bool) -> ScanSnapshot {
        var surfaces: [DetectedSurface] = []
        var objects: [DetectedObject] = []

        for s in room.walls {
            surfaces.append(makeSurface(from: s, kind: .wall))
        }
        for s in room.doors {
            surfaces.append(makeSurface(from: s, kind: .door))
        }
        for s in room.windows {
            surfaces.append(makeSurface(from: s, kind: .window))
        }
        for s in room.openings {
            surfaces.append(makeSurface(from: s, kind: .opening))
        }
        for o in room.objects {
            objects.append(makeObject(from: o))
        }

        return ScanSnapshot(surfaces: surfaces, objects: objects, isFinal: isFinal)
    }

    private func makeSurface(from s: CapturedRoom.Surface,
                             kind: DetectedSurface.Kind) -> DetectedSurface {
        let id = s.identifier
        let exclusion = surfaceExclusionOverrides[id] ?? (kind != .wall)
        return DetectedSurface(
            id: id,
            kind: kind,
            width: s.dimensions.x,
            height: s.dimensions.y,
            transform: s.transform,
            confidence: confidenceValue(from: s.confidence),
            isExcluded: exclusion
        )
    }

    private func makeObject(from o: CapturedRoom.Object) -> DetectedObject {
        let id = o.identifier
        let exclusion = objectExclusionOverrides[id] ?? true
        return DetectedObject(
            id: id,
            category: String(describing: o.category),
            dimensions: o.dimensions,
            transform: o.transform,
            confidence: confidenceValue(from: o.confidence),
            isExcluded: exclusion
        )
    }

    private func confidenceValue(from c: CapturedRoom.Confidence) -> Float {
        switch c {
        case .high: return 1.0
        case .medium: return 0.66
        case .low: return 0.33
        @unknown default: return 0.5
        }
    }

    private func emitSnapshotIfAvailable(isFinal: Bool) {
        guard let snap = latestSnapshot else { return }
        let refreshed = ScanSnapshot(
            surfaces: snap.surfaces.map { surf in
                var s = surf
                if let override = surfaceExclusionOverrides[surf.id] {
                    s.isExcluded = override
                }
                return s
            },
            objects: snap.objects.map { obj in
                var o = obj
                if let override = objectExclusionOverrides[obj.id] {
                    o.isExcluded = override
                }
                return o
            },
            isFinal: isFinal
        )
        latestSnapshot = refreshed
        delegate?.roomScan(self, didUpdate: refreshed)
    }
}

// MARK: - RoomCaptureSessionDelegate

@available(iOS 17.0, *)
extension RoomScanController: RoomCaptureSessionDelegate {

    func captureSession(_ session: RoomCaptureSession,
                        didUpdate room: CapturedRoom) {
        let snap = buildSnapshot(from: room, isFinal: false)
        latestSnapshot = snap
        delegate?.roomScan(self, didUpdate: snap)
    }

    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData,
                        error: Error?) {
        if let err = error {
            slog("ROOMPLAN", "captureSession didEnd with error: \(err.localizedDescription)")
            isScanning = false
            delegate?.roomScan(self, didFailWith: err)
            return
        }

        slog("ROOMPLAN", "captureSession didEnd — running RoomBuilder for final result")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let finalRoom = try await self.roomBuilder.capturedRoom(from: data)
                let snap = self.buildSnapshot(from: finalRoom, isFinal: true)
                await MainActor.run {
                    self.latestSnapshot = snap
                    self.isScanning = false
                    slog("ROOMPLAN", "Final scan — surfaces=\(snap.surfaces.count) objects=\(snap.objects.count)")
                    self.delegate?.roomScan(self, didFinishWith: snap)
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    slog("ROOMPLAN", "RoomBuilder failed: \(error.localizedDescription)")
                    self.delegate?.roomScan(self, didFailWith: error)
                }
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession,
                        didProvide instruction: RoomCaptureSession.Instruction) {
        slog("ROOMPLAN", "instruction: \(instruction)")
        delegate?.roomScan(self, instructionChangedTo: instruction)
    }
}
