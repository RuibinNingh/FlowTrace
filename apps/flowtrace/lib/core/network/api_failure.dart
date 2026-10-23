final class ApiFailure implements Exception {
  const ApiFailure(
    this.code,
    this.message, {
    this.status,
    this.offline = false,
  });
  final String code;
  final String message;
  final int? status;
  final bool offline;

  // Exception text must never contain a response body, token, URL or password.
  @override
  String toString() => 'ApiFailure($code)';

  factory ApiFailure.server(String code, int status) =>
      ApiFailure(code, switch (code) {
        'credentials_invalid' || 'invalid_credentials' => '用户名或密码不正确。',
        'username_unavailable' => '这个用户名已被使用。',
        'invite_invalid' ||
        'invite_expired' ||
        'invite_revoked' ||
        'invite_unavailable' => '邀请码无效、过期或已被使用。',
        'session_invalid' ||
        'session_revoked' ||
        'refresh_reused' ||
        'user_disabled' => '会话已失效，请重新登录。',
        'csrf_invalid' || 'origin_invalid' => '浏览器身份校验失败，请重新登录，并确认服务器允许当前页面来源。',
        'validation_error' => '提交内容不符合要求，请检查填写格式。',
        'rate_limited' => '操作过于频繁，请稍后重试。',
        'not_found' => '该记录不存在或已不可访问。',
        _ =>
          status == 401
              ? '会话已失效，请重新登录。'
              : status == 403
              ? '当前账号没有执行此操作的权限。'
              : status == 503
              ? '服务器尚未就绪，请稍后重试。'
              : '服务器未完成请求，请稍后重试。',
      }, status: status);
}
