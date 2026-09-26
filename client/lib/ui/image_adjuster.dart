import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'common.dart';
import 'dialogs.dart';

class ImageAdjust {
  final double zoom, cx, cy;
  const ImageAdjust(this.zoom, this.cx, this.cy);
  static const none = ImageAdjust(1, .5, .5);
}

/// Lets the person move and zoom a picture inside the frame it will be shown in (round avatar, wide banner...).
/// Nothing is re-encoded: the original file is kept as is and only these three numbers are stored, so
/// quality and GIF/WebP animation are untouched and the crop can be changed again later.
Future<ImageAdjust?> showImageAdjuster(
  BuildContext context, {
  required Uint8List bytes,
  required String cacheId,
  required double aspect,
  bool circle = false,
  ImageAdjust initial = ImageAdjust.none,
  String title = 'Adjust picture',
}) =>
    showDialog<ImageAdjust>(
      context: context,
      builder: (c) => _Adjuster(bytes: bytes, cacheId: cacheId, aspect: aspect, circle: circle, initial: initial, title: title),
    );

class _Adjuster extends StatefulWidget {
  final Uint8List bytes;
  final String cacheId, title;
  final double aspect;
  final bool circle;
  final ImageAdjust initial;
  const _Adjuster({required this.bytes, required this.cacheId, required this.aspect, required this.circle, required this.initial, required this.title});

  @override
  State<_Adjuster> createState() => _AdjusterState();
}

class _AdjusterState extends State<_Adjuster> {
  late double zoom = widget.initial.zoom, cx = widget.initial.cx, cy = widget.initial.cy;
  double _baseZoom = 1;
  Size? size;

  @override
  void initState() {
    super.initState();
    ImageSizes.of(widget.cacheId, widget.bytes).then((s) => mounted ? setState(() => size = s) : null);
  }

  void _pan(double dx, double dy, double w, double h) {
    final s = size;
    if (s == null) return;
    final g = cropGeometry(s, w, h, zoom, cx, cy);
    setState(() {
      cx = (cx - dx / g.width).clamp(0, 1).toDouble();
      cy = (cy - dy / g.height).clamp(0, 1).toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxW = (MediaQuery.sizeOf(context).width - 96).clamp(200, 440).toDouble();
    final w = widget.circle || widget.aspect <= 1.2 ? (maxW * .75).clamp(200, 320).toDouble() : maxW;
    final h = w / widget.aspect;
    final s = size;
    Widget frame;
    if (s == null) {
      frame = const Center(child: CircularProgressIndicator());
    } else {
      final g = cropGeometry(s, w, h, zoom, cx, cy);
      frame = Stack(children: [
        Positioned(left: g.left, top: g.top, width: g.width, height: g.height, child: Image.memory(widget.bytes, fit: BoxFit.fill, filterQuality: FilterQuality.high, gaplessPlayback: true)),
      ]);
    }
    return NyxDialog(
      title: widget.title,
      subtitle: 'Drag to move, scroll or use the slider to zoom. The original picture is kept in full quality.',
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) setState(() => zoom = (zoom * (e.scrollDelta.dy < 0 ? 1.08 : 1 / 1.08)).clamp(1, 8).toDouble());
            },
            child: GestureDetector(
              onScaleStart: (_) => _baseZoom = zoom,
              onScaleUpdate: (d) {
                setState(() => zoom = (_baseZoom * d.scale).clamp(1, 8).toDouble());
                _pan(d.focalPointDelta.dx, d.focalPointDelta.dy, w, h);
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: widget.circle ? null : BorderRadius.circular(context.nyx.radius * .6),
                    border: Border.all(color: context.cs.primary, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: frame,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Icon(Icons.zoom_out_rounded, size: 18),
            Expanded(child: Slider(value: zoom.clamp(1, 4), min: 1, max: 4, onChanged: (v) => setState(() => zoom = v))),
            const Icon(Icons.zoom_in_rounded, size: 18),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => setState(() {
              zoom = 1;
              cx = cy = .5;
            }), child: const Text('Reset')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: s == null ? null : () => Navigator.pop(context, ImageAdjust(zoom, cx, cy)), child: const Text('Apply')),
      ],
    );
  }
}
