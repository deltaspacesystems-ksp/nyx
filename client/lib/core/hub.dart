import 'dart:async';

import 'package:signalr_netcore/signalr_client.dart';

import 'api.dart';

/// The live connection. Reconnects forever with backoff, asking the API for a fresh access token each time
/// (tokens only live 15 minutes, so a long-lived socket must be able to come back with a new one).
class HubClient {
  final NyxApi api;
  HubClient(this.api);

  HubConnection? _conn;
  bool _wanted = false;
  bool connected = false;
  final _handlers = <String, void Function(dynamic)>{};

  void Function()? onConnected;
  void Function()? onDisconnected;

  void on(String event, void Function(dynamic data) handler) => _handlers[event] = handler;

  Future<void> start() async {
    _wanted = true;
    await _connect();
  }

  Future<void> _connect() async {
    var delay = 1;
    while (_wanted) {
      try {
        final url = '${api.baseUrl.replaceAll(RegExp(r'/+$'), '')}/hub';
        final conn = HubConnectionBuilder()
            .withUrl(url, options: HttpConnectionOptions(accessTokenFactory: () async => (await api.validToken()) ?? ''))
            .build();
        conn.keepAliveIntervalInMilliseconds = 15000;
        conn.serverTimeoutInMilliseconds = 45000;
        _handlers.forEach((evt, h) => conn.on(evt, (args) => h(args == null || args.isEmpty ? null : args[0])));
        conn.onclose(({error}) {
          connected = false;
          onDisconnected?.call();
          if (_wanted) _connect();
        });
        await conn.start();
        _conn = conn;
        connected = true;
        onConnected?.call();
        return;
      } catch (_) {
        connected = false;
        await Future<void>.delayed(Duration(seconds: delay));
        delay = (delay * 2).clamp(1, 30);
      }
    }
  }

  Future<T?> invoke<T>(String method, [List<Object>? args]) async {
    final c = _conn;
    if (c == null || !connected) throw StateError('Not connected');
    return await c.invoke(method, args: args) as T?;
  }

  Future<void> stop() async {
    _wanted = false;
    connected = false;
    final c = _conn;
    _conn = null;
    try {
      await c?.stop();
    } catch (_) {}
  }
}
