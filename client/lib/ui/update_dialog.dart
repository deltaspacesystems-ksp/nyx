import 'package:flutter/material.dart';

import '../core/updater.dart';
import 'common.dart';
import 'dialogs.dart';

/// Checks once and, when a newer build exists, asks whether to install it (with the list of what changed).
Future<void> checkForUpdates(BuildContext context, {bool manual = false}) async {
  final app = context.appRead;
  final info = await Updater.check(app.api, ignoreSkip: manual);
  if (!context.mounted) return;
  if (info == null) {
    if (manual) app.toast('Nyx is up to date.');
    return;
  }
  await showDialog(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(info: info));
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? progress;
  String? error;
  bool installing = false;

  Future<void> _install() async {
    final app = context.appRead;
    if (!Updater.canSelfInstall) {
      await Updater.openDownloadPage(app.api);
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() {
      progress = 0;
      error = null;
    });
    try {
      final path = await Updater.download(app.api, widget.info, (p) => mounted ? setState(() => progress = p) : null);
      if (!mounted) return;
      setState(() => installing = true);
      await Updater.installAndRestart(path);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          progress = null;
          installing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final busy = progress != null || installing;
    return NyxDialog(
      title: 'Update available',
      subtitle: 'Nyx ${i.version} is ready (${fmtSize(i.size)}). Your messages and keys stay on this device as they are.',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final c in i.changelog) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text('What is new in ${c.version}${c.released == null ? '' : '  ·  ${c.released}'}', style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              if (c.notes.isEmpty) Text('Improvements and fixes.', style: TextStyle(color: context.muted)),
              for (final n in c.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(padding: const EdgeInsets.only(top: 6, right: 8), child: Icon(Icons.circle, size: 6, color: context.cs.primary)),
                    Expanded(child: Text(n)),
                  ]),
                ),
            ],
            if (busy) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: installing ? null : progress),
              const SizedBox(height: 6),
              Text(installing ? 'Installing, Nyx will restart...' : 'Downloading ${((progress ?? 0) * 100).round()}%', style: TextStyle(fontSize: 12, color: context.muted)),
            ],
            if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: context.nyx.danger))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Later')),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  await Updater.skip(i);
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Skip this version'),
        ),
        FilledButton(onPressed: busy ? null : _install, child: Text(Updater.canSelfInstall ? 'Update now' : 'Open download page')),
      ],
    );
  }
}
