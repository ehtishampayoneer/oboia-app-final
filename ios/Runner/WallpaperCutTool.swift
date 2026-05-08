import Foundation
import UIKit
import SceneKit
import ARKit
import Vision
import CoreImage

// MARK: - Shape & Region Types

enum CutShape {
    case rectangle(uvRect: CGRect)
    case circle(uvCenter: CGPoint, uvRadius: CGFloat)
    case freehand(uvPoints: [CGPoint])
}

struct CutRegion {
    let id: UUID
    let shape: CutShape

    init(shape: CutShape) {
        self.id = UUID()
        self.shape = shape
    }
}

struct WallCutMask {
    var cuts: [CutRegion] = []
    var cachedMaskImage: UIImage? = nil
    var isDirty: Bool = false

    mutating func addCut(_ cut: CutRegion) {
        cuts.append(cut)
        isDirty = true
        cachedMaskImage = nil
    }

    mutating func undoLast() -> Bool {
        guard !cuts.isEmpty else { return false }
        cuts.removeLast()
        isDirty = true
        cachedMaskImage = nil
        return true
    }

    mutating func clearAll() {
        cuts.removeAll()
        isDirty = true
        cachedMaskImage = nil
    }
}

// MARK: - WallpaperCutTool

class WallpaperCutTool {

    // MARK: - Visual constants
    private let maskWidth  = 2048
    private let maskHeight = 2048
    private let featherBlur: CGFloat     = 10.0
    private let coreInsetRatio: CGFloat  = 0.15
    private let shadowRingWidth: CGFloat = 6.0
    private let shadowOffset = CGSize(width: 1.5, height: 2.0)
    private let shadowGray: CGFloat      = 0.12
    private let shadowAlpha: CGFloat     = 0.72

    // MARK: - State
    private var wallMasks: [UUID: WallCutMask] = [:]
    private let maskQueue  = DispatchQueue(label: "com.oboia.cutTool.mask",  qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "com.oboia.cutTool.vision", qos: .userInitiated)

    private lazy var ciCtx: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Add Cuts

    func addRectangleCut(uvRect: CGRect, toWall wallId: UUID) {
        let safe = clampedUVRect(uvRect)
        wallMasks[wallId, default: WallCutMask()].addCut(CutRegion(shape: .rectangle(uvRect: safe)))
    }

    func addCircleCut(uvCenter: CGPoint, uvRadius: CGFloat, toWall wallId: UUID) {
        let r = max(0.005, uvRadius)
        wallMasks[wallId, default: WallCutMask()].addCut(CutRegion(shape: .circle(uvCenter: uvCenter, uvRadius: r)))
    }

    func addFreehandCut(uvPoints: [CGPoint], toWall wallId: UUID) {
        guard uvPoints.count >= 3 else { return }
        wallMasks[wallId, default: WallCutMask()].addCut(CutRegion(shape: .freehand(uvPoints: uvPoints)))
    }

    func undoLastCut(fromWall wallId: UUID) -> Bool {
        return wallMasks[wallId]?.undoLast() ?? false
    }

    func clearAllCuts(fromWall wallId: UUID) {
        wallMasks[wallId]?.clearAll()
    }

    func cutCount(forWall wallId: UUID) -> Int {
        return wallMasks[wallId]?.cuts.count ?? 0
    }

    // MARK: - Smart Cut via Vision

    func smartCut(
        screenPoint: CGPoint,
        sceneView: ARSCNView,
        wallData: WallData,
        wallId: UUID,
        completion: @escaping (Bool) -> Void
    ) {
        guard let frame = sceneView.session.currentFrame else {
            completion(false); return
        }

        guard let tapUV = screenPointToWallUV(
            screenPoint: screenPoint, sceneView: sceneView, wallData: wallData
        ) else { completion(false); return }

        let pixelBuffer = frame.capturedImage
        let viewportSize = sceneView.bounds.size

        visionQueue.async { [weak self] in
            guard let self = self else { return }

            let detectedRect = self.detectObjectRect(
                pixelBuffer: pixelBuffer,
                nearScreenPoint: screenPoint,
                viewportSize: viewportSize,
                frame: frame,
                wallData: wallData,
                sceneView: sceneView
            )

            DispatchQueue.main.async {
                if let uvRect = detectedRect {
                    let padded = self.addPhysicalPadding(uvRect: uvRect, wallData: wallData, meters: 0.005)
                    self.addRectangleCut(uvRect: padded, toWall: wallId)
                    completion(true)
                } else {
                    // CHANGED: use wallData.width/height (works for both auto & manual walls)
                    let w = wallData.width
                    let h = wallData.height
                    let uSize = CGFloat(w > 0 ? 0.08 / w : 0.05)
                    let vSize = CGFloat(h > 0 ? 0.08 / h : 0.05)
                    let fallback = CGRect(
                        x: tapUV.x - uSize / 2,
                        y: tapUV.y - vSize / 2,
                        width: uSize, height: vSize
                    )
                    self.addRectangleCut(uvRect: fallback, toWall: wallId)
                    completion(true)
                }
            }
        }
    }

    // MARK: - Apply Mask

    func applyMask(toMaterial material: SCNMaterial, wallId: UUID, completion: @escaping () -> Void) {
        guard let maskData = wallMasks[wallId], !maskData.cuts.isEmpty else {
            clearMask(on: material)
            completion()
            return
        }

        if let cached = maskData.cachedMaskImage, !maskData.isDirty {
            applyMaskImage(cached, to: material)
            completion()
            return
        }

        let cuts = maskData.cuts
        let w = maskWidth; let h = maskHeight

        maskQueue.async { [weak self] in
            guard let self = self else { return }
            let img = self.renderMask(cuts: cuts, width: w, height: h)
            self.wallMasks[wallId]?.cachedMaskImage = img
            self.wallMasks[wallId]?.isDirty = false
            DispatchQueue.main.async {
                self.applyMaskImage(img, to: material)
                completion()
            }
        }
    }

    func reapplyMask(toMaterial material: SCNMaterial, wallId: UUID) {
        guard let maskData = wallMasks[wallId], !maskData.cuts.isEmpty else {
            clearMask(on: material); return
        }
        if let cached = maskData.cachedMaskImage {
            applyMaskImage(cached, to: material)
        } else {
            applyMask(toMaterial: material, wallId: wallId) {}
        }
    }

    // MARK: - Vision Detection (private)

    private func detectObjectRect(
        pixelBuffer: CVPixelBuffer,
        nearScreenPoint screenPoint: CGPoint,
        viewportSize: CGSize,
        frame: ARFrame,
        wallData: WallData,
        sceneView: ARSCNView
    ) -> CGRect? {

        let imageW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let imageSize = CGSize(width: imageW, height: imageH)

        let displayTx = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        guard let invTx = displayTx.safeInverted() else { return nil }

        let normScreen = CGPoint(x: screenPoint.x / viewportSize.width,
                                  y: screenPoint.y / viewportSize.height)
        let normImage   = normScreen.applying(invTx)
        let imageTap    = CGPoint(x: normImage.x * imageW, y: normImage.y * imageH)

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio  = 0.15
        request.maximumAspectRatio  = 6.0
        request.minimumSize         = 0.006
        request.maximumObservations = 20
        request.minimumConfidence   = 0.35

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { return nil }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        let threshold = min(imageW, imageH) * 0.20
        var best: VNRectangleObservation? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for obs in observations {
            let cx = obs.boundingBox.midX * imageW
            let cy = (1.0 - obs.boundingBox.midY) * imageH
            let dist = hypot(cx - imageTap.x, cy - imageTap.y)
            if dist < threshold && dist < bestDist {
                bestDist = dist; best = obs
            }
        }

        guard let obs = best else { return nil }

        let imgRect = CGRect(
            x: obs.boundingBox.minX * imageW,
            y: (1.0 - obs.boundingBox.maxY) * imageH,
            width: obs.boundingBox.width  * imageW,
            height: obs.boundingBox.height * imageH
        )

        return imageRectToWallUV(
            imageRect: imgRect, imageSize: imageSize,
            viewportSize: viewportSize, frame: frame,
            wallData: wallData, sceneView: sceneView
        )
    }

    private func imageRectToWallUV(
        imageRect: CGRect, imageSize: CGSize,
        viewportSize: CGSize, frame: ARFrame,
        wallData: WallData, sceneView: ARSCNView
    ) -> CGRect? {
        let displayTx = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        let corners = [
            CGPoint(x: imageRect.minX, y: imageRect.minY),
            CGPoint(x: imageRect.maxX, y: imageRect.maxY)
        ]
        var uvPts: [CGPoint] = []
        for c in corners {
            let ni = CGPoint(x: c.x / imageSize.width, y: c.y / imageSize.height)
            let ns = ni.applying(displayTx)
            let sp = CGPoint(x: ns.x * viewportSize.width, y: ns.y * viewportSize.height)
            if let uv = screenPointToWallUV(screenPoint: sp, sceneView: sceneView, wallData: wallData) {
                uvPts.append(uv)
            }
        }
        guard uvPts.count == 2 else { return nil }
        return CGRect(
            x: min(uvPts[0].x, uvPts[1].x),
            y: min(uvPts[0].y, uvPts[1].y),
            width:  abs(uvPts[1].x - uvPts[0].x),
            height: abs(uvPts[1].y - uvPts[0].y)
        )
    }

    // MARK: - UV Conversion (public so ARWallpaperView can also use it)

    func screenPointToWallUV(
        screenPoint: CGPoint,
        sceneView: ARSCNView,
        wallData: WallData
    ) -> CGPoint? {
        // CHANGED: For manual walls, raycast against estimated planes too
        // (manual walls don't have ARKit-tracked planes)
        let allowing: ARRaycastQuery.Target = wallData.isManual
            ? .estimatedPlane
            : .existingPlaneGeometry

        guard let q = sceneView.raycastQuery(
            from: screenPoint,
            allowing: allowing,
            alignment: .vertical
        ) else { return nil }

        let results = sceneView.session.raycast(q)
        guard let r = results.first else { return nil }

        let worldPos = SIMD3<Float>(
            r.worldTransform.columns.3.x,
            r.worldTransform.columns.3.y,
            r.worldTransform.columns.3.z
        )
        return worldPositionToWallUV(worldPos: worldPos, wallData: wallData)
    }

    func worldPositionToWallUV(worldPos: SIMD3<Float>, wallData: WallData) -> CGPoint? {
        // CHANGED: Branch by wall type — auto walls use anchor.transform,
        // manual walls compute a transform from manualCenter + manualNormal.

        if wallData.isManual {
            return manualWallUV(worldPos: worldPos, wallData: wallData)
        } else {
            return autoWallUV(worldPos: worldPos, wallData: wallData)
        }
    }

    /// Auto-detected wall: use the ARKit plane anchor's transform.
    private func autoWallUV(worldPos: SIMD3<Float>, wallData: WallData) -> CGPoint? {
        guard let anchor = wallData.anchor else { return nil }

        let invTx  = simd_inverse(anchor.transform)
        let local  = invTx * SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1.0)

        // CHANGED: gracefully fall back to extent on iOS < 16
        let pw: Float
        let ph: Float
        if #available(iOS 16.0, *) {
            pw = anchor.planeExtent.width
            ph = anchor.planeExtent.height
        } else {
            pw = anchor.extent.x
            ph = anchor.extent.z
        }
        guard pw > 0.01, ph > 0.01 else { return nil }

        // Vertical plane: x = horizontal, y = vertical along wall
        let u = CGFloat(local.x / pw + 0.5)
        let v = CGFloat(1.0 - (local.y / ph + 0.5))
        return CGPoint(x: max(0, min(1, u)), y: max(0, min(1, v)))
    }

    /// Manual wall: project onto the user-defined plane defined by center + normal.
    private func manualWallUV(worldPos: SIMD3<Float>, wallData: WallData) -> CGPoint? {
        guard let center = wallData.manualCenter,
              let normal = wallData.manualNormal else { return nil }

        let pw = wallData.width
        let ph = wallData.height
        guard pw > 0.01, ph > 0.01 else { return nil }

        // Build orthonormal basis for the wall:
        //   - up axis = world up projected onto the wall (gravity-aligned)
        //   - right axis = normal × up
        let worldUp = SIMD3<Float>(0, 1, 0)
        // Project worldUp onto the wall plane
        let upOnWall = simd_normalize(worldUp - simd_dot(worldUp, normal) * normal)
        let right = simd_normalize(simd_cross(upOnWall, normal))

        // Vector from wall center to the world point
        let delta = worldPos - center

        // Project delta onto the wall's local right and up axes
        let localX = simd_dot(delta, right)   // horizontal offset in meters
        let localY = simd_dot(delta, upOnWall) // vertical offset in meters

        // Convert to UV (0..1)
        let u = CGFloat(localX / pw + 0.5)
        let v = CGFloat(1.0 - (localY / ph + 0.5))
        return CGPoint(x: max(0, min(1, u)), y: max(0, min(1, v)))
    }

    private func addPhysicalPadding(uvRect: CGRect, wallData: WallData, meters: Float) -> CGRect {
        // CHANGED: use wallData.width/height (works for both auto and manual)
        let pw = wallData.width
        let ph = wallData.height
        guard pw > 0, ph > 0 else { return uvRect }
        return uvRect.insetBy(dx: -CGFloat(meters / pw), dy: -CGFloat(meters / ph))
    }

    // MARK: - Mask Rendering

    private func renderMask(cuts: [CutRegion], width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)

        // ── PASS 1: White background + feathered black cuts ──────────────
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx1 = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext(); return UIImage()
        }

        ctx1.setFillColor(UIColor.white.cgColor)
        ctx1.fill(CGRect(origin: .zero, size: size))

        for cut in cuts {
            let path     = buildPath(cut.shape, size: size, inset: 0)
            let corePath = buildPath(cut.shape, size: size, inset: featherBlur * coreInsetRatio)

            // Shadow spreads outward into white area → feathered edge
            ctx1.saveGState()
            ctx1.setShadow(offset: .zero, blur: featherBlur, color: UIColor.black.cgColor)
            ctx1.setFillColor(UIColor.black.cgColor)
            ctx1.addPath(path)
            ctx1.fillPath()
            ctx1.restoreGState()

            // Re-stamp core solid black so center remains fully transparent
            ctx1.setFillColor(UIColor.black.cgColor)
            ctx1.addPath(corePath)
            ctx1.fillPath()
        }

        let pass1 = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let p1 = pass1, let p1CGI = p1.cgImage else { return UIImage() }

        // ── PASS 2: CIGaussianBlur for sub-pixel smoothing ───────────────
        let ciIn   = CIImage(cgImage: p1CGI)
        let blur   = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(ciIn,  forKey: kCIInputImageKey)
        blur.setValue(1.2,   forKey: kCIInputRadiusKey)

        var smoothed: UIImage = p1
        if let blurOut = blur.outputImage,
           let blurCGI = ciCtx.createCGImage(blurOut, from: CGRect(origin: .zero, size: size)) {
            smoothed = UIImage(cgImage: blurCGI)
        }

        // ── PASS 3: Paper-lifting inner shadow at cut edges ───────────────
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx3 = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext(); return smoothed
        }

        smoothed.draw(in: CGRect(origin: .zero, size: size))

        for cut in cuts {
            drawPaperLiftShadow(cut.shape, size: size, ctx: ctx3)
        }

        let final = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return final ?? smoothed
    }

    private func buildPath(_ shape: CutShape, size: CGSize, inset: CGFloat) -> CGPath {
        switch shape {

        case .rectangle(let uvRect):
            var r = CGRect(
                x: uvRect.minX  * size.width,
                y: uvRect.minY  * size.height,
                width:  uvRect.width  * size.width,
                height: uvRect.height * size.height
            )
            if inset != 0 { r = r.insetBy(dx: inset, dy: inset) }
            let cr = max(2, 6.0 - inset * 0.4)
            return UIBezierPath(roundedRect: r, cornerRadius: cr).cgPath

        case .circle(let uvCenter, let uvRadius):
            let cx  = uvCenter.x * size.width
            let cy  = uvCenter.y * size.height
            let avg = (size.width + size.height) / 2.0
            let r   = max(2, uvRadius * avg - inset)
            return UIBezierPath(arcCenter: CGPoint(x: cx, y: cy),
                                radius: r, startAngle: 0,
                                endAngle: .pi * 2, clockwise: true).cgPath

        case .freehand(let pts):
            guard pts.count >= 2 else { return CGPath(rect: .zero, transform: nil) }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: pts[0].x * size.width, y: pts[0].y * size.height))
            for i in 1..<pts.count {
                let curr = CGPoint(x: pts[i].x * size.width, y: pts[i].y * size.height)
                if i == 1 {
                    path.addLine(to: curr)
                } else {
                    let prev = CGPoint(x: pts[i-1].x * size.width, y: pts[i-1].y * size.height)
                    let cp   = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                    path.addQuadCurve(to: curr, controlPoint: cp)
                }
            }
            path.close()
            if inset > 0 {
                let bb = path.bounds.insetBy(dx: inset, dy: inset)
                return UIBezierPath(roundedRect: bb, cornerRadius: 8).cgPath
            }
            return path.cgPath
        }
    }

    private func drawPaperLiftShadow(_ shape: CutShape, size: CGSize, ctx: CGContext) {
        let holePath  = buildPath(shape, size: size, inset: 0)
        let outerPath = buildPath(shape, size: size, inset: -shadowRingWidth)

        ctx.saveGState()

        ctx.addPath(outerPath)
        ctx.addPath(holePath)
        ctx.clip(using: .evenOdd)

        ctx.translateBy(x: shadowOffset.width, y: shadowOffset.height)
        ctx.setFillColor(UIColor(white: shadowGray, alpha: shadowAlpha).cgColor)
        ctx.addPath(holePath)
        ctx.fillPath()

        ctx.restoreGState()
    }

    // MARK: - Apply / Clear Material Mask

    private func applyMaskImage(_ image: UIImage, to material: SCNMaterial) {
        material.transparent.contents    = image
        material.transparent.wrapS       = .clampToBorder
        material.transparent.wrapT       = .clampToBorder
        material.transparencyMode        = .rgbZero
        material.writesToDepthBuffer     = true
        material.readsFromDepthBuffer    = true
    }

    private func clearMask(on material: SCNMaterial) {
        material.transparent.contents = UIColor.white
        material.transparencyMode     = .default
    }

    // MARK: - Helpers

    private func clampedUVRect(_ r: CGRect) -> CGRect {
        let x = max(0, min(0.98, r.minX))
        let y = max(0, min(0.98, r.minY))
        let w = min(r.width,  1.0 - x)
        let h = min(r.height, 1.0 - y)
        return CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
    }
}

// MARK: - CGAffineTransform safe invert

private extension CGAffineTransform {
    func safeInverted() -> CGAffineTransform? {
        let det = a * d - b * c
        guard abs(det) > 1e-8 else { return nil }
        return inverted()
    }
}
