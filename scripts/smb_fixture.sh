#!/usr/bin/env bash
set -euo pipefail
# Disposable authenticated fixture. No system Samba configuration is changed.
fixture_dir="$(mktemp -d /tmp/aiplayer-smb-fixture.XXXXXX)"
cleanup() {
  # On-demand RPC helpers can outlive smbd. Stop only helpers whose exact
  # config argument belongs to this fixture, never the host Samba service.
  python3 - "$fixture_dir/smb.conf" <<'PY'
import os, pathlib, signal, sys
config = ('--configfile=' + sys.argv[1]).encode()
for process in pathlib.Path('/proc').glob('[0-9]*'):
    try:
        args = (process / 'cmdline').read_bytes().split(b'\0')
        if config in args and pathlib.Path(os.fsdecode(args[0])).name in {
            'smbd', 'samba-dcerpcd', 'rpcd_classic', 'rpcd_winreg',
            'rpcd_spoolss', 'rpcd_lsad', 'rpcd_epmapper',
        }:
            os.kill(int(process.name), signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
PY
  rm -rf "$fixture_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$fixture_dir"/{share,state,private,lock,cache,ncalrpc}
python3 - "$fixture_dir/share" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1], '中文视频.mkv').write_bytes(bytes(range(256))*8192)
pathlib.Path(sys.argv[1], '隐藏属性.mkv').write_bytes(b'fixture')
with pathlib.Path(sys.argv[1], '大文件.mkv').open('wb') as output:
    output.seek(5 * 1024**3)
    output.write(bytes(range(64)))
PY
cat > "$fixture_dir/smb.conf" <<EOF
[global]
server role = standalone server
interfaces = 127.0.0.1
bind interfaces only = yes
smb ports = 1445
server min protocol = SMB3_11
server max protocol = SMB3_11
server signing = mandatory
private dir = $fixture_dir/private
state directory = $fixture_dir/state
lock directory = $fixture_dir/lock
cache directory = $fixture_dir/cache
ncalrpc dir = $fixture_dir/ncalrpc
pid directory = $fixture_dir
log file = $fixture_dir/log.%m
[video]
path = $fixture_dir/share
read only = yes
valid users = $(id -un)
hide files = /隐藏属性.mkv/
EOF
printf 'aiplayer-fixture-password\naiplayer-fixture-password\n' | smbpasswd -c "$fixture_dir/smb.conf" -s -a "$(id -un)"
printf 'Fixture listening on 127.0.0.1:1445; test user: %s\n' "$(id -un)"
# Give Samba its own process group so its shutdown handler cannot signal the
# invoking test shell while the EXIT trap reaps this fixture's RPC helpers.
smbd --foreground --configfile="$fixture_dir/smb.conf" --log-basename="$fixture_dir"
