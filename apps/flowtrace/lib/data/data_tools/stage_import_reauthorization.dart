import 'data_tools_models.dart';
import 'stage_import_models.dart';

/// Same-owner, current-session read-only confirmation data. It does not change
/// a stage's origin or authorize any financial action.
final class StageImportReauthorization extends StageImportWire {
  StageImportReauthorization._(super.value);
  String get stageId => value['stage_id'] as String;
  String get batchId => value['batch_id'] as String;
  int get version => value['stage_version'] as int;
  String get format => value['format'] as String;
  int get expectedBytes => value['expected_bytes'] as int;
  String get sourceSha256 => value['source_sha256'] as String;
  String get mappingHash => value['mapping_hash'] as String;
  String get status => value['status'] as String;
  bool get expired => value['expired'] as bool;
  bool get sourceReleased => value['source_released'] as bool;
  factory StageImportReauthorization.parse(Map<String, Object?> raw) {
    dataToolsKeys(raw, {
      'stage_id',
      'batch_id',
      'stage_version',
      'format',
      'expected_bytes',
      'source_sha256',
      'mapping_hash',
      'status',
      'source_released',
      'expired',
    });
    dataToolsUuid(raw['stage_id']);
    dataToolsUuid(raw['batch_id']);
    stageInteger(raw['stage_version'], 1, 2147483647);
    ImportFileKind.parse(raw['format']);
    stageInteger(raw['expected_bytes'], 1, stageImportSourceLimit);
    stageDigest(raw['source_sha256']);
    stageDigest(raw['mapping_hash']);
    if (!stageImportStatuses.contains(raw['status']) ||
        raw['source_released'] is! bool ||
        raw['expired'] is! bool ||
        raw['source_released'] == true &&
            !{'applied', 'undoing', 'undone'}.contains(raw['status'])) {
      throw const FormatException('重新授权核对资料无效。');
    }
    return StageImportReauthorization._(raw);
  }
}
