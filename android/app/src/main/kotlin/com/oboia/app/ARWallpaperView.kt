package com.oboia.app

import android.content.Context
import android.net.Uri
import android.util.Log
import android.view.MotionEvent
import android.view.View
import com.google.ar.core.Anchor
import com.google.ar.core.Config
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.TrackingState
import dev.romainguy.kotlin.math.Float3
import dev.romainguy.kotlin.math.Quaternion
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.arcore.isValid
import io.github.sceneview.ar.node.AnchorNode
import io.github.sceneview.material.setBaseColorMap
import io.github.sceneview.material.setNormalMap
import io.github.sceneview.material.setRoughnessMap
import io.github.sceneview.math.Position
import io.github.sceneview.math.Rotation
import io.github.sceneview.math.Scale
import io.github.sceneview.node.CubeNode
import io.github.sceneview.node.Node
import io.github.sceneview.node.PlaneNode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Native AR wallpaper renderer for Android.
 *
 * Built on SceneView (https://github.com/SceneView/sceneview-android), which wraps
 * Filament (Google's physically-based renderer) together with ARCore. This gives us:
 *   - Full PBR lighting pipeline (metallic-roughness workflow)
 *   - ENVIRONMENTAL_HDR light estimation feeding Filament's IBL
 *   - Real-time shadow + reflection from the captured room
 *   - OpenGL ES 3.1 / Vulkan backend
 *
 * Channel contract is identical to iOS (see ARWallpaperView.swift).
 */
class ARWallpaperView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    creationParams: Map<String?, Any?>?
) : PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "ARWallpaperView"
        private const val METHOD_CHANNEL = "com.oboia/ar"
        private const val EVENT_CHANNEL = "com.oboia/ar_events"
        private const val MIN_PLANE_METERS = 0.3f
    }

    // --- Flutter plumbing
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    // --- SceneView
    private val sceneView: ARSceneView = ARSceneView(context)

    // --- State
    private data class WallState(
        val index: Int,
        var plane: Plane,
        var anchorNode: AnchorNode? = null,
        var wallpaperNode: PlaneNode? = null,
        var markerNodes: MutableList<Node> = mutableListOf(),
        var currentWallpaper: WallpaperInfo? = null,
        var isSelected: Boolean = false
    )

    private data class WallpaperInfo(
        val albedoUrl: String,
        val normalUrl: String,
        val roughnessUrl: String,
        val aoUrl: String,
        val rollWidth: Float,
        val rollLength: Float,
        val pricePerRoll: Double
    )

    private val walls = ConcurrentHashMap<Plane, WallState>()
    private val indexToPlane = ConcurrentHashMap<Int, Plane>()
    private var nextIndex = 0
    private var selectedPlane: Plane? = null

    // --- Coroutines
    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.Main + job)

    // --- Texture cache bridge (uses Flutter-side cached files when available, otherwise Dio-downloaded)
    private val textureCache = AndroidTextureCache(context)

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        setupSceneView()
    }

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    private fun setupSceneView() {
        sceneView.apply {
            // Configure ARCore session for vertical planes + HDR light estimation
            configureSession { _, config ->
                config.planeFindingMode = Config.PlaneFindingMode.VERTICAL
                config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                config.depthMode = if (session?.isDepthModeSupported(Config.DepthMode.AUTOMATIC) == true) {
                    Config.DepthMode.AUTOMATIC
                } else {
                    Config.DepthMode.DISABLED
                }
                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                config.focusMode = Config.FocusMode.AUTO
            }

            // Show plane renderer only while scanning
            planeRenderer.isEnabled = true
            planeRenderer.isVisible = true

            // Frame callback — detect and track planes
            onSessionUpdated = { _, frame ->
                updateWalls(frame.updatedTrackables(Plane::class.java))
            }

            // Tap handling
            onTouchEvent = { e, hitResult ->
                if (e.action == MotionEvent.ACTION_UP) {
                    handleTap(e, hitResult)
                    true
                } else false
            }
        }
    }

    override fun getView(): View = sceneView

    override fun dispose() {
        disposeAR()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        job.cancel()
    }

    // ---------------------------------------------------------------------
    // Method channel
    // ---------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initAR" -> result.success(true)

                "placeWallpaper" -> {
                    val info = parseInfo(call) ?: run {
                        result.error("bad_args", "Missing wallpaper fields", null); return
                    }
                    val wallIndex = call.argument<Int>("wallIndex") ?: -1
                    placeWallpaper(info, wallIndex, result)
                }

                "switchWallpaper" -> {
                    val info = parseInfo(call) ?: run {
                        result.error("bad_args", "Missing wallpaper fields", null); return
                    }
                    val wallIndex = call.argument<Int>("wallIndex") ?: -1
                    switchWallpaper(info, wallIndex, result)
                }

                "selectWall" -> {
                    val idx = call.argument<Int>("wallIndex") ?: run {
                        result.error("bad_args", "wallIndex required", null); return
                    }
                    selectWall(idx)
                    result.success(true)
                }

                "clearWall" -> {
                    val idx = call.argument<Int>("wallIndex") ?: run {
                        result.error("bad_args", "wallIndex required", null); return
                    }
                    clearWall(idx)
                    result.success(true)
                }

                "getWallMeasurements" -> {
                    val idx = call.argument<Int>("wallIndex") ?: run {
                        result.success(null); return
                    }
                    val plane = indexToPlane[idx]
                    if (plane == null) { result.success(null); return }
                    val w = plane.extentX.toDouble()
                    val h = plane.extentZ.toDouble()
                    result.success(mapOf("width" to w, "height" to h, "sqm" to w * h))
                }

                "disposeAR" -> {
                    disposeAR()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Method call failed", t)
            result.error("exception", t.message, null)
        }
    }

    private fun parseInfo(call: MethodCall): WallpaperInfo? {
        val albedo = call.argument<String>("albedoUrl") ?: return null
        val normal = call.argument<String>("normalUrl") ?: return null
        val rough = call.argument<String>("roughnessUrl") ?: return null
        val ao = call.argument<String>("aoUrl") ?: return null
        val rollWidth = (call.argument<Double>("rollWidth") ?: 0.53).toFloat()
        val rollLength = (call.argument<Double>("rollLength") ?: 10.0).toFloat()
        val price = call.argument<Double>("pricePerRoll") ?: 0.0
        return WallpaperInfo(albedo, normal, rough, ao, rollWidth, rollLength, price)
    }

    // ---------------------------------------------------------------------
    // Plane tracking
    // ---------------------------------------------------------------------

    private fun updateWalls(trackedPlanes: Collection<Plane>) {
        for (plane in trackedPlanes) {
            if (plane.type != Plane.Type.VERTICAL) continue
            if (plane.trackingState != TrackingState.TRACKING) continue
            if (plane.extentX < MIN_PLANE_METERS || plane.extentZ < MIN_PLANE_METERS) continue

            // Collapse into its subsumed parent if ARCore merged it
            val root = plane.subsumedBy ?: plane
            val existing = walls[root]
            if (existing == null) {
                registerNewWall(root)
            } else {
                existing.plane = root
                onWallUpdated(existing)
            }
        }

        // Remove any walls whose plane is now subsumed or stopped
        val toRemove = walls.keys.filter {
            it.subsumedBy != null || it.trackingState == TrackingState.STOPPED
        }
        for (p in toRemove) {
            walls.remove(p)?.let { state ->
                indexToPlane.remove(state.index)
                state.anchorNode?.let { sceneView.removeChildNode(it) }
                if (selectedPlane == p) selectedPlane = walls.keys.firstOrNull()
            }
        }
    }

    private fun registerNewWall(plane: Plane) {
        val idx = nextIndex++
        val anchor = try { plane.createAnchor(plane.centerPose) } catch (t: Throwable) { return }
        val anchorNode = AnchorNode(sceneView.engine, anchor)
        sceneView.addChildNode(anchorNode)

        val state = WallState(index = idx, plane = plane, anchorNode = anchorNode)
        walls[plane] = state
        indexToPlane[idx] = plane

        // Add gold corner markers
        addCornerMarkers(state)

        // Auto-select first wall
        if (selectedPlane == null) {
            selectedPlane = plane
            state.isSelected = true
            updateMarkerAppearance(state)
        }

        sendEvent("wallDetected", mapOf(
            "wallIndex" to idx,
            "width" to plane.extentX.toDouble(),
            "height" to plane.extentZ.toDouble(),
            "sqm" to (plane.extentX * plane.extentZ).toDouble()
        ))
    }

    private fun onWallUpdated(state: WallState) {
        // Rebuild markers for new extent
        for (n in state.markerNodes) state.anchorNode?.removeChildNode(n)
        state.markerNodes.clear()
        addCornerMarkers(state)

        // Resize wallpaper geometry
        state.wallpaperNode?.let { node ->
            node.size = Float3(state.plane.extentX, state.plane.extentZ, 0f)
            state.currentWallpaper?.let { info ->
                applyTiling(node, state.plane.extentX, state.plane.extentZ, info)
            }
        }

        sendEvent("wallUpdated", mapOf(
            "wallIndex" to state.index,
            "width" to state.plane.extentX.toDouble(),
            "height" to state.plane.extentZ.toDouble(),
            "sqm" to (state.plane.extentX * state.plane.extentZ).toDouble()
        ))
    }

    // ---------------------------------------------------------------------
    // Corner markers
    // ---------------------------------------------------------------------

    private fun addCornerMarkers(state: WallState) {
        val anchorNode = state.anchorNode ?: return
        val w = state.plane.extentX
        val h = state.plane.extentZ
        val len = minOf(0.15f, minOf(w, h) * 0.25f)
        val thickness = 0.008f
        val halfW = w / 2
        val halfH = h / 2
        val color = if (state.isSelected) GOLD else GOLD_DIM

        val corners = listOf(
            Triple(Float3(-halfW,  0f,  halfH), Float3(-halfW + len, 0f,  halfH), Float3(-halfW, 0f,  halfH - len)),
            Triple(Float3( halfW,  0f,  halfH), Float3( halfW - len, 0f,  halfH), Float3( halfW, 0f,  halfH - len)),
            Triple(Float3(-halfW,  0f, -halfH), Float3(-halfW + len, 0f, -halfH), Float3(-halfW, 0f, -halfH + len)),
            Triple(Float3( halfW,  0f, -halfH), Float3( halfW - len, 0f, -halfH), Float3( halfW, 0f, -halfH + len))
        )
        for ((c, hEnd, vEnd) in corners) {
            val seg1 = makeSegment(c, hEnd, thickness, color)
            val seg2 = makeSegment(c, vEnd, thickness, color)
            anchorNode.addChildNode(seg1); state.markerNodes.add(seg1)
            anchorNode.addChildNode(seg2); state.markerNodes.add(seg2)
        }
    }

    private fun makeSegment(a: Float3, b: Float3, thickness: Float, color: io.github.sceneview.utils.Color): Node {
        val mid = (a + b) * 0.5f
        val delta = b - a
        val length = kotlin.math.sqrt(delta.x * delta.x + delta.z * delta.z)
        val size = Float3(
            if (kotlin.math.abs(delta.x) > kotlin.math.abs(delta.z)) length else thickness,
            thickness,
            if (kotlin.math.abs(delta.z) >= kotlin.math.abs(delta.x)) length else thickness
        )
        return CubeNode(
            engine = sceneView.engine,
            size = size,
            center = Position(0f, 0f, 0f),
            materialInstance = sceneView.materialLoader.createColorInstance(color, metallic = 0f, roughness = 1f)
        ).apply {
            position = Position(mid.x, mid.y, mid.z)
        }
    }

    private fun updateMarkerAppearance(state: WallState) {
        val color = if (state.isSelected) GOLD else GOLD_DIM
        for (n in state.markerNodes) {
            (n as? CubeNode)?.materialInstance?.setParameter("baseColorFactor", color.r, color.g, color.b, color.a)
        }
        // Hide brackets entirely once wallpaper is placed on a non-selected wall
        if (state.wallpaperNode != null) {
            for (n in state.markerNodes) n.isVisible = state.isSelected
        }
    }

    // ---------------------------------------------------------------------
    // Tap — select or place
    // ---------------------------------------------------------------------

    private fun handleTap(e: MotionEvent, hitResult: com.google.ar.core.HitResult?) {
        val frame = sceneView.frame ?: return
        val results = frame.hitTest(e)
        for (hit in results) {
            val trackable = hit.trackable
            if (trackable is Plane &&
                trackable.type == Plane.Type.VERTICAL &&
                trackable.isPoseInPolygon(hit.hitPose)) {
                val root = trackable.subsumedBy ?: trackable
                walls[root]?.let { selectWall(it.index) }
                return
            }
        }
    }

    // ---------------------------------------------------------------------
    // Wallpaper placement
    // ---------------------------------------------------------------------

    private fun placeWallpaper(info: WallpaperInfo, wallIndex: Int, result: MethodChannel.Result) {
        val plane = resolvePlane(wallIndex) ?: run {
            result.error("no_wall", "No wall available", null); return
        }
        val state = walls[plane] ?: run {
            result.error("no_wall", "Wall state missing", null); return
        }

        scope.launch {
            val textures = loadTextures(info)
            if (textures == null) {
                sendError("texture_load", "Failed to load PBR textures")
                result.error("texture_load", "Failed to load textures", null); return@launch
            }
            attachWallpaper(state, textures, info)
            sendEvent("wallpaperPlaced", mapOf("wallIndex" to state.index, "success" to true))
            result.success(true)
        }
    }

    private fun switchWallpaper(info: WallpaperInfo, wallIndex: Int, result: MethodChannel.Result) {
        val plane = indexToPlane[wallIndex] ?: run {
            result.error("no_wall", "Wall index not found", null); return
        }
        val state = walls[plane] ?: run {
            result.error("no_wall", "Wall state missing", null); return
        }

        scope.launch {
            val textures = loadTextures(info)
            if (textures == null) {
                result.error("texture_load", "Failed to load textures", null); return@launch
            }
            if (state.wallpaperNode == null) {
                attachWallpaper(state, textures, info)
            } else {
                updateWallpaperMaterial(state, textures, info)
            }
            sendEvent("wallpaperPlaced", mapOf("wallIndex" to state.index, "success" to true))
            result.success(true)
        }
    }

    private fun resolvePlane(wallIndex: Int): Plane? {
        if (wallIndex >= 0) indexToPlane[wallIndex]?.let { return it }
        selectedPlane?.let { return it }
        return walls.keys.firstOrNull()
    }

    private data class PBRTextures(
        val albedo: String,
        val normal: String,
        val roughness: String,
        val ao: String
    )

    private suspend fun loadTextures(info: WallpaperInfo): PBRTextures? = withContext(Dispatchers.IO) {
        try {
            val a = textureCache.loadLocalPath(info.albedoUrl) ?: return@withContext null
            val n = textureCache.loadLocalPath(info.normalUrl) ?: return@withContext null
            val r = textureCache.loadLocalPath(info.roughnessUrl) ?: return@withContext null
            val o = textureCache.loadLocalPath(info.aoUrl) ?: return@withContext null
            PBRTextures(a, n, r, o)
        } catch (t: Throwable) {
            Log.e(TAG, "Texture load failed", t); null
        }
    }

    private suspend fun attachWallpaper(state: WallState, textures: PBRTextures, info: WallpaperInfo) {
        val anchorNode = state.anchorNode ?: return
        val w = state.plane.extentX
        val h = state.plane.extentZ

        // Build PBR material via Filament/SceneView material loader
        val material = sceneView.materialLoader.createMaterialInstance(
            baseColorMap = Uri.fromFile(java.io.File(textures.albedo)),
            normalMap = Uri.fromFile(java.io.File(textures.normal)),
            roughnessMap = Uri.fromFile(java.io.File(textures.roughness)),
            metallicFactor = 0f
        )
        // AO map (SceneView's helper covers color/normal/roughness/metallic; AO set via parameter)
        try {
            val aoTexture = sceneView.textureLoader.createTextureFromUri(
                Uri.fromFile(java.io.File(textures.ao))
            )
            material.setParameter("aoMap", aoTexture, io.github.sceneview.material.TextureSampler())
        } catch (t: Throwable) {
            Log.w(TAG, "AO map not applied (material variant may not support it)", t)
        }

        val node = PlaneNode(
            engine = sceneView.engine,
            size = Float3(w, h, 0f),
            center = Position(0f, 0f, 0f),
            materialInstance = material
        ).apply {
            // Orient so the plane lies flat against the wall's anchor pose (AnchorNode already
            // follows the plane's pose, so we just keep identity local rotation).
            rotation = Rotation(0f, 0f, 0f)
            position = Position(0f, 0f, 0f)
        }

        applyTiling(node, w, h, info)

        // Fade in
        node.isVisible = true
        anchorNode.addChildNode(node)

        // Remove previous wallpaper if any
        state.wallpaperNode?.let { anchorNode.removeChildNode(it) }
        state.wallpaperNode = node
        state.currentWallpaper = info

        // Hide brackets on placed walls unless selected
        for (m in state.markerNodes) m.isVisible = state.isSelected
    }

    private suspend fun updateWallpaperMaterial(state: WallState, textures: PBRTextures, info: WallpaperInfo) {
        val node = state.wallpaperNode ?: return
        val mi = node.materialInstance
        try {
            val baseColor = sceneView.textureLoader.createTextureFromUri(Uri.fromFile(java.io.File(textures.albedo)))
            val normal    = sceneView.textureLoader.createTextureFromUri(Uri.fromFile(java.io.File(textures.normal)))
            val rough     = sceneView.textureLoader.createTextureFromUri(Uri.fromFile(java.io.File(textures.roughness)))
            val ao        = sceneView.textureLoader.createTextureFromUri(Uri.fromFile(java.io.File(textures.ao)))

            val sampler = io.github.sceneview.material.TextureSampler()
            mi.setParameter("baseColorMap", baseColor, sampler)
            mi.setParameter("normalMap", normal, sampler)
            mi.setParameter("roughnessMap", rough, sampler)
            mi.setParameter("aoMap", ao, sampler)
            mi.setParameter("metallicFactor", 0f)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to swap textures", t)
        }
        applyTiling(node, state.plane.extentX, state.plane.extentZ, info)
        state.currentWallpaper = info
    }

    private fun applyTiling(node: PlaneNode, wallWidth: Float, wallHeight: Float, info: WallpaperInfo) {
        val repeatX = (wallWidth / info.rollWidth.coerceAtLeast(0.01f)).coerceAtLeast(0.1f)
        val repeatY = (wallHeight / info.rollWidth.coerceAtLeast(0.01f)).coerceAtLeast(0.1f)
        try {
            node.materialInstance.setParameter("uvScale", repeatX, repeatY)
        } catch (t: Throwable) {
            Log.w(TAG, "uvScale parameter not present on material — custom material needed for precise tiling")
        }
    }

    // ---------------------------------------------------------------------
    // Wall selection / clearing
    // ---------------------------------------------------------------------

    private fun selectWall(index: Int) {
        val plane = indexToPlane[index] ?: return
        selectedPlane = plane
        for ((p, s) in walls) {
            s.isSelected = (p == plane)
            updateMarkerAppearance(s)
        }
        sendEvent("wallSelected", mapOf("wallIndex" to index))
    }

    private fun clearWall(index: Int) {
        val plane = indexToPlane[index] ?: return
        val state = walls[plane] ?: return
        state.wallpaperNode?.let { state.anchorNode?.removeChildNode(it) }
        state.wallpaperNode = null
        state.currentWallpaper = null
        for (m in state.markerNodes) m.isVisible = true
    }

    // ---------------------------------------------------------------------
    // Disposal
    // ---------------------------------------------------------------------

    private fun disposeAR() {
        try {
            for ((_, state) in walls) {
                state.anchorNode?.let { sceneView.removeChildNode(it) }
            }
            walls.clear()
            indexToPlane.clear()
            selectedPlane = null
            sceneView.destroy()
        } catch (t: Throwable) {
            Log.w(TAG, "Dispose error", t)
        }
    }

    // ---------------------------------------------------------------------
    // Event channel
    // ---------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun sendEvent(type: String, data: Map<String, Any?>) {
        val sink = eventSink ?: return
        sceneView.post {
            sink.success(mapOf("type" to type, "data" to data))
        }
    }

    private fun sendError(code: String, message: String) {
        sendEvent("error", mapOf("code" to code, "message" to message))
    }

    // ---------------------------------------------------------------------
    // Colors
    // ---------------------------------------------------------------------

    private val GOLD = io.github.sceneview.utils.Color(1.0f, 0.827f, 0.411f, 1.0f)
    private val GOLD_DIM = io.github.sceneview.utils.Color(1.0f, 0.827f, 0.411f, 0.55f)
}
