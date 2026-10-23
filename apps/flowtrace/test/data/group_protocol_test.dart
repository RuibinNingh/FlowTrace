import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/data/sync/group_protocol.dart';
import 'package:flowtrace/data/sync/snapshot_protocol.dart';

Map<String, Object?> fixture() => syncObject(
  jsonDecode(
    File(
      '../../server/tests/sync/groups/group-ready-golden.json',
    ).readAsStringSync(),
  ),
);

void rehash(Map<String, Object?> page) {
  final body = {...page}
    ..remove('page_sha256')
    ..remove('next_page_token');
  page['page_sha256'] = syncContentHash(body);
}

void main() {
  test('Python golden exact hierarchical checksums and big money survive', () {
    final raw = fixture();
    final manifest = GroupManifest.fromStatus(syncObject(raw['status']));
    final index = GroupWirePage.parse(syncObject(raw['index_page']));
    index.checkDescriptor(manifest.indexPages.single);
    final unit = GroupUnit.parse(
      manifest.id,
      (index.body['units'] as List).single,
    );
    final metadata = GroupWirePage.parse(syncObject(raw['unit_manifest_page']));
    metadata.checkDescriptor(unit.parts.single);
    final data = GroupWirePage.parse(syncObject(raw['data_page']));
    data.checkDescriptor(
      GroupPageDescriptor.parse((metadata.body['data_pages'] as List).single),
    );
    final commit = GroupCommit.parse((metadata.body['commits'] as List).single);
    final events =
        syncObject((data.body['fragments'] as List).single)['events'] as List;
    expect(syncContentHash(events), commit.hash);
    expect(canonicalSyncJson(events), contains('9007199254740993'));
    expect(canonicalSyncJson(events), isNot(contains('sort_order')));
    expect(manifest.unitCount, 1);
    final mutated = manifest.body..['unit_count'] = 9;
    expect(mutated['unit_count'], 9);
    expect(manifest.unitCount, 1);
    manifest.checkIdentity(
      manifest.instanceId,
      manifest.userId,
      manifest.clientId,
      manifest.epoch,
      now: DateTime.utc(2026, 10, 22),
    );
    expect(
      () => manifest.checkIdentity(
        manifest.instanceId,
        manifest.userId,
        manifest.clientId,
        manifest.epoch,
        now: DateTime.utc(2026, 10, 24),
      ),
      throwsStateError,
    );
  });

  test(
    'changed raw, cross-pull, unknown fields and bad tombstone are rejected',
    () {
      final raw = fixture();
      for (final mutation in <void Function(Map<String, Object?>)>[
        (page) => page['pull_id'] = '00000000-0000-0000-0000-000000000099',
        (page) => page['unknown'] = true,
        (page) {
          final fragment = syncObject((page['fragments'] as List).single);
          final event = syncObject((fragment['events'] as List).single);
          event['deleted'] = true;
          rehash(page);
        },
      ]) {
        final page = syncObject(
          jsonDecode(canonicalSyncJson(raw['data_page'])),
        );
        mutation(page);
        expect(() => GroupWirePage.parse(page), throwsFormatException);
      }
    },
  );

  test(
    'descriptor binds counts, local page position and full envelope bytes',
    () {
      final raw = fixture();
      final data = GroupWirePage.parse(syncObject(raw['data_page']));
      for (final value in [
        {'page_index': 1, 'item_count': 1, 'sha256': data.hash},
        {'page_index': 0, 'item_count': 2, 'sha256': data.hash},
        {'page_index': 0, 'item_count': 1, 'sha256': '0' * 64},
      ]) {
        expect(
          () => data.checkDescriptor(GroupPageDescriptor.parse(value)),
          throwsFormatException,
        );
      }
      final page = syncObject(raw['data_page']);
      final event = syncObject(
        (syncObject((page['fragments'] as List).single)['events'] as List)
            .single,
      );
      syncObject(event['data'])['large'] = '中' * groupPageBytes;
      rehash(page);
      expect(() => GroupWirePage.parse(page), throwsFormatException);
    },
  );
}
