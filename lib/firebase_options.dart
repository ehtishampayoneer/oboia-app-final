import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA19aEUkdcbph_SiWeELXPlDLL0GtsHc-w',
    appId: '1:223722007359:web:b656ced819740134c0418a',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    authDomain: 'oboia-server.firebaseapp.com',
    storageBucket: 'oboia-server.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyATQwItQxk0nZI_yI5pIl72xoi3idNevNY',
    appId: '1:223722007359:android:58c3b226aaa322d0c0418a',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    storageBucket: 'oboia-server.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyB6iHyiXlfla7UTa8DAStgrWs2cyT44w2I',
    appId: '1:223722007359:ios:b290f3a3927e47d7c0418a',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    storageBucket: 'oboia-server.firebasestorage.app',
    iosBundleId: 'com.oboia.app',
  );
}
