import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/features/identity/identity_models.dart';

Map<String, Object?> info(List<String> capabilities) => {
  'instance_id': '00000000-0000-4000-8000-000000000001',
  'sync_epoch': '00000000-0000-4000-8000-000000000002',
  'minimum_protocol': 1,
  'capabilities': capabilities,
};

void main() {
  test('staged imports require their own explicit capability', () {
    expect(
      ServerIdentity.fromJson(
        info(['identity', 'group-sync-v1']),
      ).supportsStagedImports,
      isFalse,
    );
    expect(
      ServerIdentity.fromJson(
        info(['identity', 'group-sync-v1', 'import-stages-v1']),
      ).supportsStagedImports,
      isTrue,
    );
    expect(
      ServerIdentity.fromJson(
        info(['identity', 'import-stages-v2']),
      ).supportsStagedImports,
      isFalse,
    );
  });
  test(
    'group pull is selected only by an explicit negotiated server capability',
    () {
      expect(
        ServerIdentity.fromJson(
          info(['identity', 'sync-v1']),
        ).supportsGroupPull,
        isFalse,
      );
      expect(
        ServerIdentity.fromJson(
          info(['identity', 'sync-v1', 'group-sync-v1']),
        ).supportsGroupPull,
        isTrue,
      );
      expect(
        ServerIdentity.fromJson(
          info(['identity', 'group-sync-v2']),
        ).supportsGroupPull,
        isFalse,
      );
    },
  );
}
