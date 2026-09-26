import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyx/core/discord_rpc_io.dart';

// A stand-in game: speaks the Discord Rich Presence pipe protocol through .NET's pipe client.
String _game(String pipe) => _script.replaceAll('PIPENAME', pipe);

const _script = r'''
$p = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'PIPENAME', 'InOut')
$p.Connect(5000)
function Send($op, $json) {
  $b = [Text.Encoding]::UTF8.GetBytes($json)
  $h = [BitConverter]::GetBytes([int]$op) + [BitConverter]::GetBytes([int]$b.Length)
  $p.Write($h + $b, 0, 8 + $b.Length); $p.Flush()
}
function Recv() {
  $h = New-Object byte[] 8; [void]$p.Read($h, 0, 8)
  $n = [BitConverter]::ToInt32($h, 4); $b = New-Object byte[] $n; [void]$p.Read($b, 0, $n)
  [Text.Encoding]::UTF8.GetString($b)
}
Send 0 '{"v":1,"client_id":"123"}'
$ready = Recv
Send 1 '{"cmd":"SET_ACTIVITY","nonce":"n1","args":{"pid":0,"activity":{"name":"Test Quest","details":"Level 7","state":"In a group","timestamps":{"start":1700000000}}}}'
$ack = Recv
Start-Sleep -Milliseconds 700
Write-Output "READY=$($ready.Contains('READY')) ACK=$($ack.Contains('n1'))"
$p.Dispose()
''';

void main() {
  test('a Discord-RPC game shows up as a Nyx activity and disappears when it quits', () async {
    if (!Platform.isWindows) return;
    final seen = <Map<String, dynamic>?>[];
    final bridge = DiscordRpcBridge();
    await bridge.start(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final r = await Process.run('powershell', ['-NoProfile', '-Command', _game(bridge.pipeName!)]);
    expect(r.stdout.toString().trim(), 'READY=True ACK=True', reason: '${r.stderr}');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final act = seen.firstWhere((a) => a != null)!;
    expect(act['name'], 'Test Quest');
    expect(act['details'], 'Level 7');
    expect(act['since'], 1700000000000);
    expect(seen.last, isNull, reason: 'closing the game clears the activity');
    bridge.stop();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
