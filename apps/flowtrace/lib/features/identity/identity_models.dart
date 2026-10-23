import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/config/server_address.dart';
import '../../core/network/api_failure.dart';

String stringField(Map<String, Object?> data, String name) {
  final value = data[name];
  if (value is! String || value.isEmpty) throw invalidIdentityResponse();
  return value;
}

String uuidField(Map<String, Object?> data, String name) {
  final value = stringField(data, name);
  if (!Uuid.isValidUUID(fromString: value)) throw invalidIdentityResponse();
  return value;
}

ApiFailure invalidIdentityResponse() =>
    const ApiFailure('invalid_response', '服务器身份响应不完整，请检查服务版本。');

final class ServerIdentity {
  ServerIdentity.fromJson(Map<String, Object?> data)
    : instanceId = uuidField(data, 'instance_id'),
      syncEpoch = uuidField(data, 'sync_epoch'),
      supportsGroupPull =
          data['capabilities'] is List &&
          (data['capabilities'] as List).contains('group-sync-v1'),
      supportsStagedImports =
          data['capabilities'] is List &&
          (data['capabilities'] as List).contains('import-stages-v1') {
    if (data['minimum_protocol'] != 1 ||
        data['capabilities'] is! List ||
        !(data['capabilities'] as List).contains('identity')) {
      throw const ApiFailure('unsupported_protocol', '该服务器尚未提供兼容的账号服务。');
    }
  }
  final String instanceId;
  final String syncEpoch;
  final bool supportsGroupPull;
  final bool supportsStagedImports;
}

final class TokenPair {
  TokenPair.fromJson(Map<String, Object?> data)
    : access = stringField(data, 'access_token'),
      refresh = data['refresh_token'] as String?,
      csrf = data['csrf_token'] as String?,
      sessionId = uuidField(data, 'session_id'),
      userId = uuidField(data, 'user_id') {
    if (data['token_type'] != 'bearer' ||
        data['expires_in'] is! int ||
        (data['expires_in'] as int) < 1) {
      throw invalidIdentityResponse();
    }
  }
  final String access;
  final String? refresh;
  final String? csrf;
  final String sessionId;
  final String userId;
}

final class IdentityAccount {
  const IdentityAccount({
    required this.instanceId,
    required this.userId,
    required this.username,
    required this.sessionId,
  });
  factory IdentityAccount.fromJson(Map<String, Object?> data) =>
      IdentityAccount(
        instanceId: uuidField(data, 'instance_id'),
        userId: uuidField(data, 'user_id'),
        username: stringField(data, 'username'),
        sessionId: uuidField(data, 'session_id'),
      );
  final String instanceId;
  final String userId;
  final String username;
  final String sessionId;
  DataSpace space(ServerAddress server) =>
      DataSpace(server: server, serverInstanceId: instanceId, userId: userId);
  Map<String, Object?> toJson() => {
    'instance_id': instanceId,
    'user_id': userId,
    'username': username,
    'session_id': sessionId,
  };
}

final class DeviceSession {
  DeviceSession.fromJson(Map<String, Object?> data)
    : id = uuidField(data, 'id'),
      deviceName = stringField(data, 'device_name'),
      createdAt = DateTime.parse(stringField(data, 'created_at')),
      expiresAt = DateTime.parse(stringField(data, 'expires_at')),
      revoked = data['revoked'] == true;
  final String id;
  final String deviceName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool revoked;
}

final class BookBrief {
  BookBrief.fromJson(Map<String, Object?> data)
    : id = uuidField(data, 'id'),
      name = stringField(data, 'name'),
      role = stringField(data, 'role'),
      currency = stringField(data, 'currency'),
      shared = data['shared'] == true;
  final String id;
  final String name;
  final String role;
  final String currency;
  final bool shared;
}
