import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Theme packs on disk: `<app data>/Nyx/themes/<id>/theme.json` plus whatever files it references.
/// Users can also drop a folder in there by hand.
class PackStore {
  static const supportsFolder = true;

  Future<Directory> _root() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}themes');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Future<String?> folderPath() async => (await _root()).path;

  Future<List<String>> listIds() async {
    final root = await _root();
    final ids = <String>[];
    await for (final e in root.list()) {
      if (e is Directory && await File('${e.path}${Platform.pathSeparator}theme.json').exists()) {
        ids.add(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      }
    }
    ids.sort();
    return ids;
  }

  Future<Map<String, Uint8List>> read(String id) async {
    final dir = Directory('${(await _root()).path}${Platform.pathSeparator}${_safe(id)}');
    final out = <String, Uint8List>{};
    if (!await dir.exists()) return out;
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        final rel = e.path.substring(dir.path.length + 1).replaceAll(Platform.pathSeparator, '/');
        out[rel] = await e.readAsBytes();
      }
    }
    return out;
  }

  Future<void> write(String id, Map<String, Uint8List> files) async {
    final dir = Directory('${(await _root()).path}${Platform.pathSeparator}${_safe(id)}');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    for (final e in files.entries) {
      if (e.key.contains('..')) continue; // never write outside the pack folder
      final f = File('${dir.path}${Platform.pathSeparator}${e.key.replaceAll('/', Platform.pathSeparator)}');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(e.value);
    }
  }

  Future<void> delete(String id) async {
    final dir = Directory('${(await _root()).path}${Platform.pathSeparator}${_safe(id)}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Reads a folder the user picked (any location).
  Future<Map<String, Uint8List>> readExternalFolder(String path) async {
    final dir = Directory(path);
    final out = <String, Uint8List>{};
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        final rel = e.path.substring(dir.path.length + 1).replaceAll(Platform.pathSeparator, '/');
        out[rel] = await e.readAsBytes();
      }
    }
    return out;
  }
}
