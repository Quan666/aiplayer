String smbDialectLabel(int dialect) => switch (dialect) {
  0x0311 => 'SMB 3.1.1',
  0x0302 => 'SMB 3.0.2',
  0x0300 => 'SMB 3.0',
  0x0210 => 'SMB 2.1',
  0x0202 => 'SMB 2.0.2',
  _ => 'SMB',
};

/// Messages are selected from protocol codes; server strings and credentials
/// are never sent from the native worker to callers or logs.
class SmbFailure implements Exception {
  final int code;
  const SmbFailure(this.code);
  String get message {
    final status = code & 0xffffffff;
    final reason = switch (status) {
      0xc000006d => '登录失败，请检查用户名、密码和域。',
      0xc0000022 || 0xc00000ca => '访问被拒绝，请检查账号和共享权限。',
      0xc00000cc => '共享不存在，请检查共享名称。',
      0xc0000034 || 0xc000003a => '文件或目录不存在。',
      0xc0000071 || 0xc0000224 => '密码已过期或必须更改。',
      0xc0000072 || 0xc000006e || 0xc0000193 || 0xc0000234 => '账号已禁用、过期或被锁定。',
      0xc00000bb => '服务器不支持所需的 SMB2/3 协议。',
      0xc00000b5 => '连接超时，请检查网络和服务器状态。',
      0xc0000236 => '连接被拒绝，请检查端口和 SMB 服务。',
      0xc000023c => '网络不可达，请确认与服务器处于同一网络。',
      0xc000020c || 0xc000020d || 0xc0000241 => '服务器连接已中断，请重试。',
      _ => switch (code) {
        -2 => '共享、文件或目录不存在。',
        -13 => '访问被拒绝，请检查账号和共享权限。',
        -110 => '连接超时，请检查网络和服务器状态。',
        -111 => '连接被拒绝，请检查端口和 SMB 服务。',
        -101 || -113 => '网络不可达，请检查网络和服务器地址。',
        -9001 => 'SMB 组件无法加载，请重新安装应用。',
        -9002 => '无法取得共享列表。请检查服务器的共享枚举服务和账号权限，或在高级设置中指定共享。',
        -9003 => 'SMB 工作进程已结束，请重新连接。',
        _ => '连接或读取失败，请检查服务器地址、共享名称和凭证。',
      },
    };
    final label = code == 0
        ? ''
        : (status & 0xff000000) == 0xc0000000
        ? '（0x${status.toRadixString(16).toUpperCase()}）'
        : '（$code）';
    return 'SMB$label · $reason';
  }

  @override
  String toString() => message;
}
