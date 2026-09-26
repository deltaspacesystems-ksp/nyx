import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/files.dart';
import '../core/gifs.dart';
import '../core/models.dart';
import 'common.dart';

/// GIF tab: my saved GIFs first, then Klipy trending / search results (when the server has a Klipy key).
class GifTab extends StatefulWidget {
  final String channelId;
  final VoidCallback onSent;
  const GifTab({super.key, required this.channelId, required this.onSent});

  @override
  State<GifTab> createState() => _GifTabState();
}

class _Hit {
  final String id, preview, full;
  final int w, h;
  _Hit(this.id, this.preview, this.full, this.w, this.h);
}

class _GifTabState extends State<GifTab> {
  final search = TextEditingController();
  Timer? _debounce;
  bool? enabled;
  bool loading = false;
  String? error;
  List<_Hit> hits = [];
  String query = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final app = context.appRead;
    try {
      enabled = (await app.api.get('/api/gifs/status'))['enabled'] == true;
    } catch (_) {
      enabled = false;
    }
    if (!mounted) return;
    setState(() {});
    if (enabled == true) _load('');
  }

  Future<void> _load(String q) async {
    final app = context.appRead;
    setState(() {
      loading = true;
      error = null;
      query = q;
    });
    try {
      final r = await app.api.get(q.isEmpty ? '/api/gifs/trending' : '/api/gifs/search', q.isEmpty ? null : {'q': q}) as Map;
      final list = [for (final x in (r['results'] as List)) _Hit(x['id'] as String, x['preview'] as String, x['full'] as String, (x['w'] as num?)?.toInt() ?? 0, (x['h'] as num?)?.toInt() ?? 0)];
      if (mounted && query == q) setState(() => hits = list);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _sendSaved(BlobRef r) async {
    final app = context.appRead;
    Navigator.pop(context);
    try {
      await app.sendRefs(widget.channelId, [r]);
    } catch (e) {
      app.toast('$e');
    }
    widget.onSent();
  }

  Future<void> _sendHit(_Hit h, {bool saveOnly = false}) async {
    final app = context.appRead;
    if (!saveOnly) Navigator.pop(context);
    try {
      final bytes = await app.api.getBytes('/api/gifs/media/${h.full}');
      if (saveOnly) {
        await app.saveGifBytes(bytes, 'gif-${h.id}.gif');
        app.toast('GIF saved.');
      } else {
        await app.sendMessage(widget.channelId, '', files: [PickedFile.bytes('gif-${h.id}.gif', bytes, mime: 'image/gif')]);
      }
    } catch (e) {
      app.toast('$e');
    }
    if (!saveOnly) widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    final saved = GifLibrary.instance;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        child: TextField(
          controller: search,
          enabled: enabled == true,
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 400), () => _load(v.trim()));
          },
          decoration: InputDecoration(hintText: enabled == false ? 'GIF search is not set up on this server' : 'Search GIFs', isDense: true, prefixIcon: const Icon(Icons.search, size: 18)),
        ),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: saved,
          builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), children: [
            if (saved.items.isNotEmpty && query.isEmpty) ...[
              _title(context, 'Saved'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in saved.items)
                  _Thumb(
                    child: BlobImage(blob: r, width: 96, height: 72, fit: BoxFit.cover, hoverToPlay: false),
                    onTap: () => _sendSaved(r),
                    action: Icons.close_rounded,
                    actionTip: 'Remove from saved',
                    onAction: () => saved.remove(r.id),
                  ),
              ]),
            ],
            if (enabled == true) ...[
              _title(context, query.isEmpty ? 'Trending' : 'Results'),
              if (error != null) Text(error!, style: TextStyle(color: context.nyx.danger)),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final h in hits)
                  _Thumb(
                    child: _Preview(token: h.preview),
                    onTap: () => _sendHit(h),
                    action: Icons.star_outline_rounded,
                    actionTip: 'Save GIF',
                    onAction: () => _sendHit(h, saveOnly: true),
                  ),
              ]),
              if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              if (!loading && hits.isEmpty && error == null) Padding(padding: const EdgeInsets.all(16), child: Text('Nothing found.', textAlign: TextAlign.center, style: TextStyle(color: context.faint))),
            ] else if (saved.items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text('No saved GIFs yet.\nUpload a GIF or use “Save GIF” in a message’s menu to keep it here.', textAlign: TextAlign.center, style: TextStyle(color: context.faint)),
              ),
          ]),
        ),
      ),
    ]);
  }

  Widget _title(BuildContext context, String t) => Padding(padding: const EdgeInsets.fromLTRB(2, 8, 2, 4), child: Text(t.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: .8, fontWeight: FontWeight.w800, color: context.muted)));
}

class _Thumb extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap, onAction;
  final IconData action;
  final String actionTip;
  const _Thumb({required this.child, required this.onTap, required this.action, required this.actionTip, required this.onAction});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 96,
        height: 72,
        child: Stack(children: [
          Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child)),
          Positioned.fill(child: Material(type: MaterialType.transparency, child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap))),
          Positioned(
            top: 2,
            right: 2,
            child: Tooltip(
              message: actionTip,
              child: InkWell(onTap: onAction, child: Container(padding: const EdgeInsets.all(2), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: Icon(action, size: 14, color: Colors.white))),
            ),
          ),
        ]),
      );
}

/// A small search result, fetched through the Nyx server.
class _Preview extends StatefulWidget {
  final String token;
  const _Preview({required this.token});

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  static final _cache = <String, Uint8List>{};
  Uint8List? bytes;

  @override
  void initState() {
    super.initState();
    final hit = _cache[widget.token];
    if (hit != null) {
      bytes = hit;
    } else {
      context.appRead.api.getBytes('/api/gifs/media/${widget.token}').then((b) {
        if (_cache.length > 300) _cache.remove(_cache.keys.first);
        _cache[widget.token] = b;
        if (mounted) setState(() => bytes = b);
      }).catchError((_) => null);
    }
  }

  @override
  Widget build(BuildContext context) => bytes == null
      ? ColoredBox(color: context.cs.onSurface.withValues(alpha: .08))
      : Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true);
}

/// Sticker tab: the stickers of the server this channel belongs to.
class StickerTab extends StatelessWidget {
  final GuildModel? guild;
  final String channelId;
  final VoidCallback onSent;
  const StickerTab({super.key, required this.guild, required this.channelId, required this.onSent});

  @override
  Widget build(BuildContext context) {
    final stickers = guild?.assets.values.where((a) => a.kind == 'sticker' && a.ref != null).toList() ?? const <AssetModel>[];
    if (stickers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(guild == null ? 'Stickers belong to servers, so they are not available in direct messages.' : 'This server has no stickers yet.\nAdd some in Server settings → Stickers.', textAlign: TextAlign.center, style: TextStyle(color: context.faint)),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in stickers)
          Tooltip(
            message: a.name,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () async {
                final app = context.appRead;
                Navigator.pop(context);
                try {
                  await app.sendRefs(channelId, [a.ref!], sticker: true);
                } catch (e) {
                  app.toast('$e');
                }
                onSent();
              },
              child: Padding(padding: const EdgeInsets.all(4), child: BlobImage(blob: a.ref, width: 88, height: 88, fit: BoxFit.contain)),
            ),
          ),
      ]),
    ]);
  }
}
