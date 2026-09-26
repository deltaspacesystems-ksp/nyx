import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/files.dart';
import '../theme/nyx_theme.dart';
import 'common.dart';
import 'image_adjuster.dart';

class SettingsTab {
  final IconData icon;
  final String title;
  final WidgetBuilder builder;
  final bool danger;
  const SettingsTab(this.icon, this.title, this.builder, {this.danger = false});
}

/// Full-window settings with a tab list on the left (a drop-down on narrow screens).
class SettingsFrame extends StatefulWidget {
  final String title;
  final List<SettingsTab> tabs;
  final int initial;
  const SettingsFrame({super.key, required this.title, required this.tabs, this.initial = 0});

  @override
  State<SettingsFrame> createState() => _SettingsFrameState();
}

class _SettingsFrameState extends State<SettingsFrame> {
  late int index = widget.initial.clamp(0, widget.tabs.length - 1);

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final size = MediaQuery.sizeOf(context);
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: KeyedSubtree(key: ValueKey(index), child: SingleChildScrollView(padding: EdgeInsets.all(narrow ? 16 : 28), child: Align(alignment: Alignment.topLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: widget.tabs[index].builder(context))))),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(narrow ? 6 : 24),
      child: Pop(
        child: SizedBox(
          width: 1000,
          height: size.height * .92,
          child: Glass(
            opacity: dialogOpacity(context),
            child: narrow
                ? Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                      child: Row(children: [
                        Expanded(child: DropdownButton<int>(value: index, isExpanded: true, underline: const SizedBox.shrink(), items: [for (final (i, t) in widget.tabs.indexed) DropdownMenuItem(value: i, child: Row(children: [Icon(t.icon, size: 18), const SizedBox(width: 10), Text(t.title)]))], onChanged: (v) => setState(() => index = v!))),
                        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(child: content),
                  ])
                : Row(children: [
                    SizedBox(
                      width: 230,
                      child: ListView(padding: const EdgeInsets.all(12), children: [
                        Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 14), child: Text(widget.title.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, letterSpacing: .9, fontWeight: FontWeight.w800, color: context.muted))),
                        for (final (i, t) in widget.tabs.indexed)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: ListTile(
                              dense: true,
                              selected: i == index,
                              selectedTileColor: context.cs.primary.withValues(alpha: .18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.nyx.radius * .55)),
                              leading: Icon(t.icon, size: 19, color: t.danger ? context.nyx.danger : null),
                              title: Text(t.title, style: TextStyle(fontWeight: i == index ? FontWeight.w700 : FontWeight.w500, color: t.danger ? context.nyx.danger : null)),
                              onTap: () => setState(() => index = i),
                            ),
                          ),
                      ]),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: Stack(children: [Positioned.fill(child: content), Positioned(top: 8, right: 8, child: IconButton.filledTonal(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => Navigator.pop(context)))])),
                  ]),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? sub;
  const SectionTitle(this.text, {super.key, this.sub});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          if (sub != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub!, style: TextStyle(color: context.muted, fontSize: 13))),
        ]),
      );
}

class PageTitle extends StatelessWidget {
  final String text;
  const PageTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(text, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)));
}

const kSwatches = [0xFF8B7CFF, 0xFF39D0C7, 0xFFFF5FA2, 0xFFFF7A59, 0xFFFFC857, 0xFF3FA7FF, 0xFF42E8B4, 0xFFB07CFF, 0xFFE94560, 0xFF7CFF6B, 0xFFFFFFFF, 0xFF99AAB5];

class ColorField extends StatelessWidget {
  final String label;
  final Color? value;
  final ValueChanged<Color?> onChanged;
  final bool allowNone;
  const ColorField({super.key, required this.label, required this.value, required this.onChanged, this.allowNone = false});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 12, bottom: 6), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (allowNone) _dot(context, null),
          for (final v in kSwatches) _dot(context, Color(v)),
          SizedBox(
            width: 108,
            child: TextField(
              key: ValueKey(value?.toARGB32()),
              controller: TextEditingController(text: value == null ? '' : hexOf(value!)),
              decoration: const InputDecoration(isDense: true, hintText: '#RRGGBB', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9)),
              onSubmitted: (s) {
                final c = parseColor(s);
                if (c != null) onChanged(c);
              },
            ),
          ),
        ]),
      ]);

  Widget _dot(BuildContext context, Color? c) {
    final selected = c == null ? value == null : value?.toARGB32() == c.toARGB32();
    return GestureDetector(
      onTap: () => onChanged(c),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: c ?? Colors.transparent, shape: BoxShape.circle, border: Border.all(color: selected ? context.cs.onSurface : context.faint.withValues(alpha: .4), width: selected ? 3 : 1)),
        child: c == null ? Icon(Icons.block_rounded, size: 16, color: context.muted) : null,
      ),
    );
  }
}

/// Lets the user pick a picture (GIF / animated WebP work), frame it ([aspect] / [circle]) and uploads the ORIGINAL
/// file encrypted; only the crop numbers are kept next to it, so nothing is re-compressed. An existing picture
/// can be re-framed without uploading again.
class ImageUploadField extends StatefulWidget {
  final String label, hint;
  final Widget Function(BuildContext) preview;
  final Future<void> Function(PickedFile file, ImageAdjust adjust) onPicked;
  final VoidCallback? onRemove;
  final int maxBytes;

  /// null = no crop step (emoji, theme backgrounds)
  final double? aspect;
  final bool circle;
  final BlobRef? current;
  final Future<void> Function(ImageAdjust adjust)? onAdjusted;
  const ImageUploadField({
    super.key,
    required this.label,
    required this.hint,
    required this.preview,
    required this.onPicked,
    this.onRemove,
    this.maxBytes = 12 * 1024 * 1024,
    this.aspect,
    this.circle = false,
    this.current,
    this.onAdjusted,
  });

  @override
  State<ImageUploadField> createState() => _ImageUploadFieldState();
}

class _ImageUploadFieldState extends State<ImageUploadField> {
  bool busy = false;
  String? error;

  Future<void> pick() async {
    setState(() => error = null);
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty || !mounted) return;
    final f = files.first;
    final size = await f.length() ?? 0;
    if (size > widget.maxBytes) {
      setState(() => error = 'That picture is ${fmtSize(size)}. The limit is ${fmtSize(widget.maxBytes)}.');
      return;
    }
    final data = await f.readAsBytes();
    var adjust = ImageAdjust.none;
    if (widget.aspect != null) {
      if (!mounted) return;
      final r = await showImageAdjuster(context, bytes: data, cacheId: 'pick-${f.name}-${data.length}', aspect: widget.aspect!, circle: widget.circle);
      if (r == null) return; // cancelled
      adjust = r;
    }
    setState(() => busy = true);
    try {
      await widget.onPicked(PickedFile.bytes(f.name, data, mime: guessMime(f.name)), adjust);
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> adjustExisting() async {
    final cur = widget.current;
    if (cur == null || widget.aspect == null || widget.onAdjusted == null) return;
    setState(() => error = null);
    try {
      final bytes = await context.appRead.media.load(cur);
      if (!mounted) return;
      final r = await showImageAdjuster(context, bytes: bytes, cacheId: cur.id, aspect: widget.aspect!, circle: widget.circle, initial: ImageAdjust(cur.zoom, cur.cx, cur.cy));
      if (r == null) return;
      setState(() => busy = true);
      await widget.onAdjusted!(r);
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 12, bottom: 6), child: Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          widget.preview(context),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_rounded, size: 18), label: const Text('Upload'), onPressed: busy ? null : pick),
                if (widget.current != null && widget.aspect != null && widget.onAdjusted != null) OutlinedButton.icon(icon: const Icon(Icons.crop_rounded, size: 18), label: const Text('Adjust'), onPressed: busy ? null : adjustExisting),
                if (widget.onRemove != null) OutlinedButton(onPressed: busy ? null : widget.onRemove, child: const Text('Remove')),
              ]),
              const SizedBox(height: 6),
              Text(error ?? widget.hint, style: TextStyle(fontSize: 12, color: error != null ? context.nyx.danger : context.muted)),
            ]),
          ),
        ]),
      ]);
}

class InfoBox extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const InfoBox(this.icon, this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: (color ?? context.cs.primary).withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 18, color: color ?? context.cs.primary), const SizedBox(width: 10), Expanded(child: Text(text, style: const TextStyle(fontSize: 13)))]),
      );
}
