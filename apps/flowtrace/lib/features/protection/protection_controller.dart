import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'password_deriver.dart';
import 'protection_notifications.dart';
import 'protection_store.dart';

class ProtectionController extends ChangeNotifier {
  ProtectionController({
    required this.store,
    required this.supported,
    PasswordDeriver? deriver,
    ProtectionNotifications? notifications,
    DateTime Function()? clock,
    List<int> Function(int)? randomBytes,
    this.beforeLock,
  }) : _deriver = deriver ?? createPasswordDeriver(),
       _notifications = notifications ?? createProtectionNotifications(),
       _clock = clock ?? DateTime.now,
       _randomBytes = randomBytes ?? _secureRandom {
    _subscription = _notifications.changes.listen((_) {
      if (supported) unawaited(_externalChange());
    });
  }

  final ProtectionStore store;
  final bool supported;
  final PasswordDeriver _deriver;
  final ProtectionNotifications _notifications;
  final DateTime Function() _clock;
  final List<int> Function(int) _randomBytes;
  Future<bool> Function()? beforeLock;
  late final StreamSubscription<void> _subscription;
  bool _disposed = false;
  int _generation = 0;
  bool ready = false;
  bool busy = false;
  bool locked = true;
  bool enabled = false;
  bool get available => supported && _notifications.available;
  String? error;
  String? draftWarning;
  _ProtectionRecord? _record;
  String? _raw;

  static const iterations = 600000;
  static List<int> _secureRandom(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Duration get retryAfter {
    final blocked = _record?.blockedUntil;
    if (blocked == null) return Duration.zero;
    final remaining = blocked.difference(_clock().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> initialize() async {
    if (_disposed) return;
    final generation = ++_generation;
    locked = supported;
    ready = false;
    error = null;
    _changed();
    if (!supported) {
      enabled = false;
      locked = false;
      ready = true;
      _changed();
      return;
    }
    try {
      final raw = await store.read();
      final record = raw == null ? null : _ProtectionRecord.decode(raw);
      if (_disposed || generation != _generation) return;
      _raw = raw;
      _record = record;
      enabled = record?.enabled == true;
      locked = enabled;
      ready = true;
      if (enabled && !_notifications.available) {
        error = '此浏览器无法协调多个标签页的应用保护，请使用支持多标签通信的浏览器后重试。';
      }
    } catch (_) {
      if (_disposed || generation != _generation) return;
      // No corrupt record is overwritten and no business data is removed.
      enabled = true;
      locked = true;
      error = '本机保护设置暂不能读取。请重试；账单和草稿仍保留。';
    }
    _changed();
  }

  Future<void> _externalChange() async {
    // Another tab must immediately lose any previously unlocked view. The
    // subsequent read also makes a re-key invalidate an in-flight verification.
    await lock(force: true);
    await initialize();
  }

  Future<void> lock({bool force = false}) async {
    if (!supported || (!force && !enabled && ready && !busy)) return;
    ++_generation;
    locked = true;
    _changed();
    try {
      final saved = await beforeLock?.call();
      if (saved == false) {
        draftWarning = '部分输入尚未保存到磁盘，仍保留在当前页面；解锁后请重试保存。';
      } else {
        draftWarning = null;
      }
    } catch (_) {
      draftWarning = '部分输入尚未保存到磁盘，仍保留在当前页面；解锁后请重试保存。';
    }
    _changed();
  }

  Future<bool> unlock(String password) async {
    if (!_canVerify ||
        !_validPassword(password) ||
        retryAfter > Duration.zero) {
      error = retryAfter > Duration.zero ? '尝试过于频繁，请稍后重试。' : '请输入正确的本机保护密码。';
      _changed();
      return false;
    }
    return _verifyAndApply(password, null);
  }

  Future<bool> disable(String currentPassword) async {
    if (!_canVerify || !_validPassword(currentPassword)) return false;
    return _verifyAndApply(currentPassword, const _ProtectionRecord.disabled());
  }

  Future<bool> setPassword(String password, {String? currentPassword}) async {
    if (!supported || !ready || busy) return false;
    if (!_notifications.available) {
      error = '此浏览器暂不支持多个标签页的应用保护，未开启本机锁。';
      _changed();
      return false;
    }
    if (!_validPassword(password)) {
      error = '保护密码需为8–128个字符，且不能全部为空白。';
      _changed();
      return false;
    }
    if (enabled && (!_canVerify || !_validPassword(currentPassword ?? ''))) {
      error = '更改保护密码前需验证当前密码。';
      _changed();
      return false;
    }
    if (enabled && retryAfter > Duration.zero) {
      error = '尝试过于频繁，请稍后重试。';
      _changed();
      return false;
    }
    final generation = _generation;
    final raw = _raw;
    busy = true;
    error = null;
    _changed();
    try {
      if (enabled && !await _matches(currentPassword!, _record!)) {
        await _failedAttempt(raw);
        return false;
      }
      final salt = _randomBytes(32);
      if (salt.length != 32 || salt.any((item) => item < 0 || item > 255)) {
        throw StateError('Unavailable secure random source');
      }
      final verifier = await _deriver.derive(
        password,
        salt,
        iterations: iterations,
      );
      if (_disposed || generation != _generation) return false;
      if (verifier.length != 32) {
        throw StateError('Invalid password derivation');
      }
      final next = _ProtectionRecord.enabled(salt, verifier);
      if (!await _persist(raw, next)) return false;
      if (_disposed || generation != _generation) return false;
      enabled = true;
      // Enabling/changing confirms the newly entered password in this tab.
      locked = false;
      return true;
    } catch (_) {
      error = '保护设置未能保存，请重试；原有保护与账单仍保留。';
      if (enabled) locked = true;
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }

  bool get _canVerify =>
      supported &&
      ready &&
      !busy &&
      enabled &&
      _record?.enabled == true &&
      _notifications.available;

  static bool _validPassword(String value) =>
      value.runes.length >= 8 &&
      value.runes.length <= 128 &&
      utf8.encode(value).length <= 512 &&
      value.trim().isNotEmpty;

  Future<bool> _verifyAndApply(
    String password,
    _ProtectionRecord? replacement,
  ) async {
    if (retryAfter > Duration.zero) return false;
    final generation = _generation;
    final raw = _raw;
    final record = _record!;
    busy = true;
    error = null;
    _changed();
    try {
      final matches = await _matches(password, record);
      if (_disposed || generation != _generation) return false;
      if (!matches) {
        await _failedAttempt(raw);
        return false;
      }
      final next = replacement ?? record.withFailures(0, null);
      if (!await _persist(raw, next)) return false;
      if (_disposed || generation != _generation) return false;
      enabled = next.enabled;
      locked = false;
      return true;
    } catch (_) {
      locked = true;
      error = '暂不能验证本机保护，请重试；账单和草稿仍保留。';
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<bool> _matches(String password, _ProtectionRecord record) async {
    final actual = await _deriver.derive(
      password,
      record.salt!,
      iterations: iterations,
    );
    final expected = record.verifier!;
    var different = actual.length ^ expected.length;
    for (var index = 0; index < expected.length; index++) {
      different |=
          expected[index] ^ (index < actual.length ? actual[index] : 0);
    }
    return different == 0;
  }

  Future<void> _failedAttempt(String? expected) async {
    final failures = min((_record?.failures ?? 0) + 1, 20);
    final delay = failures < 5 ? 0 : min(30, 1 << min(failures - 5, 5));
    final next = _record!.withFailures(
      failures,
      delay == 0 ? null : _clock().toUtc().add(Duration(seconds: delay)),
    );
    if (await _persist(expected, next)) {
      error = delay == 0 ? '本机保护密码不正确。' : '尝试过于频繁，请稍后重试。';
    }
    // An invalid disable/change attempt also revokes this tab's open view.
    locked = true;
  }

  Future<bool> _persist(String? expected, _ProtectionRecord next) async {
    final encoded = next.encode();
    if (!await store.compareAndSet(expected, encoded)) {
      ++_generation;
      locked = true;
      ready = false;
      error = '本机保护已在其他页面更改，请重新读取设置。';
      return false;
    }
    _raw = encoded;
    _record = next;
    enabled = next.enabled;
    _notifications.publish();
    return true;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_subscription.cancel());
    _notifications.close();
    super.dispose();
  }
}

class _ProtectionRecord {
  const _ProtectionRecord.disabled()
    : enabled = false,
      salt = null,
      verifier = null,
      failures = 0,
      blockedUntil = null;
  _ProtectionRecord.enabled(List<int> salt, List<int> verifier)
    : this._(
        true,
        List<int>.unmodifiable(salt),
        List<int>.unmodifiable(verifier),
        0,
        null,
      );
  const _ProtectionRecord._(
    this.enabled,
    this.salt,
    this.verifier,
    this.failures,
    this.blockedUntil,
  );
  final bool enabled;
  final List<int>? salt, verifier;
  final int failures;
  final DateTime? blockedUntil;

  factory _ProtectionRecord.decode(String raw) {
    if (raw.length > 2048) throw const FormatException();
    final json = jsonDecode(raw);
    if (json is! Map<String, Object?> ||
        json['version'] != 1 ||
        json['enabled'] is! bool) {
      throw const FormatException();
    }
    if (json['enabled'] == false) {
      if (json.length != 2) throw const FormatException();
      return const _ProtectionRecord.disabled();
    }
    final failures = json['failures'];
    if (json.length != 8 ||
        json.keys.any(
          (key) => !{
            'version',
            'enabled',
            'algorithm',
            'iterations',
            'salt',
            'verifier',
            'failures',
            'blocked_until',
          }.contains(key),
        ) ||
        json['algorithm'] != 'pbkdf2-hmac-sha256' ||
        json['iterations'] != ProtectionController.iterations ||
        json['salt'] is! String ||
        json['verifier'] is! String ||
        failures is! int ||
        failures < 0 ||
        failures > 20 ||
        (json['blocked_until'] != null && json['blocked_until'] is! String)) {
      throw const FormatException();
    }
    final salt = base64Decode(json['salt'] as String);
    final verifier = base64Decode(json['verifier'] as String);
    if (salt.length != 32 ||
        verifier.length != 32 ||
        base64Encode(salt) != json['salt'] ||
        base64Encode(verifier) != json['verifier']) {
      throw const FormatException();
    }
    final blocked = json['blocked_until'] == null
        ? null
        : DateTime.parse(json['blocked_until'] as String);
    if (blocked != null && !blocked.isUtc) throw const FormatException();
    return _ProtectionRecord._(
      true,
      salt,
      verifier,
      json['failures'] as int,
      blocked,
    );
  }

  _ProtectionRecord withFailures(int count, DateTime? until) =>
      _ProtectionRecord._(enabled, salt, verifier, count, until);

  String encode() => jsonEncode(
    enabled
        ? {
            'version': 1,
            'enabled': true,
            'algorithm': 'pbkdf2-hmac-sha256',
            'iterations': ProtectionController.iterations,
            'salt': base64Encode(salt!),
            'verifier': base64Encode(verifier!),
            'failures': failures,
            'blocked_until': blockedUntil?.toUtc().toIso8601String(),
          }
        : {'version': 1, 'enabled': false},
  );
}
