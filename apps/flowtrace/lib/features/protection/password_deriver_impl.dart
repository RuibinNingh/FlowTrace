import 'package:cryptography/cryptography.dart';

/// The browser implementation selects Web Crypto when available. Native calls
/// run this on compute's worker isolate so password verification does not block
/// the UI thread. Passwords and derived material are never logged or put in URLs.
Future<List<int>> derivePassword((String, List<int>, int) input) async {
  final algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: input.$3,
    bits: 256,
  );
  final key = await algorithm.deriveKeyFromPassword(
    password: input.$1,
    nonce: input.$2,
  );
  return key.extractBytes();
}
