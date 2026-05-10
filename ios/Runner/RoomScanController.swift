//
//  RoomScanController.swift
//  OBOIA
//
//  Wraps Apple's RoomCaptureSession (RoomPlan) to detect real walls, doors,
//  windows, openings, and furniture using LiDAR. Emits structured updates
//  that the rest of the AR stack consumes.
//
//  Requires: iOS 17.0+ (custom ARSession support)
//  Requires: LiDAR-capable device (iPhone 12 Pro and later)
//

import Foundation
import ARKit
import RoomPlan
import simd

// MARK: - Public data model

/// A single architectural surface (wall, door, window, opening) found by RoomPlan.
struct DetectedSurface {
    enum Kind: String {
        case wall
        case door
        case window
        case opening
    }

    let id: UUID                 // RoomPlan's stable Surface.identifier
    let kind: Kind
    let width: Float             // metres
    let height: Float            // metres
    let transform: simd_float4x4 // world-space transform of surface center
    let confidence: Float        // 0..1

    /// User-controlled exclusion flag. Walls default to false (included),
    /// doors/windows/openings default to true (excluded from wallpaper).
    var isExcluded: Bool

    var sqm: Float { width * height }
}

/// A free-standing object found by RoomPlan (sofa, TV, painting, etc).
struct DetectedObject {
    let id: UUID
    let category: String         // e.g. "sofa", "television", "table"
    let dimensions: SIMD3<Float> // width, height, depth in metres
    let transform: simd_float4x4
    let confidence: Float

    var isExcluded: Bool         // default true — never wallpaper objects
}

/// What gets emitted on each scan progress tick.
struct ScanSnapshot {
    let surfaces: [DetectedSurface]
    let objects: [DetectedObject]
    let isFinal: Bool            // true only on completion
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

    /// True while a scan is active.
    private(set) var isScanning: Bool = false

    /// Most recent merged scan result. Kept around so wallpaper preview
    /// can read final wall geometry after the user stops scanning.
    private(set) var latestSnapshot: ScanSnapshot?

    /// Hardware capability check. Call before attempting startScan.
    static var isDeviceSupported: Bool {
        return RoomCaptureSession.isSupported
    }

    // MARK: Private — RoomPlan

    private let captureSession = RoomCaptureSession()
    private let captureConfig: RoomCaptureSession.Configuration = {
        var cfg = RoomCaptureSession.Configuration()
        cfg.isCoachingEnabled = false   // we render our own coaching UI in Flutter
        return cfg
    }()

    /// User exclusion overrides keyed by surface UUID. Survives across
    /// scan progress updates so the user's tap-to-toggle decisions persist.
    private var surfaceExclusionOverrides: [UUID: Bool] = [:]
    private var objectExclusionOverrides: [UUID: Bool] = [:]

    /// Strong reference to the ARSession we share with ARWallpaperView.
    /// RoomPlan needs an ARSession; ARWallpaperView's ARSCNView already has
    /// one. We pass that exact session in via startScan(arSession:).
    private weak var sharedARSession: ARSession?

    // MARK: Lifecycle

    override init() {
        super.init()
        captureSession.delegate = self
        slog("ROOMPLAN", "RoomScanController init — supported=\(Self.isDeviceSupported)")
    }

    deinit {
        if isScanning {
            captureSession.stop()
        }
        slog("ROOMPLAN", "RoomScanController deinit")
    }

    // MARK: Public API

    /// Start the scan. Pass the same ARSession used by ARWallpaperView so
    /// wallpaper rendering and room scanning share one camera feed.
    /// On iOS 17+, RoomCaptureSession can run with a custom ARSession.
    func startScan(arSession: ARSession) {
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

        slog("ROOMPLAN", "startScan — using shared ARSession")
        self.sharedARSession = arSession
        surfaceExclusionOverrides.removeAll()
        objectExclusionOverrides.removeAll()
        latestSnapshot = nil
        isScanning = true

        // Tell RoomPlan to use our existing ARSession instead of creating its own.
        captureSession.run(configuration: captureConfig, arSession: arSession)
        delegate?.roomScanDidStart(self)
    }

    /// Stop the scan. The final snapshot is delivered via
    /// `roomScan(_:didFinishWith:)`.
    func stopScan() {
        guard isScanning else { return }
        slog("ROOMPLAN", "stopScan requested")
        captureSession.stop()
        isScanning = false
    }

    /// User tapped a surface to toggle its exclusion. Call this when the
    /// Flutter side reports a tap on a wall/door/window/opening.
    func toggleSurfaceExclusion(id: UUID) {
        let current = surfaceExclusionOverrides[id]
            ?? defaultExclusionForSurface(id: id)
        surfaceExclusionOverrides[id] = !current
        slog("ROOMPLAN", "toggleSurfaceExclusion id=\(id) -> \(!current)")
        emitSnapshotIfAvailable(isFinal: latestSnapshot?.isFinal ?? false)
    }

    /// User tapped a furniture object to toggle exclusion (almost always
    /// kept excluded, but hypothetically e.g. flat painting could be toggled).
    func toggleObjectExclusion(id: UUID) {
        let current = objectExclusionOverrides[id] ?? true
        objectExclusionOverrides[id] = !current
        slog("ROOMPLAN", "toggleObjectExclusion id=\(id) -> \(!current)")
        emitSnapshotIfAvailable(isFinal: latestSnapshot?.isFinal ?? false)
    }

    // MARK: Snapshot building

    private func defaultExclusionForSurface(id: UUID) -> Bool {
        // Walls included by default; doors/windows/openings excluded by default.
        guard let snap = latestSnapshot,
              let surf = snap.surfaces.first(where: { $0.id == id }) else {
            return false
        }
        return surf.kind != .wall
    }

    private func buildSnapshot(from room: CapturedRoomData,
                               isFinal: Bool) -> ScanSnapshot {
        // Note: iOS 17 emits CapturedRoomData on each session update;
        // it carries the same Surface/Object representations.
        // We only need walls/doors/windows/openings + objects.
        var surfaces: [DetectedSurface] = []
        var objects: [DetectedObject] = []

        // Surfaces in the live data are exposed via session(:didUpdate:) below
        // through CapturedRoom (after final). For live updates, RoomPlan
        // calls didUpdate with progressive CapturedRoom too on iOS 17.
        if let captured = room.captured {
            for s in captured.walls {
                surfaces.append(makeSurface(from: s, kind: .wall))
            }
            for s in captured.doors {
                surfaces.append(makeSurface(from: s, kind: .door))
            }
            for s in captured.windows {
                surfaces.append(makeSurface(from: s, kind: .window))
            }
            for s in captured.openings {
                surfaces.append(makeSurface(from: s, kind: .opening))
            }
            for o in captured.objects {
                objects.append(makeObject(from: o))
            }
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
        // Re-run the override application to pick up any new toggles.
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
                        didUpdate room: CapturedRoomData) {
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
        let snap = buildSnapshot(from: data, isFinal: true)
        latestSnapshot = snap
        isScanning = false
        slog("ROOMPLAN", "captureSession didEnd — surfaces=\(snap.surfaces.count) objects=\(snap.objects.count)")
        delegate?.roomScan(self, didFinishWith: snap)
    }

    func captureSession(_ session: RoomCaptureSession,
                        didProvide instruction: RoomCaptureSession.Instruction) {
        slog("ROOMPLAN", "instruction: \(instruction)")
        delegate?.roomScan(self, instructionChangedTo: instruction)
    }
}

// MARK: - CapturedRoomData helper
//
// CapturedRoomData (iOS 17 type) doesn't expose CapturedRoom directly in the
// public API the same way across minor iOS versions. The line below uses an
// extension to safely extract the captured room when available.

@available(iOS 17.0, *)
extension CapturedRoomData {
    /// Convenience extractor — returns the embedded CapturedRoom if iOS makes
    /// it available. On versions where it isn't, returns nil and the snapshot
    /// will simply have empty arrays until the final didEndWith fires.
    fileprivate var captured: CapturedRoom? {
        // Attempt KVC-style access; falls back to nil if not present.
        return self.value(forKey: "capturedRoom") as? CapturedRoom
    }
}
