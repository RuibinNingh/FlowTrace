import 'password_deriver_api.dart';
import 'password_deriver_impl.dart';

PasswordDeriver createPasswordDeriver() => _BrowserPasswordDeriver();

class _BrowserPasswordDeriver implements PasswordDeriver {
  @override
  Future<List<int>> derive(
    String password,
    List<int> salt, {
    required int iterations,
  }) => derivePassword((password, List<int>.of(salt), iterations));
}
