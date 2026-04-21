//
//  AppDelegate.swift
//  OBOIA
//
//  Registers Flutter plugins + the ARWallpaperView platform view factory.
//

import UIKit
import Flutter
import FirebaseCore

@main
@objc class AppDelegate: FlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // Firebase
        FirebaseApp.configure()

        // Standard Flutter plugins
        GeneratedPluginRegistrant.register(with: self)

        // Register the native AR platform view
        guard let controller = window?.rootViewController as? FlutterViewController else {
            fatalError("rootViewController is not FlutterViewController")
        }
        let registrar = self.registrar(forPlugin: "ARWallpaperPlugin")!
        let factory = ARWallpaperViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "com.oboia/ar_view")

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
