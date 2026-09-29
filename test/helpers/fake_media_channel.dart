import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Deterministic fake for the `com.motebaya.pindl/media` platform channel.
///
/// Simulates the Android-side MediaStore behavior in a temp directory so the
/// DownloadService queue can be tested end-to-end without an emulator:
/// - fileExists: checks the simulated Downloads tree
/// - saveFileToDownloads: copies the source temp file into the tree (overwrite honored)
/// - saveTextToFile / readTextFromFile: text round-trip for metadata
/// - scanFile: no-op
class FakeMediaChannel {
  final Directory root;
  late final MethodChannel _channel;
  int saveCalls = 0;
  int existsCalls = 0;

  FakeMediaChannel(this.root) {
    _channel = const MethodChannel('com.motebaya.pindl/media');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  Directory _subDir(String subFolder) =>
      Directory(p.join(root.path, 'PinDL', subFolder))..createSync(recursive: true);

  String _file(String subFolder, String filename) =>
      p.join(_subDir(subFolder).path, filename);

  Future<Object?>? _handle(MethodCall call) async {
    switch (call.method) {
      case 'fileExists':
        existsCalls++;
        final args = call.arguments as Map;
        return File(_file(args['subFolder'] as String, args['filename'] as String))
            .existsSync();
      case 'saveFileToDownloads':
        saveCalls++;
        final args = call.arguments as Map;
        final dest = _file(args['subFolder'] as String, args['filename'] as String);
        final src = File(args['sourcePath'] as String);
        if (args['overwrite'] == true && File(dest).existsSync()) {
          File(dest).deleteSync();
        }
        if (src.existsSync()) src.copySync(dest);
        return dest;
      case 'saveTextToFile':
        final args = call.arguments as Map;
        final f = File(_file(args['subFolder'] as String, args['filename'] as String));
        f.writeAsStringSync(args['content'] as String, flush: true);
        return f.path;
      case 'readTextFromFile':
        final args = call.arguments as Map;
        final f = File(_file(args['subFolder'] as String, args['filename'] as String));
        return f.existsSync() ? f.readAsStringSync() : null;
      case 'scanFile':
        return null;
      default:
        throw MissingPluginException('FakeMediaChannel: unhandled ${call.method}');
    }
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
