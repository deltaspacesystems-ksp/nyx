import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// In the browser there is no folder to drop packs into; packs are kept in the browser's own storage
/// (as long as they fit) and imported from a .nyxtheme / .zip file.
class PackStore {
  static const supportsFolder = false;
  static const _key = 'theme_packs_v1';

  Future<Map<String, dynamic>> _all() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_key);
      return s == null ? {} : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> all) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(all));
    } catch (_) {} // storage full: the pack still works for this session
  }

  Future<String?> folderPath() async => null;

  Future<List<String>> listIds() async => ((await _all()).keys.toList())..sort();

  Future<Map<String, Uint8List>> read(String id) async {
    final files = (await _all())[id] as Map<String, dynamic>?;
    return {for (final e in (files ?? {}).entries) e.key: base64Decode(e.value as String)};
  }

  Future<void> write(String id, Map<String, Uint8List> files) async {
    final all = await _all();
    all[id] = {for (final e in files.entries) e.key: base64Encode(e.value)};
    await _save(all);
  }

  Future<void> delete(String id) async {
    final all = await _all();
    all.remove(id);
    await _save(all);
  }

  Future<Map<String, Uint8List>> readExternalFolder(String path) async => {};
}
