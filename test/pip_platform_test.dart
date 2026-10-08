import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip_method_channel.dart';
import 'package:video_player_custom/src/pip/video_player_custom_pip_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = MethodChannelVideoPlayerPip();
  const channel = MethodChannel('video_player_pip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('unavailable PiP returns false and reset completes', () async {
    expect(await platform.isPipSupported(), isFalse);
    expect(await platform.enterPipMode(1), isFalse);
    expect(await platform.exitPipMode(), isFalse);
    expect(await platform.isInPipMode(), isFalse);
    await platform.reset();
  });
  test('forwards player and dimensions to native PiP', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });
    expect(await platform.enterPipMode(42, width: 320, height: 180), isTrue);
    expect(received!.method, 'enterPipMode');
    expect(received!.arguments, {'playerId': 42, 'width': 320, 'height': 180});
  });
  test('forwards the player and unsigned ARGB accent color', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    await platform.setPipAccentColor(42, 0xFF6750A4);
    expect(received!.method, 'setPipAccentColor');
    expect(received!.arguments, {'playerId': 42, 'color': 0xFF6750A4});
  });
  test('older implementations may leave accent color unsupported', () async {
    await _DefaultPipPlatform().setPipAccentColor(42, 0xFF6750A4);
    await platform.setPipAccentColor(42, 0xFF6750A4);
  });
  test('native errors are handled as unavailable PiP', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await platform.isPipSupported(), isFalse);
    await platform.setPipAccentColor(42, 0xFF6750A4);
    await platform.reset();
  });
}

class _DefaultPipPlatform extends VideoPlayerPipPlatform {}
