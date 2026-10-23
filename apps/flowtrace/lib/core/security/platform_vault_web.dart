import 'session_vault.dart';

// Web refresh credentials belong solely to the server's HttpOnly cookie.
SessionVault createSessionVault() => _NoBrowserTokenVault();

final class _NoBrowserTokenVault implements SessionVault {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> delete(String key) async {}
  @override
  Future<void> write(String key, String value) async {
    throw StateError('浏览器不能持久保存刷新令牌。');
  }
}
