import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _FlashInfo extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int flags;
  @Uint32()
  external int count;
  @Uint32()
  external int timeout;
}

/// Makes the Windows taskbar button flash orange until the window is focused (or stops it again).
void flashTaskbar(bool on) {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final findWindow = user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
    final flashWindowEx = user32.lookupFunction<Int32 Function(Pointer<_FlashInfo>), int Function(Pointer<_FlashInfo>)>('FlashWindowEx');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final hwnd = findWindow(cls, nullptr);
    calloc.free(cls);
    if (hwnd == 0) return;
    final info = calloc<_FlashInfo>();
    info.ref
      ..cbSize = sizeOf<_FlashInfo>()
      ..hwnd = hwnd
      ..flags = on ? 0x0000000F : 0 // FLASHW_ALL | FLASHW_TIMERNOFG  /  FLASHW_STOP
      ..count = 0
      ..timeout = 0;
    flashWindowEx(info);
    calloc.free(info);
  } catch (_) {}
}
