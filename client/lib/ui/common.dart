import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/files.dart';
import '../core/models.dart';
import '../state/app_state.dart';
import '../theme/nyx_theme.dart';

/// Gives every widget the app state; rebuilds dependants whenever it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);
  static AppState of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext c) => (c.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}

/// Dialogs float above other panels, so they must be nearly solid: otherwise the panels behind them show
/// through and the text of both mixes. The theme's panel opacity only nudges it within a narrow band.
double dialogOpacity(BuildContext c) => (c.nyx.panelOpacity + .3).clamp(.9, .97).toDouble();

extension NyxContext on BuildContext {
  AppState get app => AppScope.of(this);
  AppState get appRead => AppScope.read(this);
  ThemeSettings get nyx => NyxTheme.of(this);
  ColorScheme get cs => Theme.of(this).colorScheme;
  Color get muted => cs.onSurface.withValues(alpha: .6);
  Color get faint => cs.onSurface.withValues(alpha: .38);

  /// A panel tinted a bit darker (>0) or lighter (<0) than the surface colour, for the layered depth
  /// between the server rail (darkest), the channel list and the chat itself (lightest) - the same visual
  /// hierarchy most chat apps use so the eye always knows which column it is in.
  Color depth(double amount) => Color.lerp(nyx.surface, nyx.isLight ? Colors.white : Colors.black, amount)!;
}

// ----------------------------------------------------------------------------- backgrounds

/// The window background, driven by the theme: drifting aurora, flat colour, gradient or an image.
class NyxBackground extends StatefulWidget {
  final Widget child;
  const NyxBackground({super.key, required this.child});

  @override
  State<NyxBackground> createState() => _NyxBackgroundState();
}

class _NyxBackgroundState extends State<NyxBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 40))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.nyx;
    final animate = t.animatedBackground && !t.reduceMotion;
    Widget bg;
    switch (t.backgroundKind) {
      case BackgroundKind.solid:
        bg = const SizedBox.expand();
      case BackgroundKind.gradient:
        bg = DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: t.gradient)),
          child: const SizedBox.expand(),
        );
      case BackgroundKind.image:
        final bytes = t.backgroundImage == null ? null : t.assets[t.backgroundImage];
        bg = bytes == null
            ? const SizedBox.expand()
            : ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: t.backgroundBlur, sigmaY: t.backgroundBlur, tileMode: TileMode.decal),
                child: Opacity(
                  opacity: t.backgroundOpacity,
                  child: Image.memory(bytes,
                      fit: switch (t.backgroundFit) { 'contain' => BoxFit.contain, 'tile' => BoxFit.none, _ => BoxFit.cover },
                      repeat: t.backgroundFit == 'tile' ? ImageRepeat.repeat : ImageRepeat.noRepeat,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true),
                ),
              );
      case BackgroundKind.aurora:
        bg = RepaintBoundary(
          child: animate
              ? AnimatedBuilder(animation: _c, builder: (_, _) => CustomPaint(painter: _AuroraPainter(t, _c.value), size: Size.infinite))
              : CustomPaint(painter: _AuroraPainter(t, .15), size: Size.infinite),
        );
    }
    return ColoredBox(
      color: t.background,
      child: Stack(fit: StackFit.expand, children: [bg, Material(type: MaterialType.transparency, child: widget.child)]),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final ThemeSettings t;
  final double v;
  _AuroraPainter(this.t, this.v);

  @override
  void paint(Canvas canvas, Size size) {
    final light = t.isLight;
    void blob(Color color, double phase, double r, double alpha) {
      final a = (v + phase) * 2 * math.pi;
      final c = Offset(size.width * (.5 + .38 * math.cos(a)), size.height * (.5 + .36 * math.sin(a * 1.3)));
      final radius = size.shortestSide * r;
      canvas.drawCircle(
          c,
          radius,
          Paint()
            ..shader = RadialGradient(colors: [color.withValues(alpha: light ? alpha * .5 : alpha), color.withValues(alpha: 0)])
                .createShader(Rect.fromCircle(center: c, radius: radius)));
    }

    blob(t.accent, 0, .8, .28);
    blob(t.secondary, .5, .7, .22);
    blob(t.accent, .25, .5, .14);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.v != v || old.t.accent != t.accent || old.t.secondary != t.secondary;
}

// ---------------------------------------------------------------------------------- surfaces

/// Frosted panel that follows the theme's radius / blur / opacity.
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? opacity;
  final BorderRadius? radius;
  final Color? tint;
  const Glass({super.key, required this.child, this.padding = EdgeInsets.zero, this.opacity, this.radius, this.tint});

  @override
  Widget build(BuildContext context) {
    final t = context.nyx;
    final r = radius ?? BorderRadius.circular(t.radius);
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: (tint ?? t.surface).withValues(alpha: opacity ?? t.panelOpacity),
        borderRadius: r,
        border: Border.all(color: (t.isLight ? Colors.black : Colors.white).withValues(alpha: t.isLight ? .06 : .06)),
      ),
      // Its own Material so list tiles / buttons inside can paint hover and ripple *above* the panel colour.
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (t.blur <= 0) return ClipRRect(borderRadius: r, child: panel);
    return ClipRRect(borderRadius: r, child: BackdropFilter(filter: ImageFilter.blur(sigmaX: t.blur, sigmaY: t.blur), child: panel));
  }
}

/// Slides + fades its child in once, staggered by [index].
class Pop extends StatelessWidget {
  final Widget child;
  final int index;
  const Pop({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) {
    if (context.nyx.reduceMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + math.min(index, 6) * 50),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 12), child: c)),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------------- images

/// Pixel size of an encoded image without decoding it (cheap), remembered per blob.
class ImageSizes {
  static final _cache = <String, Size>{};

  static Future<Size?> of(String id, Uint8List bytes) async {
    final hit = _cache[id];
    if (hit != null) return hit;
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      final d = await ui.ImageDescriptor.encoded(buf);
      final size = Size(d.width.toDouble(), d.height.toDouble());
      d.dispose();
      buf.dispose();
      return _cache[id] = size;
    } catch (_) {
      return null;
    }
  }
}

/// Where the picture goes inside a [w]x[h] frame for a given crop: "cover" first, then [zoom], centred on (cx, cy).
/// Used both here and by the crop editor so what you adjust is exactly what everyone sees.
({double left, double top, double width, double height}) cropGeometry(Size image, double w, double h, double zoom, double cx, double cy) {
  final s = math.max(w / image.width, h / image.height) * zoom;
  final dw = image.width * s, dh = image.height * s;
  double clamp(double c, double half) => half >= .5 ? .5 : c.clamp(half, 1 - half).toDouble();
  final x = clamp(cx, (w / 2) / dw), y = clamp(cy, (h / 2) / dh);
  return (left: w / 2 - x * dw, top: h / 2 - y * dh, width: dw, height: dh);
}

/// Shows an encrypted image blob (decrypting it on the fly). Animated GIF/WebP play; set [hoverToPlay]
/// to freeze them until the pointer is over them (lists of avatars) like Discord does. With [BoxFit.cover]
/// the picture always fills its frame and honours the crop stored in the [BlobRef].
class BlobImage extends StatefulWidget {
  final BlobRef? blob;
  final BoxFit fit;
  final double? width, height;
  final bool hoverToPlay;
  final Widget? fallback;
  const BlobImage({super.key, required this.blob, this.fit = BoxFit.cover, this.width, this.height, this.hoverToPlay = false, this.fallback});

  @override
  State<BlobImage> createState() => _BlobImageState();
}

class _Loaded {
  final Uint8List bytes;
  final Size? size;
  _Loaded(this.bytes, this.size);
}

class _BlobImageState extends State<BlobImage> {
  Future<_Loaded?>? _future;
  String? _id;
  bool _hover = false;

  void _resolve(BuildContext context) {
    final b = widget.blob;
    if (b?.id == _id) return;
    _id = b?.id;
    _future = b == null
        ? null
        : context.appRead.media.load(b).then<_Loaded?>((bytes) async => _Loaded(bytes, await ImageSizes.of(b.id, bytes)), onError: (_) => null);
  }

  @override
  Widget build(BuildContext context) {
    _resolve(context);
    final fb = widget.fallback ?? const SizedBox.shrink();
    if (_future == null) return fb;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return MouseRegion(
      onEnter: widget.hoverToPlay ? (_) => setState(() => _hover = true) : null,
      onExit: widget.hoverToPlay ? (_) => setState(() => _hover = false) : null,
      child: FutureBuilder<_Loaded?>(
        future: _future,
        builder: (context, snap) {
          final data = snap.data;
          final child = data == null ? fb : TickerMode(enabled: !widget.hoverToPlay || _hover, child: _picture(data, dpr, fb));
          return AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: KeyedSubtree(key: ValueKey(data != null), child: child));
        },
      ),
    );
  }

  Widget _picture(_Loaded d, double dpr, Widget fb) {
    final b = widget.blob!;
    if (widget.fit != BoxFit.cover) {
      return Image.memory(d.bytes, fit: widget.fit, width: widget.width, height: widget.height, filterQuality: FilterQuality.high, gaplessPlayback: true, errorBuilder: (_, _, _) => fb);
    }
    return LayoutBuilder(builder: (context, c) {
      final w = widget.width ?? (c.hasBoundedWidth ? c.maxWidth : 100);
      final h = widget.height ?? (c.hasBoundedHeight ? c.maxHeight : 100);
      final size = d.size;
      if (size == null) {
        return Image.memory(d.bytes, fit: BoxFit.cover, width: w, height: h, filterQuality: FilterQuality.high, gaplessPlayback: true, errorBuilder: (_, _, _) => fb);
      }
      final g = cropGeometry(size, w, h, b.zoom, b.cx, b.cy);
      // Decode a bit above the size it is drawn at, so it stays sharp when scaled.
      final decodeW = (g.width * dpr * 1.5).round().clamp(32, math.min(size.width.round(), 3000)).toInt();
      return ClipRect(
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(children: [
            Positioned(
              left: g.left,
              top: g.top,
              width: g.width,
              height: g.height,
              child: Image.memory(d.bytes, fit: BoxFit.fill, cacheWidth: decodeW, filterQuality: FilterQuality.high, gaplessPlayback: true, errorBuilder: (_, _, _) => fb),
            ),
          ]),
        ),
      );
    });
  }
}

Color _hueColor(String seed, {double l = .55}) {
  final hue = (seed.codeUnits.fold<int>(7, (a, b) => a * 31 + b).abs() % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, .6, l).toColor();
}

/// Coloured circle with initials, or the person's (possibly animated) avatar, plus an optional presence dot.
class UserAvatar extends StatelessWidget {
  final UserModel? user;
  final double size;
  final bool presence;
  final bool hoverToPlay;
  final String? fallbackName;
  const UserAvatar(this.user, {super.key, this.size = 40, this.presence = false, this.hoverToPlay = true, this.fallbackName});

  static Color presenceColor(BuildContext c, String p) => switch (p) {
        'online' => c.nyx.online,
        'idle' => const Color(0xFFF5A623),
        'dnd' => c.nyx.danger,
        _ => const Color(0xFF80848E),
      };

  @override
  Widget build(BuildContext context) {
    final name = user?.name ?? fallbackName ?? '?';
    final base = _hueColor(user?.id ?? name);
    final initials = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [base, HSLColor.fromColor(base).withHue((HSLColor.fromColor(base).hue + 40) % 360).withLightness(.42).toColor()]),
      ),
      child: Text(name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase(),
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * .42)),
    );
    final avatar = user?.profile.avatar;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: ClipOval(child: avatar == null ? initials : BlobImage(blob: avatar, width: size, height: size, hoverToPlay: hoverToPlay, fallback: initials))),
        if (presence && user != null)
          Positioned(
            right: -size * .04,
            bottom: -size * .04,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: size * .34,
              height: size * .34,
              decoration: BoxDecoration(shape: BoxShape.circle, color: presenceColor(context, user!.presence), border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: size * .05 + 1)),
            ),
          ),
      ]),
    );
  }
}

/// Server icon: the (animated) picture, or initials on a colour.
class GuildIcon extends StatelessWidget {
  final GuildModel guild;
  final double size;
  final bool hoverToPlay;
  const GuildIcon(this.guild, {super.key, this.size = 48, this.hoverToPlay = true});

  @override
  Widget build(BuildContext context) {
    final acr = guild.name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => String.fromCharCode(w.runes.first)).take(3).join().toUpperCase();
    final fallback = Container(
      alignment: Alignment.center,
      color: _hueColor(guild.id, l: .45),
      child: Text(acr.isEmpty ? '?' : acr, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * (acr.length > 2 ? .28 : .36))),
    );
    return SizedBox(
      width: size,
      height: size,
      child: guild.icon == null ? fallback : BlobImage(blob: guild.icon, width: size, height: size, hoverToPlay: hoverToPlay, fallback: fallback),
    );
  }
}

/// Profile / server banner: the picture (animated if it is) or a gradient from the accent colour.
class BannerImage extends StatelessWidget {
  final BlobRef? blob;
  final Color accent;
  final double height;
  const BannerImage({super.key, required this.blob, required this.accent, this.height = 100});

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent, HSLColor.fromColor(accent).withHue((HSLColor.fromColor(accent).hue + 50) % 360).toColor()])),
    );
    return SizedBox(height: height, width: double.infinity, child: blob == null ? fallback : BlobImage(blob: blob, fit: BoxFit.cover, height: height, fallback: fallback));
  }
}

class CountBadge extends StatelessWidget {
  final int count;
  const CountBadge(this.count, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        constraints: const BoxConstraints(minWidth: 18),
        decoration: BoxDecoration(color: context.nyx.danger, borderRadius: BorderRadius.circular(9)),
        child: Text(count > 99 ? '99+' : '$count', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

/// Small animated reveal used by lists and menus.
class Reveal extends StatelessWidget {
  final bool show;
  final Widget child;
  const Reveal({super.key, required this.show, required this.child});

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: context.nyx.reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: show ? child : const SizedBox(width: double.infinity),
      );
}

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String fmtTime(DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final d = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (d == today) return 'Today at $hm';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday at $hm';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year} $hm';
}
