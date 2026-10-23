import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Keep the bundled, unmodified font's notices available to Flutter's standard
/// license viewer as well as in the packaged asset beside the font itself.
void registerBundledLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans CJK SC',
    ], await rootBundle.loadString('assets/fonts/LICENSE/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'Roboto',
    ], await rootBundle.loadString('assets/fonts/LICENSE/Roboto.txt'));
  });
}
