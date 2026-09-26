import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/app_state.dart';
import '../voice/voice_controller.dart';
import 'common.dart';

/// Microphone / speaker / camera pickers, used in settings and in the call's device dialog.
class DevicePanel extends StatefulWidget {
  const DevicePanel({super.key});

  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  Map<String, List<MediaDeviceInfo>>? devices;
  bool asked = false;

  VoiceController get call => context.appRead.voice;

  @override
  void initState() {
    super.initState();
    call.loadPrefs().then((_) => _refresh());
  }

  Future<void> _refresh() async {
    final d = await call.devices();
    if (mounted) setState(() => devices = d);
  }

  /// Device names are hidden by browsers and OSes until a stream was opened once.
  Future<void> _allowLabels() async {
    setState(() => asked = true);
    try {
      final s = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
      for (final t in s.getTracks()) {
        await t.stop();
      }
      await s.dispose();
    } catch (_) {}
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final d = devices;
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        if (d == null) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        final unnamed = [...d['mics']!, ...d['outs']!, ...d['cams']!].any((x) => x.label.isEmpty);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (unnamed && !asked) Padding(padding: const EdgeInsets.only(bottom: 8), child: TextButton.icon(icon: const Icon(Icons.mic_rounded), label: const Text('Allow access to show device names'), onPressed: _allowLabels)),
          _pick(context, 'Microphone', Icons.mic_rounded, d['mics']!, call.micId, call.setMic),
          _pick(context, 'Speakers / headphones', Icons.headphones_rounded, d['outs']!, call.outId, call.setOutput, note: d['outs']!.isEmpty ? 'Your system does not let Nyx choose the output here; it uses the default one.' : null),
          _pick(context, 'Camera', Icons.videocam_rounded, d['cams']!, call.camId, call.setCameraDevice),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Refresh devices'), onPressed: _refresh)),
        ]);
      },
    );
  }

  Widget _pick(BuildContext context, String title, IconData icon, List<MediaDeviceInfo> list, String? current, Future<void> Function(String?) onPick, {String? note}) {
    final known = list.any((x) => x.deviceId == current);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, size: 16, color: context.muted), const SizedBox(width: 6), Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: context.muted))]),
        const SizedBox(height: 6),
        if (list.isEmpty)
          Text(note ?? 'No device found.', style: TextStyle(color: context.faint, fontSize: 13))
        else
          DropdownButtonFormField<String?>(
            initialValue: known ? current : null,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('System default')),
              for (final x in list) DropdownMenuItem<String?>(value: x.deviceId, child: Text(x.label.isEmpty ? 'Device ${list.indexOf(x) + 1}' : x.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => onPick(v),
          ),
      ]),
    );
  }
}

Future<void> showDeviceDialog(BuildContext context) => showDialog(
      context: context,
      builder: (c) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Audio & video devices', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                const DevicePanel(),
                Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))),
              ]),
            ),
          ),
        ),
      ),
    );
