abstract interface class PasswordDeriver {
  Future<List<int>> derive(
    String password,
    List<int> salt, {
    required int iterations,
  });
}
