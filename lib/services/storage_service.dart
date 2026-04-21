import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

/// Thin wrapper over Firebase Storage for profile photo uploads.
/// NOTE: Firebase Storage must be enabled in the Firebase console for this
/// to work (it is NOT enabled in the current OBOIA project per the spec).
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> uploadProfilePhoto({
    required String uid,
    required File file,
  }) async {
    final ref = _storage.ref().child('users/$uid/avatar.jpg');
    final metadata = SettableMetadata(contentType: 'image/jpeg');
    await ref.putFile(file, metadata);
    return ref.getDownloadURL();
  }
}
