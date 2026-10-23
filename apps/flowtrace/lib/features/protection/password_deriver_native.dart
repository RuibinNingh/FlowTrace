import 'package:flutter/foundation.dart';

import 'password_deriver_api.dart';
import 'password_deriver_impl.dart';

PasswordDeriver createPasswordDeriver() => _NativePasswordDeriver();

class _NativePasswordDeriver implements PasswordDeriver {
  @override
  Future<List<int>> derive(
    String password,
    List<int> salt, {
    required int iterations,
  }) => compute(derivePassword, (password, List<int>.of(salt), iterations));
}
