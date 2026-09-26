import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'files.dart';

/// The GIFs a person saved. Only the references (id + key) are kept on this device; the pictures themselves
/// are encrypted blobs on the server, so any saved GIF can be sent to anyone in one tap.
class GifLibrary extends ChangeNotifier {
  GifLibrary._();
  static final instance = GifLibrary._();
  static const max = 200;

  String _user = '';
  final items = <BlobRef>[];

  String get _key => 'nyx.gifs.$_user';

  Future<void> load(String userId) async {
    if (_user == userId) return;
    _user = userId;
    items.clear();
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final r = BlobRef.from(j);
          if (r != null) items.add(r);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  bool has(String blobId) => items.any((r) => r.id == blobId);

  Future<void> _persist() async {
    try {
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode([for (final r in items) r.toJson()]));
    } catch (_) {}
  }

  Future<void> add(BlobRef r) async {
    if (has(r.id)) return;
    items.insert(0, r);
    if (items.length > max) items.removeRange(max, items.length);
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String blobId) async {
    items.removeWhere((r) => r.id == blobId);
    notifyListeners();
    await _persist();
  }

  void clear() {
    _user = '';
    items.clear();
    notifyListeners();
  }
}
