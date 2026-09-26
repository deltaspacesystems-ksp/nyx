import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/theme/nyx_theme.dart';
import 'package:nyx/theme/theme_packs.dart';

void main() {
  test('the shipped example pack imports and its GIF really is animated', () async {
    final file = File('../themes-examples/sunset-drift.nyxtheme');
    if (!file.existsSync()) return; // running outside the repo
    final d = ThemePacks().importZip(await file.readAsBytes());
    expect(d.settings.name, 'Sunset Drift');
    expect(d.settings.backgroundKind, BackgroundKind.image);
    final codec = await ui.instantiateImageCodec(d.settings.assets['background.gif']!);
    expect(codec.frameCount, 16);
    final frame = await codec.getNextFrame();
    expect((frame.image.width, frame.image.height), (320, 180));
  });
}
