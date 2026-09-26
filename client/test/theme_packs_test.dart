import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/theme/nyx_theme.dart';
import 'package:nyx/theme/theme_packs.dart';

Uint8List j(Map<String, dynamic> m) => Uint8List.fromList(utf8.encode(jsonEncode(m)));

// Smallest valid-looking GIF header + padding (only the magic bytes matter to the sniffing check).
final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B]);

Uint8List zipOf(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((k, v) => a.addFile(ArchiveFile(k, v.length, v)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  final packs = ThemePacks();

  test('a minimal theme.json parses with sane defaults', () {
    final d = packs.parse('mini', {'theme.json': j({'name': 'Mini', 'colors': {'accent': '#FF0000'}})});
    expect(d.settings.name, 'Mini');
    expect(d.settings.accent.toARGB32(), 0xFFFF0000);
    expect(d.settings.radius, 16); // untouched default
    expect(d.settings.backgroundKind, BackgroundKind.aurora);
  });

  test('values are clamped instead of trusted', () {
    final d = packs.parse('x', {'theme.json': j({'shape': {'radius': 9999, 'blur': -5, 'panelOpacity': 7}, 'typography': {'scale': 50}})});
    expect(d.settings.radius, 40);
    expect(d.settings.blur, 0);
    expect(d.settings.panelOpacity, 1);
    expect(d.settings.fontScale, 1.8);
  });

  test('nonsense colours and unknown keys are ignored', () {
    final d = packs.parse('x', {'theme.json': j({'colors': {'accent': 'red', 'surface': 12345}, 'evil': {'run': 'rm -rf /'}})});
    expect(d.settings.accent, ThemeSettings().accent);
  });

  test('image background needs a real picture that is in the pack', () {
    final ok = packs.parse('bg', {
      'theme.json': j({'background': {'type': 'image', 'image': 'bg.gif'}}),
      'bg.gif': gif,
    });
    expect(ok.settings.backgroundKind, BackgroundKind.image);
    expect(ok.settings.backgroundFile, 'bg.gif');
    expect(ok.files.keys, containsAll(['theme.json', 'bg.gif']));

    expect(() => packs.parse('bg', {'theme.json': j({'background': {'type': 'image', 'image': 'bg.gif'}})}), throwsA(isA<PackFormatException>()));
    expect(() => packs.parse('bg', {'theme.json': j({'background': {'type': 'image'}})}), throwsA(isA<PackFormatException>()));
    // Right extension, wrong content: rejected (nobody hides an executable behind .png).
    expect(() => packs.parse('bg', {'theme.json': j({'background': {'type': 'image', 'image': 'bg.png'}}), 'bg.png': Uint8List.fromList(List.filled(64, 65))}), throwsA(isA<PackFormatException>()));
    // Wrong extension.
    expect(() => packs.parse('bg', {'theme.json': j({'background': {'type': 'image', 'image': 'bg.exe'}}), 'bg.exe': gif}), throwsA(isA<PackFormatException>()));
  });

  test('paths cannot escape the pack', () {
    for (final bad in ['../secret.png', '/etc/passwd', 'C:\\Windows\\x.png', 'a/../../b.png']) {
      expect(() => packs.parse('p', {'theme.json': j({'background': {'type': 'image', 'image': bad}}), bad: gif}), throwsA(isA<PackFormatException>()), reason: bad);
    }
    expect(() => packs.parse('p', {'theme.json': j({'typography': {'files': ['../../evil.ttf']}}), '../../evil.ttf': Uint8List(10)}), throwsA(isA<PackFormatException>()));
  });

  test('missing or broken theme.json is reported in plain words', () {
    expect(() => packs.parse('p', {}), throwsA(predicate((e) => e.toString().contains('theme.json'))));
    expect(() => packs.parse('p', {'theme.json': Uint8List.fromList(utf8.encode('{not json'))}), throwsA(isA<PackFormatException>()));
  });

  test('size limits', () {
    expect(() => packs.parse('p', {'theme.json': j({}), 'huge.bin': Uint8List(ThemePacks.maxFile + 1)}), throwsA(isA<PackFormatException>()));
  });

  test('fonts must be ttf/otf files that are in the pack', () {
    final ok = packs.parse('f', {'theme.json': j({'typography': {'files': ['fonts/A.ttf']}}), 'fonts/A.ttf': Uint8List(100)});
    expect(ok.settings.fontFiles, ['fonts/A.ttf']);
    expect(ok.settings.fontFamily, 'pack-f');
    expect(() => packs.parse('f', {'theme.json': j({'typography': {'files': ['fonts/A.woff']}}), 'fonts/A.woff': Uint8List(100)}), throwsA(isA<PackFormatException>()));
    expect(() => packs.parse('f', {'theme.json': j({'typography': {'files': ['fonts/A.ttf']}})}), throwsA(isA<PackFormatException>()));
  });

  test('zip import: top level, wrapped in a folder, and rejects traversal / junk', () {
    final theme = j({'name': 'Zipped', 'colors': {'accent': '#00FF00'}, 'background': {'type': 'image', 'image': 'bg.gif'}});
    final flat = packs.importZip(zipOf({'theme.json': theme, 'bg.gif': gif}));
    expect(flat.id, 'zipped');
    expect(flat.settings.backgroundFile, 'bg.gif');
    final wrapped = packs.importZip(zipOf({'Zipped/theme.json': theme, 'Zipped/bg.gif': gif}));
    expect(wrapped.settings.backgroundFile, 'bg.gif');

    expect(() => packs.importZip(zipOf({'../theme.json': theme})), throwsA(isA<PackFormatException>()));
    expect(() => packs.importZip(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<PackFormatException>()));
    expect(() => packs.importZip(zipOf({'readme.txt': utf8.encode('hi')})), throwsA(isA<PackFormatException>()));
  });

  test('export -> import round-trips the look (including the background picture)', () {
    final original = ThemeSettings(name: 'Round Trip', author: 'me', accent: const Color(0xFF123456), radius: 22, blur: 9, messageStyle: MessageStyle.bubbles, backgroundKind: BackgroundKind.image, backgroundFile: 'background.gif', compact: true)
      ..assets = {'background.gif': gif}
      ..backgroundImage = 'background.gif';
    final zip = packs.exportZip(original);
    final back = packs.importZip(zip).settings;
    expect(back.name, 'Round Trip');
    expect(back.accent.toARGB32(), 0xFF123456);
    expect(back.radius, 22);
    expect(back.messageStyle, MessageStyle.bubbles);
    expect(back.compact, isTrue);
    expect(back.backgroundKind, BackgroundKind.image);
    expect(back.assets['background.gif'], gif);
  });

  test('the shipped template is itself a valid theme (given its picture)', () {
    final json = jsonDecode(ThemePacks.template) as Map<String, dynamic>;
    expect(json['name'], isNotEmpty);
    final d = packs.parse('t', {'theme.json': Uint8List.fromList(utf8.encode(ThemePacks.template)), 'background.gif': gif});
    expect(d.settings.messageStyle, MessageStyle.bubbles);
  });

  test('settings survive JSON round trip', () {
    final s = ThemeSettings(name: 'S', accent: const Color(0xFFABCDEF), gradient: const [Color(0xFF111111), Color(0xFF222222)], textColor: const Color(0xFFEEEEEE), animatedBackground: false);
    final t = ThemeSettings.fromJson(s.toJson());
    expect(t.accent, s.accent);
    expect(t.textColor, s.textColor);
    expect(t.animatedBackground, isFalse);
    expect(t.gradient.length, 2);
  });
}
