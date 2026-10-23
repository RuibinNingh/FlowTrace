import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../local/local_repository.dart';
import 'app_preferences.dart';

class PreferencesController extends ChangeNotifier {
  PreferencesController(this.repository);
  final LocalRepository repository;
  static const settingKey = 'app.preferences.v1';
  static const recoveryKey = 'app.preferences.recovery.v1';
  AppPreferences _value = const AppPreferences();
  AppPreferences get value => _value;
  bool ready = false;
  bool saving = false;
  String? error;
  String? _unreadable;
  String? _expectedRaw, _expectedLegacy;
  bool _disposed = false;
  int _loadGeneration = 0;
  bool get needsRecovery => _unreadable != null;

  Future<void> initialize() async {
    if (_disposed || saving) throw StateError('本机设置正在保存或已经关闭。');
    final generation = ++_loadGeneration;
    ready = false;
    error = null;
    late final ({String? raw, String? legacy}) snapshot;
    try {
      snapshot = await _readSnapshot();
    } catch (_) {
      if (!_disposed && generation == _loadGeneration) {
        error = '本机设置暂不能读取，原值仍保留；请重新读取后重试。';
        _changed();
      }
      rethrow;
    }
    if (_disposed || generation != _loadGeneration) return;
    _acceptSnapshot(snapshot);
    _changed();
  }

  Future<({String? raw, String? legacy})> _readSnapshot() =>
      repository.database.readSnapshot(
        () async => (
          raw: await repository.readSetting(settingKey),
          legacy: await repository.readSetting('theme_mode'),
        ),
      );

  void _acceptSnapshot(({String? raw, String? legacy}) snapshot) {
    final raw = snapshot.raw;
    _expectedRaw = raw;
    _expectedLegacy = snapshot.legacy;
    if (raw == null) {
      _value = AppPreferences(
        themeMode: switch (snapshot.legacy) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        },
      );
      _unreadable = null;
    } else {
      try {
        if (raw.length > 16384) throw const FormatException();
        _value = AppPreferences.fromJson(jsonDecode(raw));
        _unreadable = null;
      } on FormatException {
        _value = const AppPreferences();
        _unreadable = raw;
        error = '本机设置暂不能读取，当前使用默认显示；原值已保留。';
      }
    }
    ready = true;
  }

  Future<void> update(AppPreferences next) async {
    if (_disposed || !ready || saving) throw StateError('本机设置尚未就绪。');
    if (needsRecovery) throw StateError('请先恢复本机设置，原始值仍保留。');
    await _save(next);
  }

  Future<void> restoreDefaults() async {
    if (_disposed || !ready || saving) throw StateError('本机设置尚未就绪。');
    await _save(const AppPreferences(), preserve: _unreadable);
  }

  Future<void> _save(AppPreferences next, {String? preserve}) async {
    final expectedRaw = _expectedRaw, expectedLegacy = _expectedLegacy;
    final encoded = jsonEncode(next.toJson());
    saving = true;
    _changed();
    try {
      await repository.database.atomicWrite(() async {
        if (await repository.readSetting(settingKey) != expectedRaw ||
            await repository.readSetting('theme_mode') != expectedLegacy) {
          throw const PreferencesChanged();
        }
        if (preserve != null) {
          await repository.writeSetting(recoveryKey, preserve);
        }
        await repository.writeSetting(settingKey, encoded);
        // Keep an old binary's existing theme source in the same transaction.
        await repository.writeSetting('theme_mode', next.themeMode.name);
      });
      if (_disposed) return;
      _expectedRaw = encoded;
      _expectedLegacy = next.themeMode.name;
      _value = next;
      _unreadable = null;
      error = null;
    } on PreferencesChanged {
      try {
        final latest = await _readSnapshot();
        if (!_disposed) {
          _acceptSnapshot(latest);
          error = '本机设置已在其他页面更改，已重新读取；请重试本次修改。';
        }
      } catch (_) {
        if (!_disposed) {
          error = '本机设置已在其他页面更改，暂不能读取新值；请重新读取后重试。';
          ready = false;
        }
      }
      rethrow;
    } catch (_) {
      if (!_disposed) error = '本机设置未能保存，仍使用上次已保存的设置。';
      rethrow;
    } finally {
      saving = false;
      _changed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_loadGeneration;
    super.dispose();
  }
}

class PreferencesChanged implements Exception {
  const PreferencesChanged();
  @override
  String toString() => '本机设置已在其他页面更改，请重试。';
}
