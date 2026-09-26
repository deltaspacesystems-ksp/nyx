import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Nyx pretends to be the Discord desktop app for games: anything that talks "Discord Rich Presence"
/// (a named pipe called discord-ipc-N) talks to Nyx instead, and what it reports becomes the person's
/// activity in Nyx. Nothing is forwarded to Discord. Windows only; if Discord itself is running it keeps
/// discord-ipc-0, so games usually pick it: close Discord (or start Nyx first) to receive their activity.
class DiscordRpcBridge {
  ReceivePort? _rx;
  Isolate? _listener;
  final _byConn = <int, Map<String, dynamic>>{};
  void Function(Map<String, dynamic>? activity)? _onChange;

  /// Which discord-ipc-N pipe was claimed (N is the first one not already used by Discord itself).
  String? pipeName;

  bool get supported => Platform.isWindows;
  bool get running => _listener != null;

  Future<void> start(void Function(Map<String, dynamic>? activity) onChange) async {
    if (!supported || running) return;
    _onChange = onChange;
    _rx = ReceivePort();
    _rx!.listen((m) {
      if (m is! List) return;
      if (m[0] is String) {
        pipeName = m[0] as String;
        return;
      }
      final conn = m[0] as int;
      final act = m[1] as String?;
      if (act == null) {
        _byConn.remove(conn);
      } else {
        _byConn[conn] = (jsonDecode(act) as Map).cast<String, dynamic>();
      }
      _onChange?.call(_byConn.isEmpty ? null : _byConn.values.last);
    });
    _listener = await Isolate.spawn(_listen, _rx!.sendPort, debugName: 'nyx-rpc');
  }

  void stop() {
    _listener?.kill(priority: Isolate.immediate);
    _listener = null;
    _rx?.close();
    _rx = null;
    _byConn.clear();
    _onChange?.call(null);
  }
}

// ------------------------------------------------------------------------------ Win32

final _k32 = DynamicLibrary.open('kernel32.dll');
final _createPipe = _k32.lookupFunction<IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Uint32, Uint32, Uint32, Uint32, Pointer<Void>), int Function(Pointer<Utf16>, int, int, int, int, int, int, Pointer<Void>)>('CreateNamedPipeW');
final _connect = _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Void>), int Function(int, Pointer<Void>)>('ConnectNamedPipe');
final _disconnect = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DisconnectNamedPipe');
final _closeHandle = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _readFile = _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>), int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
final _writeFile = _k32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>), int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
final _getLastError = _k32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
final _openProcess = _k32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
final _queryImage = _k32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>), int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>('QueryFullProcessImageNameW');

const _invalid = -1;

int _newPipe(String name, {required bool first}) {
  final n = name.toNativeUtf16();
  // PIPE_ACCESS_DUPLEX (+ FILE_FLAG_FIRST_PIPE_INSTANCE), byte pipe, blocking, up to 255 instances
  final h = _createPipe(n, first ? 0x00080003 : 0x3, 0, 255, 65536, 65536, 0, nullptr);
  calloc.free(n);
  return h;
}

/// Blocking accept loop (runs in its own isolate).
void _listen(SendPort main) {
  String? name;
  for (var i = 0; i < 10 && name == null; i++) {
    final probe = _newPipe(r'\\.\pipe\discord-ipc-' '$i', first: true);
    if (probe != _invalid) {
      name = r'\\.\pipe\discord-ipc-' '$i';
      main.send(['discord-ipc-$i']);
      _acceptLoop(name, probe, main);
    }
  }
}

void _acceptLoop(String name, int firstHandle, SendPort main) {
  var h = firstHandle;
  while (true) {
    final ok = _connect(h, nullptr);
    if (ok != 0 || _getLastError() == 535 /* ERROR_PIPE_CONNECTED */) {
      final conn = h;
      Isolate.spawn(_serve, [main, conn], errorsAreFatal: false, onError: RawReceivePort((e) => stderr.writeln('rpc serve error: $e')).sendPort);
      h = _newPipe(name, first: false);
      if (h == _invalid) return;
    } else {
      _disconnect(h);
    }
  }
}

// ------------------------------------------------------------------------------ protocol

bool _readExact(int h, Pointer<Uint8> buf, int n) {
  final got = calloc<Uint32>();
  var off = 0;
  try {
    while (off < n) {
      if (_readFile(h, buf + off, n - off, got, nullptr) == 0 || got.value == 0) return false;
      off += got.value;
    }
    return true;
  } finally {
    calloc.free(got);
  }
}

void _send(int h, int op, Object json) {
  final body = utf8.encode(jsonEncode(json));
  final data = Uint8List(8 + body.length);
  final bd = ByteData.sublistView(data);
  bd.setInt32(0, op, Endian.little);
  bd.setInt32(4, body.length, Endian.little);
  data.setRange(8, data.length, body);
  final p = calloc<Uint8>(data.length);
  p.asTypedList(data.length).setAll(0, data);
  final w = calloc<Uint32>();
  _writeFile(h, p, data.length, w, nullptr);
  calloc.free(p);
  calloc.free(w);
}

String? _exeName(int pid) {
  final proc = _openProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, 0, pid);
  if (proc == 0) return null;
  final buf = calloc<Uint16>(520).cast<Utf16>();
  final size = calloc<Uint32>()..value = 520;
  try {
    if (_queryImage(proc, 0, buf, size) == 0) return null;
    final path = buf.toDartString(length: size.value);
    var file = path.split(r'\').last;
    if (file.toLowerCase().endsWith('.exe')) file = file.substring(0, file.length - 4);
    return file;
  } finally {
    calloc.free(buf);
    calloc.free(size);
    _closeHandle(proc);
  }
}

/// One connected game.
void _serve(List args) {
  final main = args[0] as SendPort;
  final h = args[1] as int;
  final hdr = calloc<Uint8>(8);
  try {
    while (_readExact(h, hdr, 8)) {
      final bd = ByteData.sublistView(hdr.asTypedList(8));
      final op = bd.getInt32(0, Endian.little), len = bd.getInt32(4, Endian.little);
      if (len < 0 || len > 1 << 20) break;
      Map<String, dynamic> msg = {};
      if (len > 0) {
        final body = calloc<Uint8>(len);
        final ok = _readExact(h, body, len);
        if (ok) {
          try {
            msg = (jsonDecode(utf8.decode(body.asTypedList(len), allowMalformed: true)) as Map).cast<String, dynamic>();
          } catch (_) {}
        }
        calloc.free(body);
        if (!ok) break;
      }
      switch (op) {
        case 0: // handshake
          _send(h, 1, {
            'cmd': 'DISPATCH',
            'evt': 'READY',
            'nonce': null,
            'data': {
              'v': 1,
              'config': {'cdn_host': 'cdn.discordapp.com', 'api_endpoint': '//discord.com/api', 'environment': 'production'},
              'user': {'id': '1', 'username': 'nyx', 'discriminator': '0', 'avatar': null},
            },
          });
        case 1:
          final cmd = msg['cmd'];
          final a = (msg['args'] as Map?)?.cast<String, dynamic>() ?? {};
          if (cmd == 'SET_ACTIVITY') {
            final act = (a['activity'] as Map?)?.cast<String, dynamic>();
            if (act == null) {
              main.send([h, null]);
            } else {
              final pid = (a['pid'] as num?)?.toInt();
              final name = (act['name'] as String?) ?? (pid == null ? null : _exeName(pid)) ?? 'a game';
              final start = ((act['timestamps'] as Map?)?['start'] as num?)?.toInt();
              main.send([
                h,
                jsonEncode({'name': name, 'details': act['details'], 'state': act['state'], if (start != null) 'since': start > 1e12 ? start : start * 1000}),
              ]);
            }
            _send(h, 1, {'cmd': 'SET_ACTIVITY', 'data': act, 'evt': null, 'nonce': msg['nonce']});
          } else {
            _send(h, 1, {'cmd': cmd, 'data': {}, 'evt': null, 'nonce': msg['nonce']});
          }
        case 2:
          _send(h, 2, {});
          break;
        case 3: // ping
          _send(h, 4, msg);
      }
      if (op == 2) break;
    }
  } finally {
    main.send([h, null]);
    _disconnect(h);
    _closeHandle(h);
    calloc.free(hdr);
  }
}
