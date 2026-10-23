import 'dart:convert';
import 'dart:io';

/// Load the original shared files, without maintaining a second expected set.
Map<String, dynamic> loadLedgerFixture(String name) {
  var directory = Directory.current.absolute;
  while (true) {
    final file = File('${directory.path}/contracts/fixtures/ledger/$name');
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Shared ledger fixture not found: $name');
    }
    directory = parent;
  }
}

Map<String, dynamic> copyMap(Map value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
