// MeasurementEngine.swift
// OBOIA — Wall measurement and roll estimation

import Foundation

struct WallMeasurements {
    let width: Float
    let height: Float
    var areaSqm: Float { width * height }

    func rollsNeeded(rollWidth: Float, rollLength: Float) -> Int {
        let rollArea = rollWidth * rollLength
        guard rollArea > 0 else { return 0 }
        return max(1, Int(ceil(areaSqm / rollArea)))
    }

    func totalPrice(pricePerRoll: Double, rollWidth: Float, rollLength: Float) -> Double {
        Double(rollsNeeded(rollWidth: rollWidth, rollLength: rollLength)) * pricePerRoll
    }
}

struct RoomMeasurements {
    var walls: [WallMeasurements] = []
    var totalArea: Float { walls.reduce(0) { $0 + $1.areaSqm } }
}

final class MeasurementEngine {

    /// Build wall measurements from a scan snapshot.
    func fromScanSnapshot(_ snapshot: ScanSnapshot,
                          excluding excluded: [String]) -> [WallMeasurements] {
        var walls: [WallMeasurements] = []
        for surface in snapshot.surfaces {
            guard surface.type == "wall" && !excluded.contains(surface.id) else { continue }
            walls.append(WallMeasurements(width: surface.width, height: surface.height))
        }
        return walls
    }

    /// Calculate rolls for a single wall.
    func rolls(for wall: WallMeasurements, rollWidth: Float, rollLength: Float) -> Int {
        wall.rollsNeeded(rollWidth: rollWidth, rollLength: rollLength)
    }

    /// Total rolls for all non-excluded walls.
    func totalRolls(walls: [WallMeasurements], rollWidth: Float, rollLength: Float) -> Int {
        var area: Float = 0
        for w in walls {
            area += w.areaSqm
        }
        let rollArea = rollWidth * rollLength
        guard rollArea > 0 else { return 0 }
        return max(1, Int(ceil(area / rollArea)))
    }
}
