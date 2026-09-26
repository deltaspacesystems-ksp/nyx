import 'api.dart';
import 'updater.dart';

// The web app is served by the server itself, so it is always the newest build.
bool get canSelfInstall => false;
String? platformName() => null;
Future<String> download(NyxApi api, UpdateInfo i, void Function(double) progress) async => throw UnsupportedError('web');
Future<void> installAndRestart(String path) async {}
Future<void> openDownloadPage(NyxApi api) async {}
