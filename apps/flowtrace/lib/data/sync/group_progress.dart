import 'dart:convert';

import 'group_protocol.dart';
import 'snapshot_protocol.dart';

/// A progress response carries no installable manifest until the server seals
/// its fixed page chain. Tokens survive app restart as local controlled cache.
final class GroupProgress {
  GroupProgress._(this.encoded, this.expiresAt);
  final String encoded;
  final DateTime expiresAt;
  late final Map<String, Object?> _value = syncObject(jsonDecode(encoded));
  Map<String, Object?> get body => syncObject(jsonDecode(encoded));
  String get id => _value['pull_id'] as String;
  String get requestId => _value['request_id'] as String;
  String get epoch => _value['sync_epoch'] as String;
  String get status => _value['status'] as String;
  String? get stepToken => groupToken(_value['next_step_token']);

  factory GroupProgress.parse(Map<String, Object?> value) {
    const fields = {
      'pull_id',
      'request_id',
      'sync_epoch',
      'expires_at',
      'status',
      'progress_code',
      'next_step_token',
      'manifest',
      'manifest_sha256',
      'first_page_token',
    };
    final encoded = canonicalSyncJson(value);
    if (value.length != fields.length ||
        !value.keys.toSet().containsAll(fields) ||
        utf8.encode(encoded).length > groupPageBytes) {
      throw const FormatException('Invalid group progress fields');
    }
    syncIdentifier(value['pull_id']);
    syncIdentifier(value['request_id']);
    syncIdentifier(value['sync_epoch']);
    final status = value['status'];
    if (status == 'ready') {
      final manifest = GroupManifest.fromStatus(value);
      return GroupProgress._(encoded, manifest.expiresAt);
    }
    if (!{'planning', 'materializing', 'expired', 'failed'}.contains(status) ||
        value['manifest'] != null ||
        value['manifest_sha256'] != null ||
        value['first_page_token'] != null) {
      throw const FormatException(
        'Group progress contains an unsealed manifest',
      );
    }
    final token = groupToken(value['next_step_token']);
    if ({'planning', 'materializing'}.contains(status)) {
      if (token == null || value['progress_code'] != status) {
        throw const FormatException('Missing group continuation');
      }
    } else if (token != null ||
        value['progress_code'] !=
            (status == 'expired' ? 'expired' : 'unavailable')) {
      throw const FormatException('Invalid terminal group progress');
    }
    final expiry = value['expires_at'];
    if (expiry is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(expiry)) {
      throw const FormatException('Group expiry requires timezone');
    }
    return GroupProgress._(encoded, DateTime.parse(expiry).toUtc());
  }
}
