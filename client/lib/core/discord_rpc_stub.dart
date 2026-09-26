/// Discord Rich Presence bridge: only exists on Windows.
class DiscordRpcBridge {
  String? pipeName;
  bool get supported => false;
  bool get running => false;
  Future<void> start(void Function(Map<String, dynamic>? activity) onChange) async {}
  void stop() {}
}
