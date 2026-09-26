import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../core/files.dart';
import 'common.dart';

/// Decrypts an attachment on this device and hands it to a player. Nothing plaintext ever leaves the device.
Future<Media> _openMedia(BuildContext context, BlobRef f) async {
  final bytes = await context.appRead.media.load(f);
  if (kIsWeb) return Media(Uri.dataFromBytes(bytes, mimeType: f.mime).toString());
  final dir = await getTemporaryDirectory();
  final safe = f.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final file = File('${dir.path}/nyx-play-${f.id.substring(0, 8)}-$safe');
  if (!await file.exists() || await file.length() != bytes.length) await file.writeAsBytes(bytes, flush: true);
  return Media(file.path);
}

String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

/// Inline video: a poster with a play button; the file is only fetched and decrypted when it is pressed.
class VideoAttachment extends StatefulWidget {
  final BlobRef file;
  const VideoAttachment({super.key, required this.file});

  @override
  State<VideoAttachment> createState() => _VideoAttachmentState();
}

class _VideoAttachmentState extends State<VideoAttachment> {
  Player? player;
  VideoController? controller;
  bool loading = false;
  String? err;

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final media = await _openMedia(context, widget.file);
      final p = Player();
      final c = VideoController(p);
      await p.open(media);
      if (!mounted) {
        p.dispose();
        return;
      }
      setState(() {
        player = p;
        controller = c;
      });
    } catch (e) {
      err = 'Could not decrypt or play this video.';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: controller != null
              ? Video(controller: controller!, controls: AdaptiveVideoControls)
              : Container(
                  color: Colors.black87,
                  child: Stack(alignment: Alignment.center, children: [
                    Positioned(left: 12, bottom: 10, right: 12, child: Text('${f.name.isEmpty ? 'video' : f.name} · ${fmtSize(f.size)}${err != null ? '\n$err' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: err != null ? Colors.redAccent : Colors.white70, fontSize: 12))),
                    loading
                        ? const CircularProgressIndicator(strokeWidth: 2.5)
                        : IconButton.filled(iconSize: 34, icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Decrypt & play', onPressed: _start),
                  ]),
                ),
        ),
      ),
    );
  }
}

/// Inline audio: play/pause, a seek bar and the time.
class AudioAttachment extends StatefulWidget {
  final BlobRef file;
  const AudioAttachment({super.key, required this.file});

  @override
  State<AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<AudioAttachment> {
  Player? player;
  bool loading = false, playing = false;
  Duration pos = Duration.zero, total = Duration.zero;
  String? err;

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (player != null) return player!.playOrPause();
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final media = await _openMedia(context, widget.file);
      final p = Player();
      p.stream.playing.listen((v) => mounted ? setState(() => playing = v) : null);
      p.stream.position.listen((v) => mounted ? setState(() => pos = v) : null);
      p.stream.duration.listen((v) => mounted ? setState(() => total = v) : null);
      await p.open(media);
      player = p;
    } catch (e) {
      err = 'Could not decrypt or play this audio.';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final max = total.inMilliseconds.toDouble();
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
      decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .07), borderRadius: BorderRadius.circular(12), border: Border.all(color: context.cs.onSurface.withValues(alpha: .06))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        loading
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton.filled(icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded), tooltip: playing ? 'Pause' : 'Decrypt & play', onPressed: _toggle),
        const SizedBox(width: 8),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.name.isEmpty ? 'audio' : f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (err != null)
              Text(err!, style: TextStyle(fontSize: 12, color: context.nyx.danger))
            else if (player == null)
              Text('${fmtSize(f.size)} · encrypted', style: TextStyle(fontSize: 12, color: context.muted))
            else ...[
              SizedBox(
                height: 22,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(value: pos.inMilliseconds.toDouble().clamp(0, max <= 0 ? 1 : max), max: max <= 0 ? 1 : max, onChanged: (v) => player!.seek(Duration(milliseconds: v.round()))),
                ),
              ),
              Text('${_clock(pos)} / ${_clock(total)}', style: TextStyle(fontSize: 11.5, color: context.muted, fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ]),
        ),
      ]),
    );
  }
}
