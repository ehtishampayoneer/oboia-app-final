package com.oboia.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register the native AR platform view
        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory(
                "com.oboia/ar_view",
                ARWallpaperViewFactory(flutterEngine.dartExecutor.binaryMessenger)
            )
    }
}
