//
//  ARWallpaperViewFactory.swift
//  OBOIA
//
//  Registers WallpaperARView as an embeddable Flutter platform view.
//

import Foundation
import Flutter
import UIKit

final class ARWallpaperViewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        return WallpaperARView(
            frame: frame,
            viewId: viewId,
            messenger: messenger,
            args: args
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}
