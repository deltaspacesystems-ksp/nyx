import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'updater_web.dart' if (dart.library.io) 'updater_io.dart' as impl;

class ChangelogEntry {
  final String version;
  final String? released;
  final List<String> notes;
  ChangelogEntry(this.version, this.released, this.notes);
}

class UpdateInfo {
  final String version, file, sha256, platform;
  final int size;
  final List<ChangelogEntry> changelog;
  UpdateInfo({required this.version, required this.file, required this.sha256, required this.platform, required this.size, required this.changelog});
}

/// Asks the server whether a newer build exists, and (on Windows) downloads, verifies and installs it.
class Updater {
  static const _skipKey = 'nyx.update.skip';

  /// Which build this is, e.g. "1.1.0".
  static Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  static bool get canSelfInstall => impl.canSelfInstall;

  /// null when up to date, unsupported here (web is always current), offline, or the person chose to skip that version.
  static Future<UpdateInfo?> check(NyxApi api, {bool ignoreSkip = false}) async {
    final platform = impl.platformName();
    if (platform == null) return null;
    try {
      final current = await currentVersion();
      final r = await api.get('/api/app/update', {'platform': platform, 'current': current}) as Map;
      if (r['available'] != true) return null;
      final info = UpdateInfo(
        version: r['version'] as String,
        file: r['file'] as String,
        sha256: r['sha256'] as String,
        size: (r['size'] as num).toInt(),
        platform: platform,
        changelog: [
          for (final c in (r['changelog'] as List? ?? const []))
            ChangelogEntry(c['version'] as String, c['released'] as String?, ((c['notes'] as List?) ?? const []).cast<String>()),
        ],
      );
      if (!ignoreSkip && (await SharedPreferences.getInstance()).getString(_skipKey) == info.version) return null;
      return info;
    } catch (_) {
      return null; // an older server without updates, or offline: just carry on
    }
  }

  static Future<void> skip(UpdateInfo i) async => (await SharedPreferences.getInstance()).setString(_skipKey, i.version);

  /// Downloads the update into a temp folder and checks its SHA-256. Returns the path.
  static Future<String> download(NyxApi api, UpdateInfo i, void Function(double) progress) => impl.download(api, i, progress);

  /// Installs [path] and restarts the app. Only returns if it failed.
  static Future<void> installAndRestart(String path) => impl.installAndRestart(path);

  static Future<void> openDownloadPage(NyxApi api) => impl.openDownloadPage(api);
}
