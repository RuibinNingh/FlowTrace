import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'server_address.dart';

/// Separate origins, server installations and users never share queued writes.
final class DataSpace {
  DataSpace({
    required this.server,
    required this.serverInstanceId,
    required this.userId,
  }) {
    if (serverInstanceId.isEmpty || userId.isEmpty) {
      throw ArgumentError('资料空间需要服务器实例和用户标识。');
    }
  }

  factory DataSpace.provisional(ServerAddress server) => DataSpace(
    server: server,
    serverInstanceId: 'unverified',
    userId: 'local-drafts',
  );

  final ServerAddress server;
  final String serverInstanceId;
  final String userId;

  bool get verified => serverInstanceId != 'unverified';

  String get id => sha256
      .convert(
        utf8.encode(jsonEncode([server.toString(), serverInstanceId, userId])),
      )
      .toString();
}
