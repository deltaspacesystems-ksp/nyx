import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'updater.dart';

bool get canSelfInstall => Platform.isWindows;

String? platformName() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  return null;
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<String> download(NyxApi api, UpdateInfo i, void Function(double) progress) async {
  await api.validToken();
  final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}nyx-update');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final out = File('${dir.path}${Platform.pathSeparator}${i.file}');

  final client = http.Client();
  try {
    final req = http.Request('GET', api.uri('/api/app/update/file', {'platform': i.platform, 'version': i.version}))..headers['Authorization'] = 'Bearer ${api.accessToken}';
    final res = await client.send(req);
    if (res.statusCode != 200) throw Exception('Download failed (${res.statusCode}).');
    final total = res.contentLength ?? i.size;
    final sink = out.openWrite();
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      progress(total == 0 ? 0 : (got / total).clamp(0, 1).toDouble());
    }
    await sink.close();
  } finally {
    client.close();
  }
  final hash = await Sha256().hash(await out.readAsBytes());
  if (_hex(hash.bytes) != i.sha256.toLowerCase()) {
    out.deleteSync();
    throw Exception('The downloaded update is damaged (checksum mismatch). Nothing was installed.');
  }
  return out.path;
}

Future<void> installAndRestart(String path) async {
  if (!Platform.isWindows) throw UnsupportedError('Self-install is only available on Windows.');
  final root = File(path).parent;
  final stage = Directory('${root.path}\\stage');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  await extractFileToDisk(path, stage.path);

  // The zip may hold the app directly or inside a single folder.
  var src = stage;
  if (!File('${src.path}\\nyx.exe').existsSync()) {
    final inner = stage.listSync().whereType<Directory>().where((d) => File('${d.path}\\nyx.exe').existsSync()).firstOrNull;
    if (inner == null) throw Exception('The update package does not contain nyx.exe.');
    src = inner;
  }

  final exe = Platform.resolvedExecutable;
  final dst = File(exe).parent.path;
  final script = File('${root.path}\\apply.ps1');
  // Waits for this process to exit (files are locked while it runs), copies the new files over, starts the app again.
  script.writeAsStringSync(r'''
param([int]$ProcId, [string]$Src, [string]$Dst, [string]$Exe)
try { Wait-Process -Id $ProcId -Timeout 60 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 700
robocopy $Src $Dst /E /R:10 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
Start-Process -FilePath $Exe
''');
  await Process.start(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script.path, '-ProcId', '$pid', '-Src', src.path, '-Dst', dst, '-Exe', exe],
    mode: ProcessStartMode.detached,
  );
  exit(0);
}

Future<void> openDownloadPage(NyxApi api) async {
  await launchUrl(Uri.parse('${api.baseUrl.replaceAll(RegExp(r'/+$'), '')}/downloadnyx'), mode: LaunchMode.externalApplication);
}
