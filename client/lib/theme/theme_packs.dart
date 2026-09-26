import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'nyx_theme.dart';
import 'pack_store.dart';

/// A parsed, validated theme pack.
class PackData {
  final String id;
  final Map<String, dynamic> json;
  final Map<String, Uint8List> files;
  final ThemeSettings settings;
  PackData(this.id, this.json, this.files, this.settings);
}

class PackInfo {
  final String id, name, author;
  final Color accent, secondary, background, surface;
  final bool hasBackground, hasFont;
  PackInfo(this.id, this.name, this.author, this.accent, this.secondary, this.background, this.surface, this.hasBackground, this.hasFont);
}

class PackFormatException implements Exception {
  final String message;
  PackFormatException(this.message);
  @override
  String toString() => message;
}

/// Theme packs are plain data - a `theme.json` and the pictures / fonts it names. Nothing in a pack is ever
/// executed, so installing one someone sent you cannot run code on your device.
///
/// A pack is a folder (or a .nyxtheme / .zip of it):
///   theme.json         colours, shape, background, typography, message style
///   background.gif     optional: still or animated picture (png, jpg, gif, webp)
///   fonts/Name.ttf     optional: fonts (ttf / otf)
class ThemePacks {
  final store = PackStore();

  static const maxFile = 25 * 1024 * 1024;
  static const maxTotal = 60 * 1024 * 1024;
  static const imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp'};
  static const fontExt = {'ttf', 'otf'};

  String fontFamily(String packId) => 'pack-$packId';

  // ------------------------------------------------------------------ parsing

  static String _ext(String path) => path.contains('.') ? path.split('.').last.toLowerCase() : '';

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    final jpg = b[0] == 0xFF && b[1] == 0xD8;
    final gif = b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46;
    final webp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
    return png || jpg || gif || webp;
  }

  static String _cleanPath(String p) {
    final c = p.replaceAll('\\', '/').replaceAll(RegExp(r'^\./'), '');
    if (c.startsWith('/') || c.contains('..') || c.contains(':')) throw PackFormatException('Unsafe file path in theme: "$p"');
    return c;
  }

  /// Turns files + theme.json into settings, or throws [PackFormatException] with a message meant for people.
  PackData parse(String id, Map<String, Uint8List> files) {
    final raw = files['theme.json'];
    if (raw == null) throw PackFormatException('This folder has no theme.json.');
    var total = 0;
    for (final e in files.entries) {
      if (e.value.length > maxFile) throw PackFormatException('"${e.key}" is larger than ${maxFile ~/ (1024 * 1024)} MB.');
      total += e.value.length;
    }
    if (total > maxTotal) throw PackFormatException('The theme is larger than ${maxTotal ~/ (1024 * 1024)} MB.');

    Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    } catch (_) {
      throw PackFormatException('theme.json is not valid JSON.');
    }
    Map<String, dynamic> section(String k) => (j[k] as Map?)?.cast<String, dynamic>() ?? {};
    final colors = section('colors'), shape = section('shape'), bg = section('background'), type = section('typography'), msgs = section('messages'), fx = section('effects');

    final d = ThemeSettings();
    double n(Map m, String k, double def, double lo, double hi) => ((m[k] as num?)?.toDouble() ?? def).clamp(lo, hi).toDouble();
    bool b(Map m, String k, bool def) => m[k] is bool ? m[k] as bool : def;

    final s = ThemeSettings(
      name: ((j['name'] as String?) ?? id).trim().isEmpty ? id : ((j['name'] as String?) ?? id),
      author: (j['author'] as String?) ?? '',
      accent: parseColor(colors['accent']) ?? d.accent,
      secondary: parseColor(colors['secondary']) ?? d.secondary,
      background: parseColor(colors['background']) ?? d.background,
      surface: parseColor(colors['surface']) ?? d.surface,
      danger: parseColor(colors['danger']) ?? d.danger,
      online: parseColor(colors['online']) ?? d.online,
      textColor: parseColor(colors['text']),
      radius: n(shape, 'radius', d.radius, 0, 40),
      blur: n(shape, 'blur', d.blur, 0, 60),
      panelOpacity: n(shape, 'panelOpacity', d.panelOpacity, 0, 1),
      fontScale: n(type, 'scale', 1, .7, 1.8),
      animatedBackground: b(bg, 'animated', true),
      compact: b(msgs, 'compact', false),
      messageStyle: MessageStyle.values.asNameMap()[msgs['style']] ?? MessageStyle.flat,
      speakingGlow: b(fx, 'speakingGlow', true),
      hoverAnimations: b(fx, 'hoverAnimations', true),
      reduceMotion: b(fx, 'reduceMotion', false),
      backgroundKind: BackgroundKind.values.asNameMap()[bg['type']] ?? BackgroundKind.aurora,
      backgroundOpacity: n(bg, 'opacity', 1, 0, 1),
      backgroundBlur: n(bg, 'blur', 0, 0, 60),
      backgroundFit: (bg['fit'] as String?) == 'contain' || bg['fit'] == 'tile' ? bg['fit'] as String : 'cover',
      gradient: ((bg['gradient'] as List?) ?? const []).map(parseColor).whereType<Color>().toList().length >= 2 ? ((bg['gradient'] as List).map(parseColor).whereType<Color>().toList()) : d.gradient,
      packId: id,
    );

    final used = <String, Uint8List>{'theme.json': raw};
    if (s.backgroundKind == BackgroundKind.image) {
      final f = bg['image'] as String?;
      if (f == null) throw PackFormatException('background.type is "image" but background.image is missing.');
      final path = _cleanPath(f);
      final bytes = files[path];
      if (bytes == null) throw PackFormatException('Background picture "$f" is not in the theme.');
      if (!imageExt.contains(_ext(path)) || !_looksLikeImage(bytes)) throw PackFormatException('"$f" is not a png / jpg / gif / webp picture.');
      used[path] = bytes;
      s.backgroundFile = path;
      s.backgroundImage = path;
    }
    for (final f in ((type['files'] as List?) ?? const []).whereType<String>()) {
      final path = _cleanPath(f);
      final bytes = files[path];
      if (bytes == null) throw PackFormatException('Font "$f" is not in the theme.');
      if (!fontExt.contains(_ext(path))) throw PackFormatException('"$f" is not a .ttf or .otf font.');
      used[path] = bytes;
      s.fontFiles.add(path);
    }
    s.assets = Map.of(used);
    if (s.fontFiles.isNotEmpty) s.fontFamily = fontFamily(id);
    return PackData(id, j, used, s);
  }

  static String idFrom(String name) {
    final id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return id.isEmpty ? 'theme' : id;
  }

  // --------------------------------------------------------------------- import

  /// Accepts a .nyxtheme / .zip. theme.json may be at the top or inside a single folder.
  PackData importZip(Uint8List zip, {String? fallbackName}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip);
    } catch (_) {
      throw PackFormatException('That file is not a valid zip archive.');
    }
    var files = <String, Uint8List>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final path = f.name.replaceAll('\\', '/');
      if (path.contains('..') || path.startsWith('/')) throw PackFormatException('The archive contains an unsafe path.');
      if (f.size > maxFile) throw PackFormatException('"$path" is larger than ${maxFile ~/ (1024 * 1024)} MB.');
      files[path] = Uint8List.fromList(f.content as List<int>);
    }
    // Strip a single wrapping folder.
    if (!files.containsKey('theme.json')) {
      final candidate = files.keys.where((k) => k.endsWith('/theme.json') && k.split('/').length == 2).firstOrNull;
      if (candidate != null) {
        final prefix = candidate.substring(0, candidate.length - 'theme.json'.length);
        files = {for (final e in files.entries) if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value};
      }
    }
    final name = _nameOf(files) ?? fallbackName ?? 'theme';
    return parse(idFrom(name), files);
  }

  Future<PackData> importFolder(String path) async {
    final files = await store.readExternalFolder(path);
    final name = _nameOf(files) ?? path.split(RegExp(r'[\\/]')).last;
    return parse(idFrom(name), files);
  }

  static String? _nameOf(Map<String, Uint8List> files) {
    try {
      return (jsonDecode(utf8.decode(files['theme.json']!)) as Map)['name'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> install(PackData d) => store.write(d.id, d.files);

  Future<List<PackInfo>> list() async {
    final out = <PackInfo>[];
    for (final id in await store.listIds()) {
      if (id == '_local') continue;
      try {
        final d = parse(id, await store.read(id));
        out.add(PackInfo(id, d.settings.name, d.settings.author, d.settings.accent, d.settings.secondary, d.settings.background, d.settings.surface, d.settings.backgroundFile != null, d.settings.fontFiles.isNotEmpty));
      } catch (_) {
        // A broken pack in the folder is skipped instead of breaking the list.
      }
    }
    return out;
  }

  Future<PackData?> read(String id) async {
    try {
      return parse(id, await store.read(id));
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String id) => store.delete(id);

  // -------------------------------------------------------------------- fonts

  final _loadedFonts = <String>{};

  Future<void> loadFonts(String id, List<String> paths, Map<String, Uint8List> files) async {
    if (paths.isEmpty || _loadedFonts.contains(id)) return;
    final loader = FontLoader(fontFamily(id));
    for (final p in paths) {
      final bytes = files[p];
      if (bytes != null) loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    try {
      await loader.load();
      _loadedFonts.add(id);
    } catch (_) {}
  }

  // ------------------------------------------------------------------- export

  Uint8List exportZip(ThemeSettings s) {
    final json = <String, dynamic>{
      'name': s.name,
      'author': s.author,
      'version': 1,
      'colors': {'accent': hexOf(s.accent), 'secondary': hexOf(s.secondary), 'background': hexOf(s.background), 'surface': hexOf(s.surface), 'danger': hexOf(s.danger), 'online': hexOf(s.online), if (s.textColor != null) 'text': hexOf(s.textColor!)},
      'shape': {'radius': s.radius, 'blur': s.blur, 'panelOpacity': s.panelOpacity},
      'background': {
        'type': s.backgroundKind.name,
        'animated': s.animatedBackground,
        'opacity': s.backgroundOpacity,
        'blur': s.backgroundBlur,
        'fit': s.backgroundFit,
        'gradient': s.gradient.map(hexOf).toList(),
        if (s.backgroundKind == BackgroundKind.image && s.backgroundFile != null) 'image': s.backgroundFile,
      },
      'typography': {'scale': s.fontScale, if (s.fontFiles.isNotEmpty) 'files': s.fontFiles},
      'messages': {'style': s.messageStyle.name, 'compact': s.compact},
      'effects': {'speakingGlow': s.speakingGlow, 'hoverAnimations': s.hoverAnimations, 'reduceMotion': s.reduceMotion},
    };
    final a = Archive();
    void add(String name, List<int> data) => a.addFile(ArchiveFile(name, data.length, data));
    add('theme.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(json)));
    for (final path in [if (s.backgroundKind == BackgroundKind.image) s.backgroundFile, ...s.fontFiles]) {
      final bytes = path == null ? null : s.assets[path];
      if (bytes != null) add(path!, bytes);
    }
    return Uint8List.fromList(ZipEncoder().encode(a));
  }

  /// Copy-paste starting point shown in the app.
  static const template = '''{
  "name": "My theme",
  "author": "you",
  "version": 1,
  "colors": {
    "accent": "#FF7A59",
    "secondary": "#FFC857",
    "background": "#120B0A",
    "surface": "#1E1412",
    "text": "#F5E9E4"
  },
  "shape": { "radius": 18, "blur": 22, "panelOpacity": 0.55 },
  "background": {
    "type": "image",
    "image": "background.gif",
    "opacity": 0.85,
    "blur": 6,
    "fit": "cover"
  },
  "typography": { "scale": 1.0 },
  "messages": { "style": "bubbles", "compact": false },
  "effects": { "speakingGlow": true, "hoverAnimations": true }
}
''';
}
