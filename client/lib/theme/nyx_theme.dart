import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_packs.dart';

enum BackgroundKind { aurora, solid, gradient, image }
enum MessageStyle { flat, bubbles }

Color? parseColor(dynamic v) {
  if (v is int) return Color(v);
  if (v is! String) return null;
  var s = v.trim().replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  if (s.length == 3) s = 'FF${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
  final n = int.tryParse(s, radix: 16);
  return n == null ? null : Color(n);
}

String hexOf(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// Everything a theme can change. Serialised to JSON (settings) and loadable from theme packs.
class ThemeSettings {
  String name;
  String author;
  Color accent, secondary, background, surface, danger, online;
  Color? textColor; // null = derived from the surface
  double radius, blur, panelOpacity, fontScale;
  bool animatedBackground, reduceMotion, compact, speakingGlow, hoverAnimations;
  String fontFamily;
  BackgroundKind backgroundKind;
  List<Color> gradient;
  double backgroundOpacity, backgroundBlur;
  String backgroundFit; // cover | contain | tile
  MessageStyle messageStyle;

  /// Files that came with a theme pack (background image, fonts...), by relative path. Not persisted in
  /// settings JSON: packs are re-read from the theme folder.
  Map<String, Uint8List> assets;
  String? backgroundImage; // key into [assets]
  String? packId; // which installed pack the assets come from ('_local' = picture the user chose)
  String? backgroundFile; // relative path inside the pack
  List<String> fontFiles; // relative paths inside the pack

  ThemeSettings({
    this.name = 'Nyx',
    this.author = '',
    this.accent = const Color(0xFF8B7CFF),
    this.secondary = const Color(0xFF39D0C7),
    this.background = const Color(0xFF0B0B14),
    this.surface = const Color(0xFF15151F),
    this.danger = const Color(0xFFE5484D),
    this.online = const Color(0xFF3DDC84),
    this.textColor,
    this.radius = 16,
    this.blur = 18,
    this.panelOpacity = .55,
    this.fontScale = 1,
    this.animatedBackground = true,
    this.reduceMotion = false,
    this.compact = false,
    this.speakingGlow = true,
    this.hoverAnimations = true,
    this.fontFamily = '',
    this.backgroundKind = BackgroundKind.aurora,
    this.gradient = const [Color(0xFF0B0B14), Color(0xFF1A1030)],
    this.backgroundOpacity = 1,
    this.backgroundBlur = 0,
    this.backgroundFit = 'cover',
    this.messageStyle = MessageStyle.flat,
    Map<String, Uint8List>? assets,
    this.backgroundImage,
    this.packId,
    this.backgroundFile,
    List<String>? fontFiles,
  })  : assets = assets ?? {},
        fontFiles = fontFiles ?? [];

  bool get isLight => background.computeLuminance() > .5;

  ThemeSettings copy() => ThemeSettings.fromJson(toJson())..assets = Map.of(assets);

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'accent': hexOf(accent),
        'secondary': hexOf(secondary),
        'background': hexOf(background),
        'surface': hexOf(surface),
        'danger': hexOf(danger),
        'online': hexOf(online),
        if (textColor != null) 'text': hexOf(textColor!),
        'radius': radius,
        'blur': blur,
        'panelOpacity': panelOpacity,
        'fontScale': fontScale,
        'animated': animatedBackground,
        'reduceMotion': reduceMotion,
        'compact': compact,
        'speakingGlow': speakingGlow,
        'hoverAnimations': hoverAnimations,
        'font': fontFamily,
        'bg': backgroundKind.name,
        'gradient': gradient.map(hexOf).toList(),
        'bgOpacity': backgroundOpacity,
        'bgBlur': backgroundBlur,
        'bgFit': backgroundFit,
        'messages': messageStyle.name,
        if (packId != null) 'pack': packId,
        if (backgroundFile != null) 'bgFile': backgroundFile,
        if (fontFiles.isNotEmpty) 'fontFiles': fontFiles,
      };

  static ThemeSettings fromJson(Map<String, dynamic> j) {
    final d = ThemeSettings();
    double n(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    bool b(String k, bool def) => j[k] is bool ? j[k] as bool : def;
    return ThemeSettings(
      name: (j['name'] as String?) ?? d.name,
      author: (j['author'] as String?) ?? '',
      accent: parseColor(j['accent']) ?? d.accent,
      secondary: parseColor(j['secondary']) ?? d.secondary,
      background: parseColor(j['background']) ?? d.background,
      surface: parseColor(j['surface']) ?? d.surface,
      danger: parseColor(j['danger']) ?? d.danger,
      online: parseColor(j['online']) ?? d.online,
      textColor: parseColor(j['text']),
      radius: n('radius', d.radius).clamp(0, 40).toDouble(),
      blur: n('blur', d.blur).clamp(0, 60).toDouble(),
      panelOpacity: n('panelOpacity', d.panelOpacity).clamp(0, 1).toDouble(),
      fontScale: n('fontScale', 1).clamp(.7, 1.8).toDouble(),
      animatedBackground: b('animated', true),
      reduceMotion: b('reduceMotion', false),
      compact: b('compact', false),
      speakingGlow: b('speakingGlow', true),
      hoverAnimations: b('hoverAnimations', true),
      fontFamily: (j['font'] as String?) ?? '',
      backgroundKind: BackgroundKind.values.asNameMap()[j['bg']] ?? BackgroundKind.aurora,
      gradient: ((j['gradient'] as List?)?.map(parseColor).whereType<Color>().toList() ?? d.gradient).length >= 2
          ? (j['gradient'] as List).map(parseColor).whereType<Color>().toList()
          : d.gradient,
      backgroundOpacity: n('bgOpacity', 1).clamp(0, 1).toDouble(),
      backgroundBlur: n('bgBlur', 0).clamp(0, 60).toDouble(),
      backgroundFit: (j['bgFit'] as String?) ?? 'cover',
      messageStyle: MessageStyle.values.asNameMap()[j['messages']] ?? MessageStyle.flat,
      packId: j['pack'] as String?,
      backgroundFile: j['bgFile'] as String?,
      fontFiles: ((j['fontFiles'] as List?) ?? const []).whereType<String>().toList(),
      backgroundImage: j['bgFile'] as String?,
    );
  }
}

class Preset {
  final String name;
  final ThemeSettings settings;
  Preset(this.name, this.settings);
}

ThemeSettings _p(String name, String accent, String secondary, String bg, String surface, {bool anim = true, BackgroundKind kind = BackgroundKind.aurora}) => ThemeSettings(
      name: name,
      accent: parseColor(accent)!,
      secondary: parseColor(secondary)!,
      background: parseColor(bg)!,
      surface: parseColor(surface)!,
      animatedBackground: anim,
      backgroundKind: kind,
    );

final presets = <Preset>[
  Preset('Nyx', ThemeSettings()),
  Preset('Ember', _p('Ember', '#FF7A59', '#FFC857', '#120B0A', '#1E1412')),
  Preset('Ocean', _p('Ocean', '#3FA7FF', '#42E8B4', '#07111A', '#0E1C29')),
  Preset('Rose', _p('Rose', '#FF5FA2', '#B07CFF', '#14090F', '#211019')),
  Preset('Forest', _p('Forest', '#5BD67A', '#C8E86B', '#08120C', '#101C14')),
  Preset('Midnight', _p('Midnight', '#7C9CFF', '#FF7CD6', '#000000', '#0B0B10', kind: BackgroundKind.solid)),
  Preset('Paper', _p('Paper', '#5B5BD6', '#3AA6A0', '#F4F2EE', '#FFFFFF', anim: false)),
];

class ThemeController extends ChangeNotifier {
  ThemeSettings settings = ThemeSettings();
  static const _key = 'theme_v2';
  final packs = ThemePacks();

  Future<void> load() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_key);
      if (s != null) settings = ThemeSettings.fromJson(jsonDecode(s));
      await _hydrate();
    } catch (_) {}
    notifyListeners();
  }

  /// Re-reads the files a theme pack brought (background picture, fonts) after a restart.
  Future<void> _hydrate() async {
    final id = settings.packId;
    if (id == null) return;
    final files = await packs.store.read(id);
    settings.assets = {for (final e in files.entries) e.key: e.value};
    if (settings.backgroundFile != null && !files.containsKey(settings.backgroundFile)) {
      settings.backgroundImage = null;
    }
    await packs.loadFonts(id, settings.fontFiles, files);
    if (settings.fontFiles.isNotEmpty) settings.fontFamily = packs.fontFamily(id);
  }

  Future<void> applyPack(PackData d) async {
    settings = d.settings;
    await packs.loadFonts(d.id, settings.fontFiles, d.files);
    notifyListeners();
    await _save();
  }

  /// A picture the user chose in Appearance: kept on this device like a pack of its own.
  Future<void> setLocalBackground(String name, Uint8List bytes) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'png';
    final file = 'background.$ext';
    await packs.store.write('_local', {file: bytes});
    settings
      ..packId = '_local'
      ..backgroundFile = file
      ..backgroundImage = file
      ..assets = {file: bytes}
      ..backgroundKind = BackgroundKind.image;
    notifyListeners();
    await _save();
  }

  Future<void> update(void Function(ThemeSettings) change) async {
    change(settings);
    notifyListeners();
    await _save();
  }

  Future<void> replace(ThemeSettings s) async {
    settings = s;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(settings.toJson()));
    } catch (_) {}
  }

  ThemeData build() {
    final s = settings;
    final brightness = s.isLight ? Brightness.light : Brightness.dark;
    final base = ColorScheme.fromSeed(seedColor: s.accent, brightness: brightness, surface: s.surface);
    final scheme = base.copyWith(
      primary: s.accent,
      secondary: s.secondary,
      surface: s.surface,
      error: s.danger,
      onSurface: s.textColor ?? base.onSurface,
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(s.radius));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: s.background,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      visualDensity: s.compact ? VisualDensity.compact : VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: scheme.onSurface.withValues(alpha: .08),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: s.isLight ? const Color(0xE6202020) : const Color(0xE6000000), borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.onSurface.withValues(alpha: .06),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(s.radius * .75), borderSide: BorderSide.none),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape, minimumSize: const Size(0, 44))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape, minimumSize: const Size(0, 44))),
      cardTheme: CardThemeData(shape: shape, color: s.surface, elevation: 0),
      dialogTheme: DialogThemeData(shape: shape, backgroundColor: s.surface),
      popupMenuTheme: PopupMenuThemeData(shape: shape, color: s.surface, surfaceTintColor: Colors.transparent, elevation: 8),
      scrollbarTheme: ScrollbarThemeData(thickness: WidgetStatePropertyAll(s.compact ? 4 : 6), radius: const Radius.circular(8)),
    );
  }
}

/// Makes the theme available to every widget without passing it around.
class NyxTheme extends InheritedNotifier<ThemeController> {
  const NyxTheme({super.key, required ThemeController controller, required super.child}) : super(notifier: controller);

  static ThemeController controllerOf(BuildContext c) => c.dependOnInheritedWidgetOfExactType<NyxTheme>()!.notifier!;
  static ThemeSettings of(BuildContext c) => controllerOf(c).settings;
}
