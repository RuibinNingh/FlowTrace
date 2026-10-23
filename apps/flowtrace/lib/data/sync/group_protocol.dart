import 'dart:convert';

import 'snapshot_protocol.dart';

const groupPageBytes = 512 * 1024;
const groupSessionBytes = 512 * 1024 * 1024;

void _closed(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const FormatException('Invalid group protocol fields');
  }
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid group count');
  }
  return value;
}

String groupDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid group checksum');
  }
  return value;
}

String? groupToken(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length < 20 || value.length > 128) {
    throw const FormatException('Invalid group token');
  }
  return value;
}

Map<String, String> _vector(Object? value) {
  final result = syncVector(value);
  if (result.length > 1000) {
    throw const FormatException('Too many group scopes');
  }
  return result;
}

List<Object?> _list(Object? value, int minimum, int maximum) {
  if (value is! List || value.length < minimum || value.length > maximum) {
    throw const FormatException('Invalid group collection');
  }
  return value.cast<Object?>();
}

void _bounded(Object? value) {
  if (utf8.encode(canonicalSyncJson(value)).length > groupPageBytes) {
    throw const FormatException('Group page exceeds byte budget');
  }
}

/// Immutable exact wire storage. Reading a body always returns a fresh object;
/// optional fields in historical projections are never inserted before hashing.
abstract base class GroupExactObject {
  GroupExactObject(Map<String, Object?> value)
    : encoded = canonicalSyncJson(value);
  final String encoded;
  late final Map<String, Object?> _value = syncObject(jsonDecode(encoded));
  late final String digest = syncContentHash(_value);
  Map<String, Object?> get body => syncObject(jsonDecode(encoded));
}

final class GroupPageDescriptor extends GroupExactObject {
  GroupPageDescriptor._(super.value);
  int get index => _value['page_index'] as int;
  int get count => _value['item_count'] as int;
  String get hash => _value['sha256'] as String;

  factory GroupPageDescriptor.parse(Object? raw) {
    final value = syncObject(raw);
    _closed(value, {'page_index', 'item_count', 'sha256'});
    _integer(value['page_index'], 0, 8191);
    _integer(value['item_count'], 0, 200);
    groupDigest(value['sha256']);
    return GroupPageDescriptor._(value);
  }
}

List<GroupPageDescriptor> _descriptors(Object? raw, int maximum) {
  final pages = _list(raw, 0, maximum).map(GroupPageDescriptor.parse).toList();
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].index != i) {
      throw const FormatException('Group descriptor order mismatch');
    }
  }
  return pages;
}

final class GroupManifest extends GroupExactObject {
  GroupManifest._(super.value, this.expiresAt);
  final DateTime expiresAt;
  String get id => _value['pull_id'] as String;
  String get requestId => _value['request_id'] as String;
  String get instanceId => _value['instance_id'] as String;
  String get userId => _value['user_id'] as String;
  String get clientId => _value['client_id'] as String;
  String get epoch => _value['sync_epoch'] as String;
  String get controlVersion => _value['control_version'] as String;
  int get unitCount => _value['unit_count'] as int;
  Map<String, String> get base => _vector(_value['base_cursors']);
  Map<String, String> get checkpoint => _vector(_value['checkpoint']);
  Map<String, String> get permissions => _vector(_value['permission_versions']);
  List<GroupPageDescriptor> get indexPages =>
      _descriptors(_value['index_pages'], 1024);

  factory GroupManifest.fromStatus(Map<String, Object?> status) {
    _closed(status, {
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
    });
    _bounded(status);
    if (status['status'] != 'ready' ||
        status['progress_code'] != 'ready' ||
        status['next_step_token'] != null) {
      throw const FormatException('Group manifest is not ready');
    }
    final value = syncObject(status['manifest']);
    _closed(value, {
      'protocol',
      'pull_id',
      'request_id',
      'instance_id',
      'user_id',
      'client_id',
      'sync_epoch',
      'control_version',
      'permission_versions',
      'base_cursors',
      'checkpoint',
      'unit_count',
      'index_pages',
    });
    if (value['protocol'] != 'group-sync-v1' ||
        syncContentHash(value) != groupDigest(status['manifest_sha256'])) {
      throw const FormatException('Group manifest checksum mismatch');
    }
    for (final key in [
      'pull_id',
      'request_id',
      'instance_id',
      'user_id',
      'client_id',
      'sync_epoch',
    ]) {
      syncIdentifier(value[key]);
    }
    if (value['pull_id'] != status['pull_id'] ||
        value['request_id'] != status['request_id'] ||
        value['sync_epoch'] != status['sync_epoch']) {
      throw const FormatException('Group status identity mismatch');
    }
    syncRevision(value['control_version']);
    final permissions = _vector(value['permission_versions']);
    final base = _vector(value['base_cursors']);
    final target = _vector(value['checkpoint']);
    if (permissions.isEmpty ||
        permissions.length != target.length ||
        !target.keys.toSet().containsAll(permissions.keys) ||
        !target.keys.toSet().containsAll(base.keys) ||
        base.entries.any(
          (e) => BigInt.parse(e.value) > BigInt.parse(target[e.key]!),
        )) {
      throw const FormatException('Group scope vector mismatch');
    }
    final count = _integer(value['unit_count'], 0, 10000);
    final pages = _descriptors(value['index_pages'], 1024);
    if (pages.fold<int>(0, (sum, p) => sum + p.count) != count ||
        (count > 0) != pages.isNotEmpty ||
        (count > 0) != (groupToken(status['first_page_token']) != null)) {
      throw const FormatException('Incomplete group index');
    }
    final expiry = status['expires_at'];
    if (expiry is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(expiry)) {
      throw const FormatException('Group expiry requires timezone');
    }
    return GroupManifest._(value, DateTime.parse(expiry).toUtc());
  }

  void checkIdentity(
    String instance,
    String user,
    String client,
    String syncEpoch, {
    DateTime? now,
  }) {
    if (instanceId != instance ||
        userId != user ||
        clientId != client ||
        epoch != syncEpoch ||
        !(now ?? DateTime.now().toUtc()).isBefore(expiresAt)) {
      throw StateError('Group identity changed or expired');
    }
  }
}

final class GroupUnit extends GroupExactObject {
  GroupUnit._(super.value);
  int get index => _value['unit_index'] as int;
  String get id => _value['group_id'] as String;
  int get commitCount => _value['commit_count'] as int;
  int get eventCount => _value['event_count'] as int;
  String get hash => _value['manifest_sha256'] as String;
  Map<String, String> get endCursors => _vector(_value['end_cursors']);
  List<GroupPageDescriptor> get parts =>
      _descriptors(_value['manifest_parts'], 128);

  factory GroupUnit.parse(String pullId, Object? raw) {
    final value = syncObject(raw);
    _closed(value, {
      'unit_index',
      'group_id',
      'kind',
      'commit_count',
      'event_count',
      'end_cursors',
      'manifest_parts',
      'manifest_sha256',
    });
    _bounded(value);
    _integer(value['unit_index'], 0, 9999);
    syncIdentifier(value['group_id']);
    final count = _integer(value['commit_count'], 1, 2000);
    final events = _integer(value['event_count'], count, count * 200);
    if (!{'commit', 'publication'}.contains(value['kind']) ||
        value['kind'] == 'commit' && count != 1 ||
        events == 0 ||
        _descriptors(value['manifest_parts'], 128).isEmpty) {
      throw const FormatException('Invalid group unit');
    }
    _vector(value['end_cursors']);
    final hashed = {...value}..remove('manifest_sha256');
    if (syncContentHash({'pull_id': pullId, ...hashed}) !=
        groupDigest(value['manifest_sha256'])) {
      throw const FormatException('Group unit checksum mismatch');
    }
    return GroupUnit._(value);
  }
}

final class GroupCommit extends GroupExactObject {
  GroupCommit._(super.value);
  int get index => _value['commit_index'] as int;
  int get eventCount => _value['event_count'] as int;
  String get id => _value['commit_id'] as String;
  String get hash => _value['events_sha256'] as String;

  factory GroupCommit.parse(Object? raw) {
    final value = syncObject(raw);
    _closed(value, {
      'commit_index',
      'commit_id',
      'event_count',
      'events_sha256',
    });
    _integer(value['commit_index'], 0, 1999);
    _integer(value['event_count'], 1, 200);
    syncIdentifier(value['commit_id']);
    groupDigest(value['events_sha256']);
    return GroupCommit._(value);
  }
}

/// Independent 512KiB group envelope; the ordinary v1 decoder stays unchanged.
final class GroupWirePage extends GroupExactObject {
  GroupWirePage._(super.value);
  String get pullId => _value['pull_id'] as String;
  String get kind => _value['kind'] as String;
  String? get groupId => _value['group_id'] as String?;
  int get index => _value['page_index'] as int;
  String get hash => _value['page_sha256'] as String;
  String? get nextToken => groupToken(_value['next_page_token']);
  int get byteCount => utf8.encode(encoded).length;
  int get itemCount => switch (kind) {
    'index' => (_value['units'] as List).length,
    'manifest' =>
      (_value['commits'] as List).length +
          (_value['data_pages'] as List).length,
    _ => (_value['fragments'] as List).fold<int>(
      0,
      (sum, f) => sum + (syncObject(f)['events'] as List).length,
    ),
  };

  factory GroupWirePage.parse(Map<String, Object?> value) {
    const common = {
      'pull_id',
      'kind',
      'page_index',
      'page_sha256',
      'next_page_token',
    };
    final kind = value['kind'];
    final fields = switch (kind) {
      'index' => {'units'},
      'manifest' => {'group_id', 'commits', 'data_pages'},
      'data' => {'group_id', 'fragments'},
      _ => throw const FormatException('Invalid group page kind'),
    };
    _closed(value, {...common, ...fields});
    _bounded(value);
    final pull = syncIdentifier(value['pull_id']);
    _integer(value['page_index'], 0, 8191);
    groupToken(value['next_page_token']);
    final hashed = {...value}
      ..remove('page_sha256')
      ..remove('next_page_token');
    if (syncContentHash(hashed) != groupDigest(value['page_sha256'])) {
      throw const FormatException('Group page checksum mismatch');
    }
    if (kind == 'index') {
      final units = _list(
        value['units'],
        1,
        200,
      ).map((u) => GroupUnit.parse(pull, u)).toList();
      if (units.map((u) => u.id).toSet().length != units.length ||
          List.generate(units.length, (i) => units.first.index + i).join(',') !=
              units.map((u) => u.index).join(',')) {
        throw const FormatException('Group index order mismatch');
      }
    } else {
      syncIdentifier(value['group_id']);
      if (kind == 'manifest') {
        final commits = _list(value['commits'], 0, 200);
        final pages = _list(value['data_pages'], 0, 200);
        if (commits.length + pages.length < 1 ||
            commits.length + pages.length > 200) {
          throw const FormatException('Invalid group metadata size');
        }
        commits.forEach(GroupCommit.parse);
        pages.forEach(GroupPageDescriptor.parse);
      } else {
        var total = 0;
        var previous = -1;
        for (final raw in _list(value['fragments'], 1, 200)) {
          final fragment = syncObject(raw);
          _closed(fragment, {'commit_index', 'event_offset', 'events'});
          final commit = _integer(fragment['commit_index'], 0, 1999);
          final offset = _integer(fragment['event_offset'], 0, 199);
          final events = _list(fragment['events'], 1, 200);
          if (commit <= previous || offset + events.length > 200) {
            throw const FormatException('Invalid group fragment position');
          }
          previous = commit;
          total += events.length;
          for (final rawEvent in events) {
            final event = syncObject(rawEvent);
            _closed(event, {
              'scope_id',
              'scope_revision',
              'event_index',
              'entity_type',
              'entity_id',
              'revision',
              'deleted',
              'data',
            });
            decodeSyncEvent(event);
            if (event['deleted'] != (event['data'] == null)) {
              throw const FormatException('Invalid group tombstone');
            }
          }
        }
        if (total > 200) {
          throw const FormatException('Too many group page events');
        }
      }
    }
    return GroupWirePage._(value);
  }

  void checkDescriptor(GroupPageDescriptor descriptor) {
    if (index != descriptor.index ||
        itemCount != descriptor.count ||
        hash != descriptor.hash) {
      throw const FormatException('Group page descriptor mismatch');
    }
  }
}
