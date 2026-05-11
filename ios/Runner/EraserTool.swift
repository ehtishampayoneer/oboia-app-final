// EraserTool.swift
// OBOIA — Alpha‑mask brush tool for wallpaper editing
// Replaces the broken WallpaperCutTool.swift

import UIKit
import SceneKit

/// Represents a single brush stroke point.
struct BrushPoint {
    let location: CGPoint
    let size: CGFloat
    let timestamp: TimeInterval
}

/// The EraserTool paints an alpha mask texture in real time.
/// It can be used with a UIView overlay to capture pan gestures.
final class EraserTool {

    // ── Configuration ──────────────────────────────────────────
    var brushSize: CGFloat = 30.0          // default diameter in points
    var brushColor: UIColor = .white       // white = keep wallpaper, black = erase
    var brushOpacity: CGFloat = 1.0        // 0.0 = transparent, 1.0 = fully opaque

    // ── State ──────────────────────────────────────────────────
    private(set) var maskImage: UIImage?   // the current alpha mask
    private var maskWidth: Int = 0
    private var maskHeight: Int = 0
    private var drawContext: CGContext?
    private var points: [BrushPoint] = []

    // ── Touch handlers ─────────────────────────────────────────
    func startStroke(at point: CGPoint) {
        points.removeAll()
        points.append(BrushPoint(location: point, size: brushSize, timestamp: CACurrentMediaTime()))
    }

    func continueStroke(at point: CGPoint) {
        points.append(BrushPoint(location: point, size: brushSize, timestamp: CACurrentMediaTime()))
    }

    func endStroke() {
        // stroke completed; the rendered image is already updated
    }

    // ── Mask management ────────────────────────────────────────
    /// Initialises a new blank mask of the given dimensions (in pixels).
    func createMask(width: Int, height: Int) {
        maskWidth = width
        maskHeight = height

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        maskImage = renderer.image { ctx in
            let cgContext = ctx.cgContext
            cgContext.setFillColor(UIColor.white.cgColor) // white = visible wallpaper
            cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // Create a persistent CGContext for incremental drawing
        UIGraphicsBeginImageContext(CGSize(width: width, height: height))
        maskImage?.draw(at: .zero)
        drawContext = UIGraphicsGetCurrentContext()
    }

    /// Renders accumulated brush strokes onto the mask and returns the updated UIImage.
    func renderMask() -> UIImage? {
        guard let context = drawContext, maskWidth > 0, maskHeight > 0 else { return nil }

        // Draw each brush point as a soft circle
        for pt in points {
            let rect = CGRect(x: pt.location.x - pt.size/2,
                              y: pt.location.y - pt.size/2,
                              width: pt.size,
                              height: pt.size)
            // Soft circle with alpha for smooth edges
            context.saveGState()
            context.setBlendMode(brushColor == .white ? .normal : .clear)
            context.setFillColor(brushColor.withAlphaComponent(brushOpacity).cgColor)

            // Draw a radial gradient to simulate a soft brush
            let colors = [brushColor.withAlphaComponent(brushOpacity).cgColor,
                          brushColor.withAlphaComponent(0.0).cgColor] as CFArray
            let locations: [CGFloat] = [0.0, 1.0]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: locations) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                context.drawRadialGradient(gradient,
                                           startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: pt.size/2,
                                           options: [])
            }
            context.restoreGState()
        }

        // Clear points after rendering
        points.removeAll()

        // Create image from context
        if let cgImage = context.makeImage() {
            maskImage = UIImage(cgImage: cgImage)
        }
        return maskImage
    }

    /// Apply the latest mask to a SceneKit material's transparency.
    func applyMask(to material: SCNMaterial) {
        guard let mask = maskImage else { return }
        material.transparent.contents = mask
        material.transparencyMode = .aOne
    }

    /// Undo last stroke (clear all points since last startStroke)
    func undoStroke() {
        points.removeAll()
    }

    func resetMask() {
        createMask(width: maskWidth > 0 ? maskWidth : 1024,
                   height: maskHeight > 0 ? maskHeight : 1024)
    }
}
