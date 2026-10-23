import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'data_tools_models.dart';
import 'stage_import_models.dart';

/// This is separate from the frozen create/command body. Defaults are expanded
/// only for comparing the server's desired mapping state after a lost response.
Map<String, Object?> normalizeStageMapping(Map<String, Object?> input) {
  final raw = stageMapping(input);
  Map<String, Object?>? template;
  if (raw['template_mapping'] != null) {
    final source = dataToolsObject(raw['template_mapping']);
    template = {
      'scope_id': source['scope_id'],
      'timezone': source['timezone'],
      'currency': source['currency'] ?? 'CNY',
      'currency_scale': source['currency_scale'] ?? 2,
      for (final key in [
        'account_names',
        'category_names',
        'tag_names',
        'image_urls',
      ])
        key: source[key] ?? <String, Object?>{},
    };
  }
  return {
    'source_namespace': raw['source_namespace'] ?? 'file-import',
    'template_mapping': template,
    for (final key in [
      'scope_mapping',
      'resource_mapping',
      'attachment_transfers',
    ])
      key: raw[key] ?? <String, Object?>{},
  };
}

int _scalarCompare(String left, String right) {
  final a = left.runes.iterator, b = right.runes.iterator;
  while (true) {
    final hasA = a.moveNext(), hasB = b.moveNext();
    if (!hasA || !hasB) {
      return hasA
          ? 1
          : hasB
          ? -1
          : 0;
    }
    final difference = a.current.compareTo(b.current);
    if (difference != 0) return difference;
  }
}

/// Python canonical JSON orders arbitrary resource-name keys by Unicode scalar
/// value. Dart's UTF-16 String.compareTo gives a different order for emoji/PUA.
String canonicalStageJson(Object? input) {
  dataToolsFrozenJson(input);
  Object? ordered(Object? value) {
    if (value is List) return value.map(ordered).toList();
    if (value is Map) {
      final map = dataToolsObject(value);
      final keys = map.keys.toList()..sort(_scalarCompare);
      return {for (final key in keys) key: ordered(map[key])};
    }
    return value;
  }

  return jsonEncode(ordered(input));
}

String stageMappingHash(Map<String, Object?> mapping) => sha256
    .convert(utf8.encode(canonicalStageJson(normalizeStageMapping(mapping))))
    .toString();
