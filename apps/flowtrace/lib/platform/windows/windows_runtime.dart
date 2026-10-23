import 'dart:io';

import 'package:flutter/services.dart';

/// The native runner owns the directory lease before any database is opened.
/// There is deliberately no fallback: a missing channel must not open a second
/// unlocked database or silently switch user data directories.
abstract final class WindowsRuntime {
  static const channel = MethodChannel('com.flowtrace/windows-runtime');

  static Future<Directory> dataDirectory() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows data directory requested on another OS.');
    }
    final values = await channel.invokeMapMethod<String, Object?>(
      'dataDirectory',
    );
    final path = values?['path'];
    if (path is! String ||
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
        values?['leaseHeld'] != true) {
      throw const FileSystemException(
        'Windows data directory lease unavailable.',
      );
    }
    return Directory(path);
  }
}
