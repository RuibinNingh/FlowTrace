/// A credential-free server base URL. Its normalized form is a storage boundary.
final class ServerAddress {
  ServerAddress._(this.uri);

  factory ServerAddress.parse(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入完整的 HTTP 或 HTTPS 服务器地址，不包含账号、查询或片段。');
    }
    if (uri.scheme == 'http' && !_isLocalHost(uri.host)) {
      throw const FormatException('公网服务器请使用 HTTPS；HTTP 仅用于本机或局域网调试。');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return ServerAddress._(
      uri.replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
      ),
    );
  }

  final Uri uri;

  Uri resolve(String path) =>
      Uri.parse('$this/${path.replaceFirst(RegExp(r'^/+'), '')}');

  static bool _isLocalHost(String host) {
    if (host == 'localhost' || host == '::1') return true;
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
      return false;
    }
    return parts[0] == 127 ||
        parts[0] == 10 ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31);
  }

  @override
  String toString() => uri.toString();
}
