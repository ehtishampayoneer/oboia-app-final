import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        GeneratedPluginRegistrant.register(with: self)

        if let registrar = self.registrar(forPlugin: "ARWallpaperPlugin") {
            let factory = ARWallpaperViewFactory(messenger: registrar.messenger())
            registrar.register(factory, withId: "com.oboia/ar_view")
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
