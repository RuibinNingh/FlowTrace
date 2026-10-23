import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_store.dart';

/// The protocol uses exact JSON: money/revisions are strings and only bounded
/// nonnegative control integers are numbers. ASCII object keys sort identically
/// in Python and Dart; strings retain their original Unicode normalization.
String canonicalSyncJson(Object? value) {
  Object? sort(Object? item, int depth) {
    if (depth > 32) throw const FormatException('JSON nesting limit');
    if (item == null || item is bool) return item;
    if (item is String) {
      for (var i = 0; i < item.length; i++) {
        final unit = item.codeUnitAt(i);
        if (unit >= 0xd800 && unit <= 0xdbff) {
          if (++i >= item.length ||
              item.codeUnitAt(i) < 0xdc00 ||
              item.codeUnitAt(i) > 0xdfff) {
            throw const FormatException('Invalid Unicode');
          }
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
          throw const FormatException('Invalid Unicode');
        }
      }
      return item;
    }
    if (item is int && item >= 0 && item <= 2147483647) return item;
    if (item is List) return item.map((v) => sort(v, depth + 1)).toList();
    if (item is Map<String, Object?>) {
      final keys = item.keys.toList()..sort();
      if (keys.any((k) => k.isEmpty || k.codeUnits.any((c) => c > 127))) {
        throw const FormatException('Invalid object key');
      }
      return {for (final k in keys) k: sort(item[k], depth + 1)};
    }
    throw const FormatException('Invalid exact JSON value');
  }

  return jsonEncode(sort(value, 0));
}

String syncContentHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalSyncJson(value))).toString();

Map<String, Object?> syncObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected protocol object');
  }
  return value;
}

String syncIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
      ).hasMatch(value)) {
    throw const FormatException('Invalid identifier');
  }
  return value;
}

String syncRevision(Object? value) {
  if (value is! String ||
      !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value) ||
      value.length > 19 ||
      BigInt.parse(value) > BigInt.parse('9223372036854775807')) {
    throw const FormatException('Invalid revision');
  }
  return value;
}

Map<String, String> syncVector(Object? value) => {
  for (final entry in syncObject(value).entries)
    syncIdentifier(entry.key): syncRevision(entry.value),
};

SyncEvent decodeSyncEvent(Object? raw) {
  final event = syncObject(raw);
  const types = {'book', 'account', 'category', 'tag', 'bill', 'budget'};
  if (!types.contains(event['entity_type']) ||
      event['deleted'] is! bool ||
      event['event_index'] is! int ||
      (event['event_index'] as int) < 0 ||
      (event['event_index'] as int) > 199) {
    throw const FormatException('Invalid event');
  }
  syncRevision(event['scope_revision']);
  final deleted = event['deleted'] as bool;
  if (!deleted && event['data'] == null) {
    throw const FormatException('Missing projection');
  }
  final data = event['data'] == null
      ? <String, Object?>{}
      : syncObject(event['data']);
  canonicalSyncJson(data);
  return SyncEvent(
    scopeId: syncIdentifier(event['scope_id']),
    entityType: event['entity_type'] as String,
    entityId: syncIdentifier(event['entity_id']),
    revision: syncRevision(event['revision']),
    deleted: deleted,
    data: data,
  );
}

final class SnapshotManifest {
  SnapshotManifest._(this._json, this.expiresAt);
  final String _json;
  final DateTime expiresAt;
  Map<String, Object?> get body => syncObject(jsonDecode(_json));
  String get id => body['snapshot_id'] as String;
  String get epoch => body['sync_epoch'] as String;
  String get instanceId => body['instance_id'] as String;
  Map<String, String> get checkpoint => syncVector(body['checkpoint']);
  Map<String, String> get permissionVersions =>
      syncVector(body['permission_versions']);
  List<Map<String, Object?>> get pages =>
      (body['pages'] as List).map(syncObject).toList();

  factory SnapshotManifest.fromStatus(Map<String, Object?> status) {
    if (status['status'] != 'ready') throw StateError('Snapshot is not ready');
    final manifest = syncObject(status['manifest']);
    if (syncContentHash(manifest) != status['manifest_sha256']) {
      throw const FormatException('Snapshot manifest checksum mismatch');
    }
    final id = syncIdentifier(manifest['snapshot_id']);
    final epoch = syncIdentifier(manifest['sync_epoch']);
    syncIdentifier(manifest['instance_id']);
    final checkpoint = syncVector(manifest['checkpoint']);
    final permissions = syncVector(manifest['permission_versions']);
    if (id != status['snapshot_id'] ||
        epoch != status['sync_epoch'] ||
        canonicalSyncJson(checkpoint) !=
            canonicalSyncJson(status['checkpoint']) ||
        canonicalSyncJson(permissions) !=
            canonicalSyncJson(status['permission_versions']) ||
        checkpoint.length > 1000 ||
        checkpoint.isEmpty ||
        checkpoint.keys
            .toSet()
            .difference(permissions.keys.toSet())
            .isNotEmpty ||
        permissions.length != checkpoint.length) {
      throw const FormatException('Snapshot identity or scope mismatch');
    }
    final pages = manifest['pages'];
    if (pages is! List || pages.length > 1000 || pages.isEmpty) {
      throw const FormatException('Invalid snapshot pages');
    }
    for (var i = 0; i < pages.length; i++) {
      final page = syncObject(pages[i]);
      if (page['page_index'] != i ||
          page['item_count'] is! int ||
          (page['item_count'] as int) < 0 ||
          (page['item_count'] as int) > 200 ||
          page['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(page['sha256'] as String)) {
        throw const FormatException('Invalid page manifest');
      }
    }
    return SnapshotManifest._(
      canonicalSyncJson(manifest),
      DateTime.parse(status['expires_at'] as String).toUtc(),
    );
  }

  void checkIdentity(String instance, String expectedEpoch, {DateTime? now}) {
    if (instanceId != instance ||
        epoch != expectedEpoch ||
        !(now ?? DateTime.now().toUtc()).isBefore(expiresAt)) {
      throw StateError('Snapshot identity changed or expired');
    }
  }

  List<SyncEvent> checkPage(int index, List<Object?> items, String hash) {
    if (index < 0 ||
        index >= pages.length ||
        pages[index]['item_count'] != items.length ||
        pages[index]['sha256'] != hash ||
        syncContentHash(items) != hash) {
      throw const FormatException('Snapshot page checksum mismatch');
    }
    final events = items.map(decodeSyncEvent).toList();
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (!checkpoint.containsKey(event.scopeId) ||
          BigInt.parse(syncRevision(syncObject(items[i])['scope_revision'])) >
              BigInt.parse(checkpoint[event.scopeId]!)) {
        throw const FormatException('Snapshot event outside checkpoint');
      }
    }
    return events;
  }
}
