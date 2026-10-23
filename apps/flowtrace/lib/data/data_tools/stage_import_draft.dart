import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'data_tools_models.dart';
import 'stage_import_mapping.dart';
import 'stage_import_models.dart';
import 'stage_import_requirements.dart';

String stageRequirementKey(StageImportRequirement item) =>
    sha256.convert(utf8.encode(item.identity)).toString();

/// Resource choices survive navigation/restart. Stored cursors describe the
/// last reviewed page; a reopened reader still verifies the full SHA from page1.
final class StageImportMappingDraft extends StageImportWire {
  StageImportMappingDraft._(super.value);
  late final Map<String, Object?> _metadata = dataToolsObject(
    jsonDecode(encoded),
  );
  late final Map<String, Object?> _choices = dataToolsObject(
    _metadata['choices'],
  );
  int get baseVersion => _metadata['base_version'] as int;
  String get requirementsHash => _metadata['requirements_hash'] as String;
  int get reviewedPosition => _metadata['reviewed_position'] as int;
  String? get nextCursor => _metadata['next_cursor'] as String?;
  Map<String, Object?> get mapping => dataToolsObject(value['mapping']);
  Map<String, Object?> get choices => dataToolsObject(value['choices']);
  int get choiceCount => _choices.length;
  bool matches(int version, String? hash) =>
      baseVersion == version && requirementsHash == hash;
  String? choice(StageImportRequirement item) =>
      _choices[stageRequirementKey(item)] as String?;

  factory StageImportMappingDraft.create({
    required int version,
    required String requirementsHash,
    required Map<String, Object?> mapping,
  }) => StageImportMappingDraft.parse({
    'version': 1,
    'base_version': version,
    'requirements_hash': requirementsHash,
    'mapping': stageMapping(mapping),
    'choices': <String, Object?>{},
    'reviewed_position': 0,
    'next_cursor': null,
  });

  factory StageImportMappingDraft.parse(Map<String, Object?> raw) {
    dataToolsKeys(
      raw,
      {
        'version',
        'base_version',
        'requirements_hash',
        'mapping',
        'choices',
        'reviewed_position',
        'next_cursor',
      },
      {'images'},
    );
    if (raw['version'] != 1) {
      throw const FormatException('资源选择草稿版本无效。');
    }
    stageInteger(raw['base_version'], 1, 2147483647);
    stageDigest(raw['requirements_hash']);
    stageMapping(dataToolsObject(raw['mapping']));
    stageInteger(raw['reviewed_position'], 0, 200000);
    final cursor = raw['next_cursor'];
    if (cursor != null &&
        (cursor is! String || cursor.isEmpty || cursor.length > 512)) {
      throw const FormatException('资源选择草稿分页无效。');
    }
    final choices = dataToolsObject(raw['choices']);
    if (choices.length > 200000) {
      throw const FormatException('资源选择数量超过范围。');
    }
    for (final choice in choices.entries) {
      stageDigest(choice.key);
      dataToolsUuid(choice.value);
    }
    final images = dataToolsObject(raw['images'] ?? <String, Object?>{});
    if (images.length > choices.length) {
      throw const FormatException('原图选择证明数量不匹配。');
    }
    final mapping = dataToolsObject(raw['mapping']);
    for (final entry in images.entries) {
      stageDigest(entry.key);
      final proof = dataToolsObject(entry.value);
      dataToolsKeys(proof, {
        'source_kind',
        'source_key',
        'uploaded_id',
        'target_book_id',
        'sha256',
        'size_bytes',
        'media_type',
      });
      final uploaded = dataToolsUuid(proof['uploaded_id']);
      final book = dataToolsUuid(proof['target_book_id']);
      final descriptor = DataAttachmentSource.fromJson({
        'source_id': uploaded,
        'sha256': proof['sha256'],
        'size_bytes': proof['size_bytes'],
        'media_type': proof['media_type'],
      });
      final source = proof['source_key'];
      if (source is! String ||
          source.isEmpty ||
          source.runes.length > 2000 ||
          !{'name', 'identifier'}.contains(proof['source_kind'])) {
        throw const FormatException('原图来源证明无效。');
      }
      if (proof['source_kind'] == 'identifier') {
        dataToolsUuid(source);
      }
      final actual = proof['source_kind'] == 'identifier'
          ? dataToolsObject(
              mapping['resource_mapping'] ?? <String, Object?>{},
            )[source]
          : dataToolsObject(
              dataToolsObject(mapping['template_mapping'])['image_urls'] ??
                  <String, Object?>{},
            )[source];
      final identity = sha256
          .convert(
            utf8.encode(
              canonicalStageJson(['image', proof['source_kind'], null, source]),
            ),
          )
          .toString();
      if (entry.key != identity ||
          choices[entry.key] != descriptor.sourceId ||
          actual != uploaded ||
          dataToolsObject(
                mapping['attachment_transfers'] ?? <String, Object?>{},
              )[uploaded] !=
              book) {
        throw const FormatException('原图来源、上传与目标账本未成对保存。');
      }
    }
    return StageImportMappingDraft._(raw);
  }

  StageImportMappingDraft withPage(StageImportRequirementsPage page) {
    if (page.version != baseVersion || page.hash != requirementsHash) {
      throw const FormatException('原始资源清单已变化，原选择保留。');
    }
    return StageImportMappingDraft.parse({
      ...body,
      'reviewed_position': page.items.lastOrNull?.position ?? 0,
      'next_cursor': page.nextCursor,
    });
  }

  StageImportMappingDraft withChoice(
    StageImportRequirement item,
    String target,
  ) {
    dataToolsUuid(target);
    if (item.kind == 'image') {
      throw const FormatException('请通过原图选择与上传流程设置图片。');
    }
    final updated = mapping;
    if (item.sourceKind == 'name') {
      final template = dataToolsObject(updated['template_mapping']);
      final field = switch (item.kind) {
        'account' => 'account_names',
        'category' => 'category_names',
        'tag' => 'tag_names',
        _ => throw const FormatException('未知原始资源名称。'),
      };
      final names = dataToolsObject(template[field] ?? <String, Object?>{});
      template[field] = {...names, item.sourceKey: target};
      updated['template_mapping'] = template;
    } else {
      final field = switch (item.kind) {
        'scope' => 'scope_mapping',
        'resource' => 'resource_mapping',
        _ => throw const FormatException('未知原始资源标识。'),
      };
      updated[field] = {
        ...dataToolsObject(updated[field] ?? <String, Object?>{}),
        item.sourceKey: target,
      };
    }
    return StageImportMappingDraft.parse({
      ...body,
      'mapping': updated,
      'choices': {...choices, stageRequirementKey(item): target},
    });
  }

  StageImportMappingDraft withImageChoice(
    StageImportRequirement item, {
    required String uploadedId,
    required String targetBookId,
    required Uint8List selectedBytes,
    required String mediaType,
  }) {
    dataToolsUuid(uploadedId);
    dataToolsUuid(targetBookId);
    if (item.kind != 'image' ||
        selectedBytes.isEmpty ||
        selectedBytes.length > 10 * 1024 * 1024 ||
        !{'image/png', 'image/jpeg', 'image/webp'}.contains(mediaType)) {
      throw const FormatException('请选择受支持且不超过10MiB的原图。');
    }
    final digest = sha256.convert(selectedBytes).toString();
    final manifest = item.attachment;
    if (manifest != null &&
        (manifest.sha256 != digest ||
            manifest.sizeBytes != selectedBytes.length ||
            manifest.mediaType != mediaType)) {
      throw const FormatException('所选原图与文件校验清单不一致。');
    }
    final updated = mapping;
    final key = stageRequirementKey(item);
    final images = dataToolsObject(value['images'] ?? <String, Object?>{});
    final oldNames = updated['template_mapping'] == null
        ? <String, Object?>{}
        : dataToolsObject(
            dataToolsObject(updated['template_mapping'])['image_urls'] ??
                <String, Object?>{},
          );
    final oldResources = dataToolsObject(
      updated['resource_mapping'] ?? <String, Object?>{},
    );
    final previousUpload = item.sourceKind == 'name'
        ? oldNames[item.sourceKey]
        : oldResources[item.sourceKey];
    final transfers = dataToolsObject(
      updated['attachment_transfers'] ?? <String, Object?>{},
    );
    if (transfers[uploadedId] != null &&
        transfers[uploadedId] != targetBookId) {
      throw const FormatException('同一上传原图不能同时迁移到两个账本，请分别选择并上传。');
    }
    if (item.sourceKind == 'name') {
      final template = dataToolsObject(updated['template_mapping']);
      if (template['scope_id'] != targetBookId) {
        throw const FormatException('钱迹原图应迁移到当前选择的目标账本。');
      }
      template['image_urls'] = {
        ...dataToolsObject(template['image_urls'] ?? <String, Object?>{}),
        item.sourceKey: uploadedId,
      };
      updated['template_mapping'] = template;
    } else {
      updated['resource_mapping'] = {
        ...dataToolsObject(updated['resource_mapping'] ?? <String, Object?>{}),
        item.sourceKey: uploadedId,
      };
    }
    final imageNames = updated['template_mapping'] == null
        ? <String, Object?>{}
        : dataToolsObject(
            dataToolsObject(updated['template_mapping'])['image_urls'] ??
                <String, Object?>{},
          );
    final resources = dataToolsObject(
      updated['resource_mapping'] ?? <String, Object?>{},
    );
    if (previousUpload != null &&
        previousUpload != uploadedId &&
        !imageNames.values.contains(previousUpload) &&
        !resources.values.contains(previousUpload)) {
      transfers.remove(previousUpload);
    }
    updated['attachment_transfers'] = {...transfers, uploadedId: targetBookId};
    return StageImportMappingDraft.parse({
      ...body,
      'mapping': updated,
      'choices': {...choices, key: uploadedId},
      'images': {
        ...images,
        key: {
          'source_kind': item.sourceKind,
          'source_key': item.sourceKey,
          'uploaded_id': uploadedId,
          'target_book_id': targetBookId,
          'sha256': digest,
          'size_bytes': selectedBytes.length,
          'media_type': mediaType,
        },
      },
    });
  }

  int get requestBytes => utf8
      .encode(
        dataToolsFrozenJson({'stage_version': baseVersion, 'mapping': mapping}),
      )
      .length;
  String get desiredHash => stageMappingHash(mapping);
}
