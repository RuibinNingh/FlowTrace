/// Explicitly selected for locally hosted test deliverables. Normal release
/// builds retain HTTPS for native identity transport. ServerAddress continues
/// to reject public HTTP origins in every profile.
const localTestBuild = bool.fromEnvironment('FLOWTRACE_LOCAL_TEST');

bool allowsLocalHttp({
  required bool debug,
  required bool web,
  required String webHost,
  bool localTest = localTestBuild,
}) =>
    debug ||
    localTest ||
    (web && {'localhost', '127.0.0.1', '::1'}.contains(webHost));
