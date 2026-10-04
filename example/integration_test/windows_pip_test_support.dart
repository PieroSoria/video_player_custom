import 'dart:ffi';

/// Exercises the actual native PiP window without adding test-only channels.
class WindowsPipWindow {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _gdi32 = DynamicLibrary.open('gdi32.dll');
  static final _crt = DynamicLibrary.open('msvcrt.dll');
  static final _allocate = _crt
      .lookupFunction<
        Pointer<Void> Function(UintPtr, UintPtr),
        Pointer<Void> Function(int, int)
      >('calloc');
  static final _free = _crt
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  static final _find = _user32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>),
        Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>)
      >('FindWindowW');
  static final _post = _user32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, UintPtr, IntPtr),
        int Function(Pointer<Void>, int, int, int)
      >('PostMessageW');
  static final _rect = _user32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_Rect>),
        int Function(Pointer<Void>, Pointer<_Rect>)
      >('GetClientRect');
  static final _setWindowPos = _user32
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Int32,
          Int32,
          Int32,
          Int32,
          Uint32,
        ),
        int Function(Pointer<Void>, Pointer<Void>, int, int, int, int, int)
      >('SetWindowPos');
  static final _style = _user32
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('GetWindowLongPtrW');
  static final _getDc = _user32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('GetDC');
  static final _releaseDc = _user32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('ReleaseDC');
  static final _pixel = _gdi32
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Int32, Int32),
        int Function(Pointer<Void>, int, int)
      >('GetPixel');

  static Pointer<Void> get handle {
    const name = 'VideoPlayerCustom_PipWindow';
    final buffer = _allocate(name.length + 1, 2).cast<Uint16>();
    try {
      buffer.asTypedList(name.length + 1).setAll(0, name.codeUnits);
      return _find(buffer, nullptr);
    } finally {
      _free(buffer.cast());
    }
  }

  static bool get exists => handle != nullptr;

  static bool get isTopmost => (_style(handle, -20) & 0x00000008) != 0;

  static ({int width, int height}) get size {
    final rect = _allocate(1, sizeOf<_Rect>()).cast<_Rect>();
    try {
      if (_rect(handle, rect) == 0) {
        throw StateError('The native PiP window does not exist');
      }
      return (
        width: rect.ref.right - rect.ref.left,
        height: rect.ref.bottom - rect.ref.top,
      );
    } finally {
      _free(rect.cast());
    }
  }

  static void click(int x, int y) {
    final window = handle;
    final coordinates = (y << 16) | (x & 0xffff);
    _post(window, 0x0201, 1, coordinates); // WM_LBUTTONDOWN
    _post(window, 0x0202, 0, coordinates); // WM_LBUTTONUP
  }

  static void togglePlayback() {
    final bounds = size;
    movePointer(bounds.width ~/ 2, controlY);
    click(bounds.width ~/ 2, controlY);
  }

  static int get controlY {
    final height = size.height;
    return 32 + (height - 32 - (height < 180 ? 48 : 0)) ~/ 2;
  }

  static void skipSeconds({required bool forward}) {
    final bounds = size;
    final x = bounds.width ~/ 2 + (forward ? 56 : -56);
    final y = controlY;
    movePointer(x, y);
    click(x, y);
  }

  static void movePointer(int x, int y, {bool dragging = false}) =>
      _post(handle, 0x0200, dragging ? 1 : 0, (y << 16) | (x & 0xffff));

  static void leavePointer() => _post(handle, 0x02a3, 0, 0); // WM_MOUSELEAVE

  static void seek(double fraction) {
    final bounds = size;
    final x = (16 + (bounds.width - 32) * fraction).round();
    movePointer(x, bounds.height - 20);
    click(x, bounds.height - 20);
  }

  static void beginSeek(double fraction) {
    final bounds = size;
    final x = (16 + (bounds.width - 32) * fraction).round();
    movePointer(x, bounds.height - 20);
    _post(handle, 0x0201, 1, ((bounds.height - 20) << 16) | (x & 0xffff));
  }

  static void dragSeek(double fraction) {
    final bounds = size;
    movePointer(
      (16 + (bounds.width - 32) * fraction).round(),
      bounds.height - 20,
      dragging: true,
    );
  }

  static void endSeek(double fraction) {
    final bounds = size;
    final x = (16 + (bounds.width - 32) * fraction).round();
    _post(handle, 0x0202, 0, ((bounds.height - 20) << 16) | (x & 0xffff));
  }

  static void cancelSeek() => _post(handle, 0x001f, 0, 0); // WM_CANCELMODE

  static List<int> get controlPixels {
    final bounds = size;
    final centerY = controlY;
    return samplePixels([
      for (var y = -16; y <= 16; y += 4)
        for (var x = -16; x <= 16; x += 4)
          (x: bounds.width ~/ 2 + x, y: centerY + y),
    ]);
  }

  static List<int> get framePixels {
    final bounds = size;
    return samplePixels([
      for (var y = 1; y <= 3; y++)
        for (var x = 1; x <= 8; x++)
          (x: bounds.width * x ~/ 10, y: 32 + (bounds.height - 32) * y ~/ 10),
    ]);
  }

  static void restore() => click(size.width - 48, 16);

  static void closeButton() => click(size.width - 16, 16);

  static void close() => _post(handle, 0x0010, 0, 0); // WM_CLOSE

  static void resize(int width, int height) {
    if (_setWindowPos(handle, nullptr, 0, 0, width, height, 0x0016) == 0) {
      throw StateError('Could not resize the native PiP window');
    }
  }

  static List<int> samplePixels(List<({int x, int y})> points) {
    final window = handle;
    final dc = _getDc(window);
    try {
      return [for (final point in points) _pixel(dc, point.x, point.y)];
    } finally {
      _releaseDc(window, dc);
    }
  }

  static bool get hasVideoPixels {
    final window = handle;
    final bounds = size;
    final dc = _getDc(window);
    try {
      // Ignore the control bands and letterbox edges; sample the video itself.
      for (var row = 2; row < 8; row++) {
        for (var column = 2; column < 8; column++) {
          final color = _pixel(
            dc,
            bounds.width * column ~/ 10,
            bounds.height * row ~/ 10,
          );
          if (color != 0 && color != 0xffffffff) return true;
        }
      }
      return false;
    } finally {
      _releaseDc(window, dc);
    }
  }
}

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}
