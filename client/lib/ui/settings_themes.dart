import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/nyx_theme.dart';
import '../theme/pack_store.dart';
import '../theme/theme_packs.dart';
import 'common.dart';
import 'settings_common.dart';

/// Install, switch, export and write theme packs. A pack is data only (colours, pictures, fonts): it can
/// restyle everything but can never run code.
class ThemePacksTab extends StatefulWidget {
  const ThemePacksTab({super.key});

  @override
  State<ThemePacksTab> createState() => _ThemePacksTabState();
}

class _ThemePacksTabState extends State<ThemePacksTab> {
  late Future<List<PackInfo>> installed;
  String? error, folder;

  ThemeController get tc => NyxTheme.controllerOf(context);

  @override
  void initState() {
    super.initState();
    installed = ThemePacks().list();
    ThemePacks().store.folderPath().then((p) => mounted ? setState(() => folder = p) : null);
  }

  void _reload() => setState(() => installed = tc.packs.list());

  Future<void> _install(PackData d, {bool apply = true}) async {
    await tc.packs.install(d);
    if (apply) await tc.applyPack(d);
    _reload();
  }

  Future<void> _importFile() async {
    setState(() => error = null);
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    try {
      final f = files.first;
      final d = tc.packs.importZip(await f.readAsBytes(), fallbackName: f.name.split('.').first);
      await _install(d);
      if (mounted) context.appRead.toast('Installed “${d.settings.name}”.');
    } on PackFormatException catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = 'Could not read that file: $e');
    }
  }

  Future<void> _importFolder() async {
    setState(() => error = null);
    final path = await FilePicker.getDirectoryPath();
    if (path == null) return;
    try {
      final d = await tc.packs.importFolder(path);
      await _install(d);
    } on PackFormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  Future<void> _export() async {
    final s = tc.settings;
    final bytes = tc.packs.exportZip(s);
    await FilePicker.saveFile(fileName: '${ThemePacks.idFrom(s.name)}.nyxtheme', bytes: Uint8List.fromList(bytes), mimeType: 'application/zip');
  }

  Future<void> _useInstalled(PackInfo p) async {
    final d = await tc.packs.read(p.id);
    if (d == null) return setState(() => error = 'That theme could not be read any more.');
    await tc.applyPack(d);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = tc.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageTitle('Theme packs'),
      Text('A theme pack restyles the whole app: colours, shapes, background picture (animated GIF / WebP welcome) and fonts. Packs are plain data files, so they cannot run code.', style: TextStyle(color: context.muted)),
      const SectionTitle('Installed'),
      FutureBuilder(
        future: installed,
        builder: (c, snap) {
          final list = snap.data ?? const <PackInfo>[];
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
          if (list.isEmpty) return Text('No theme packs installed yet.', style: TextStyle(color: c.muted));
          return Column(children: [
            for (final p in list)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: _Swatch(p),
                  title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([if (p.author.isNotEmpty) 'by ${p.author}', if (p.hasBackground) 'picture', if (p.hasFont) 'font'].join(' · ')),
                  selected: current.packId == p.id,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (current.packId == p.id) Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.check_circle_rounded, color: c.cs.primary)) else TextButton(onPressed: () => _useInstalled(p), child: const Text('Use')),
                    IconButton(icon: Icon(Icons.delete_outline_rounded, color: c.nyx.danger), tooltip: 'Remove', onPressed: () async {
                      await tc.packs.delete(p.id);
                      _reload();
                    }),
                  ]),
                ),
              ),
          ]);
        },
      ),
      if (error != null) InfoBox(Icons.error_outline_rounded, error!, color: context.nyx.danger),
      const SectionTitle('Add a theme'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(icon: const Icon(Icons.file_open_rounded, size: 18), label: const Text('Import .nyxtheme / .zip'), onPressed: _importFile),
        if (PackStore.supportsFolder) OutlinedButton.icon(icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('Import a folder'), onPressed: _importFolder),
        OutlinedButton.icon(icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('Export current look'), onPressed: _export),
      ]),
      if (folder != null) ...[
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.folder_rounded, size: 18, color: context.muted),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(folder!, style: TextStyle(fontSize: 12, color: context.muted))),
          TextButton(onPressed: () => launchUrl(Uri.file(folder!)), child: const Text('Open')),
        ]),
        Text('Drop a theme folder in there and reopen this page to install it by hand.', style: TextStyle(fontSize: 12, color: context.faint)),
      ],
      const SectionTitle('Make your own', sub: 'Create a folder with a theme.json (and optional background picture / fonts), zip it and import it.'),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: context.cs.onSurface.withValues(alpha: .06), borderRadius: BorderRadius.circular(12)),
        child: SelectableText(ThemePacks.template, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35)),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.copy_rounded, size: 18), label: const Text('Copy template'), onPressed: () => Clipboard.setData(const ClipboardData(text: ThemePacks.template))),
      ]),
      const InfoBox(Icons.lightbulb_outline_rounded, 'Colours are "#RRGGBB". background.type can be aurora, solid, gradient or image. Pictures may be png, jpg, gif or webp (animated ones loop). Fonts are .ttf / .otf listed in typography.files. Limits: 25 MB per file, 60 MB per theme.'),
    ]);
  }
}

class _Swatch extends StatelessWidget {
  final PackInfo p;
  const _Swatch(this.p);

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: p.background)),
            Positioned(left: 4, top: 4, right: 4, height: 18, child: DecoratedBox(decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(4)))),
            Positioned(left: 4, bottom: 4, width: 18, height: 16, child: DecoratedBox(decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(4)))),
            Positioned(right: 4, bottom: 4, width: 18, height: 16, child: DecoratedBox(decoration: BoxDecoration(color: p.secondary, borderRadius: BorderRadius.circular(4)))),
          ]),
        ),
      );
}
