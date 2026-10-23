#!/usr/bin/env python3
"""Exercise the extracted Linux release's DLNA UI against the local fixture."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
from linux_pip_release_check import XInput, wait_for, application_window, geometry, progress, stop, ROOT, ARTIFACTS

class Keyboard(XInput):
    def __init__(self):
        super().__init__()
        self.x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x11.XStringToKeysym.restype = ctypes.c_ulong
        self.x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x11.XKeysymToKeycode.restype = ctypes.c_uint
        self.xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    def key(self, name, pressed):
        keycode = self.x11.XKeysymToKeycode(self.display, self.x11.XStringToKeysym(name.encode()))
        self.xtst.XTestFakeKeyEvent(self.display, keycode, pressed, 0)
        self.x11.XFlush(self.display)
    def type(self, text):
        names = {':': 'colon', '/': 'slash', '.': 'period', '-': 'minus'}
        for char in text:
            if char == ':': self.key('Shift_L', True)
            self.key(names.get(char, char), True)
            self.key(names.get(char, char), False)
            if char == ':': self.key('Shift_L', False)
            time.sleep(.025)
    def drag(self, start, end):
        self.move(*start)
        self.xtst.XTestFakeButtonEvent(self.display, 1, True, 0)
        self.x11.XFlush(self.display)
        for n in range(1, 16):
            self.move(start[0] + (end[0] - start[0]) * n / 15, start[1] + (end[1] - start[1]) * n / 15)
            time.sleep(.025)
        self.xtst.XTestFakeButtonEvent(self.display, 1, False, 0)
        self.x11.XFlush(self.display)

def inside(args):
    import gi
    gi.require_version('Gdk', '3.0')
    from gi.repository import Gdk
    archive = Path(args.archive)
    evidence = {'version': '0.5.0+6', 'archive': archive.name,
        'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'platform': 'Linux x64', 'display': 'isolated Xvfb/XTest release UI',
        'renderer': 'Controlled local DLNA fixture; no physical TV rendering', 'success': False}
    manifest = json.loads((ARTIFACTS / 'build-linux.json').read_text())
    expected = next(item for item in manifest['artifact_details'] if item['name'] == archive.name)
    assert evidence['sha256'] == expected['sha256']
    evidence['version'] = manifest['version']
    evidence['matchesBuildManifest'] = True
    input = Keyboard()
    process = dmr = None
    report = ARTIFACTS / 'linux-dlna-fixture-050.json'
    control = Path(args.control) if args.control else None
    def capture(name):
        bounds = geometry(application_window())
        pixels = Gdk.pixbuf_get_from_window(Gdk.get_default_root_window(), bounds['x'], bounds['y'], bounds['width'], bounds['height'])
        path = ARTIFACTS / f'linux_dlna_050_{name}.png'
        pixels.savev(str(path), 'png', [], [])
        return path.name
    def remote():
        try: return json.loads(report.read_text())
        except (OSError, json.JSONDecodeError): return {}
    def has_command(action, *, count=1):
        return sum(item['action'] == action for item in remote().get('commands', [])) >= count
    def frame_sample():
        bounds = geometry(application_window())
        pixels = Gdk.pixbuf_get_from_window(Gdk.get_default_root_window(),
            bounds['x'] + 320, bounds['y'] + 180, 300, 150)
        data = bytes(pixels.get_pixels())
        return {'sha256': hashlib.sha256(data).hexdigest(), 'byteRange': max(data) - min(data)}
    with tempfile.TemporaryDirectory(prefix='aiplayer-dlna-release-') as temporary:
        temporary = Path(temporary)
        with tarfile.open(archive) as bundle: bundle.extractall(temporary, filter='data')
        app = temporary / 'aiplayer-linux-x64'
        env = {k:v for k,v in os.environ.items() if k not in ['LD_LIBRARY_PATH', 'JAVA_HOME', 'JDK_HOME']}
        env.update(XDG_CONFIG_HOME=str(temporary/'config'), XDG_DATA_HOME=str(temporary/'data'),
            XDG_CACHE_HOME=str(temporary/'cache'), LIBGL_ALWAYS_SOFTWARE='1', GDK_BACKEND='x11')
        with (ARTIFACTS/'linux-dlna-release-050.log').open('w+') as log, (ARTIFACTS/'linux-dlna-fixture-050.log').open('w') as dmrlog:
            try:
                process = subprocess.Popen([str(app/'launch.sh')], cwd=app, env=env, stdout=log, stderr=log)
                wait_for(application_window, process=process)
                database = wait_for(lambda: next((temporary/'data').rglob('library.db'),None), process=process)
                time.sleep(.6)
                stop(process); process = None
                with sqlite3.connect(database) as db:
                    db.execute('INSERT OR REPLACE INTO local(key,value) VALUES(?,?)',('settings',json.dumps({'metadataStrategy':'off','enterFullscreen':False})))
                fixture = temporary/'Example S01E01.mkv'
                subprocess.run(['ffmpeg','-v','error','-nostdin','-stream_loop','9','-i',args.fixture,'-t','300','-map','0','-c','copy',str(fixture)],check=True)
                if report.exists(): report.unlink()
                dmr = subprocess.Popen([sys.executable,str(ROOT/'scripts/dlna_fixture.py'),'--port',str(args.port),
                    '--duration','300','--fixture',str(fixture),'--verify-closed','--report',str(report)],stdout=dmrlog,stderr=dmrlog)
                process = subprocess.Popen([str(app/'launch.sh'),fixture.as_uri()], cwd=app,env=env,stdout=log,stderr=log)
                wait_for(application_window, process=process)
                before = wait_for(lambda: (p if (p:=progress(database)).get('position',0)>0 else None),process=process)
                input.move(210,150);time.sleep(.4)
                evidence['before'] = {'progress':before,'screenshot':capture('before')}
                if control:
                    control.unlink(missing_ok=True)
                    state = {'database':str(database),'geometry':geometry(application_window()),'ready':True}
                    control.with_suffix('.state.json').write_text(json.dumps(state))
                    print('READY '+json.dumps(state),flush=True)
                    running = True
                    while running:
                        if process.poll() is not None: raise RuntimeError('Release exited')
                        if control.exists():
                            action = json.loads(control.read_text());control.unlink()
                            kind=action['action']
                            if kind=='click':input.click(*action['point'])
                            elif kind=='move':input.move(*action['point'])
                            elif kind=='type':input.type(action['text'])
                            elif kind=='drag':input.drag(action['start'],action['end'])
                            elif kind=='capture':print('CAPTURE '+capture(action['name']),flush=True)
                            elif kind=='finish':running=False
                            time.sleep(.35)
                            if kind not in ['finish','capture']:capture('interactive')
                        time.sleep(.15)
                else:
                    # These coordinates are calibrated against the default 1280x720
                    # extracted release. Wait on observable HTTP/SQLite state, not
                    # Flutter internals, between native XTest interactions.
                    assert geometry(application_window())['width'] == 1280
                    assert geometry(application_window())['height'] == 720
                    input.click(1143, 596)
                    time.sleep(5)  # Bounded discovery completes before manual input.
                    input.click(890, 694)
                    time.sleep(.5)
                    input.click(600, 672)
                    input.type(f'http://127.0.0.1:{args.port}/description.xml')
                    input.click(910, 672)
                    wait_for(lambda: remote().get('descriptions', 0) == 1,
                        description='manual renderer description', process=process)
                    time.sleep(.6)
                    unselected = remote()
                    assert not unselected['commands'] and not unselected['reads']
                    evidence['beforeExplicitSelection'] = {
                        'commands': 0, 'videoReads': 0, 'screenshot': capture('discovered')}
                    selected_at = time.time()
                    input.click(513, 588)
                    wait_for(lambda: len(remote().get('reads', [])) == 3 and
                        remote().get('playing') is True,
                        description='selected renderer starts and reads ranges', process=process)
                    time.sleep(.6)  # Allow the platform frame to present the new controls.
                    evidence['activeScreenshot'] = capture('active')
                    reads = remote()['reads']
                    assert [item['status'] for item in reads] == [200, 206, 206], reads
                    assert remote()['fixtureHashMatches'] and remote()['middleHashMatches']
                    assert int(reads[0]['contentLength']) == fixture.stat().st_size
                    assert all(item['contentType'] == 'video/x-matroska' for item in reads)
                    assert remote()['temporaryRelayOnly'] is True
                    assert remote()['commands'][0]['at'] >= selected_at
                    time.sleep(.4)
                    input.click(640, 642)
                    wait_for(lambda: has_command('Pause') and remote().get('playing') is False,
                        description='remote pause', process=process)
                    paused_position = remote()['lastPosition']
                    time.sleep(.7)
                    evidence['pauseScreenshot'] = capture('paused')
                    assert abs(remote()['lastPosition'] - paused_position) < .2
                    # Drag the remote seek bar to 60%, exercising pointer down,
                    # drag, and release rather than sending a direct test command.
                    input.drag((430, 584), (696, 584))
                    wait_for(lambda: any(item.get('target') == '00:03:00'
                        for item in remote().get('commands', [])),
                        description='remote seek to 180 seconds', process=process)
                    wait_for(lambda: abs(progress(database).get('position', 0)-180) < 1,
                        description='remote position saved locally', process=process)
                    evidence['remoteSeekProgress'] = progress(database)
                    time.sleep(.6)
                    evidence['seekScreenshot'] = capture('seeked')
                    input.click(570, 684)
                    wait_for(lambda: any(item.get('volume') == '35'
                        for item in remote().get('commands', [])),
                        description='remote volume 35 percent', process=process)
                    input.click(640, 642)
                    wait_for(lambda: has_command('Play', count=2) and
                        remote().get('playing') is True and remote().get('lastPosition', 0) >= 182,
                        description='remote resume advances', process=process)
                    input.click(910, 532)
                    wait_for(lambda: has_command('Stop') and remote().get('relayClosedAfterStop') is True,
                        description='remote stop invalidates temporary relay', process=process)
                    stop_position = remote()['lastPosition']
                    restored = wait_for(lambda: (p if (p:=progress(database)).get('position',0) > stop_position else None),
                        description='local restored playback advances', process=process)
                    assert restored['position'] - stop_position < 12, (stop_position, restored)
                    input.move(210,150); time.sleep(.4)
                    evidence['restoredScreenshot'] = capture('restored')
                    first_frame = frame_sample()
                    time.sleep(.6)
                    second_frame = frame_sample()
                    assert first_frame['sha256'] != second_frame['sha256']
                    assert min(first_frame['byteRange'], second_frame['byteRange']) > 100
                    evidence['localResume'] = {'remoteStopSeconds': stop_position,
                        'progress': restored, 'movingDecodedFrames': [first_frame, second_frame]}
                    input.move(210,150);time.sleep(.25)
                    close_time = time.time()
                    input.click(92,62)
                    time.sleep(2)
                    with sqlite3.connect(database) as db:
                        previews = [json.loads(row[0]) for row in db.execute("SELECT value FROM local WHERE key LIKE 'preview:%'")]
                    assert len(previews) == 1, previews
                    recent_preview = previews[0]
                    final_progress = progress(database)
                    expected_fingerprint = hashlib.sha256(f"{recent_preview['contentFingerprint']}:{int(final_progress['position']+.5)}".encode()).hexdigest()
                    assert recent_preview['fingerprint'] == expected_fingerprint
                    preview_file = Path(recent_preview['path'])
                    assert preview_file.stat().st_size > 1000
                    assert preview_file.stat().st_mtime >= close_time - .3
                    evidence['historyPreview'] = {'matchesLatestProgress': True,
                        'position': final_progress['position'], 'bytes': preview_file.stat().st_size,
                        'sha256': hashlib.sha256(preview_file.read_bytes()).hexdigest()}
                    evidence['historyScreenshot'] = capture('history')
                    final_remote = remote()
                    assert not final_remote['errors'], final_remote['errors']
                    assert not final_remote['playing'] and final_remote['relayClosedAfterStop']
                    assert {'SetAVTransportURI','Play','Pause','Seek','Stop','GetPositionInfo','SetVolume'}.issubset(
                        {item['action'] for item in final_remote['commands']})
                    assert all(int(item['contentLength']) == item['bodyBytes'] and
                        item['transferEncoding'] is None for item in final_remote['commands']), 'SOAP must use exact UTF-8 Content-Length'
                    evidence['fixedUtf8SoapLength'] = True
                log.flush();log.seek(0)
                errors=re.findall(r'(?:A RenderFlex overflowed[^\n]*|Unhandled Exception[^\n]*|Another exception was thrown[^\n]*)',log.read())
                assert not errors,errors
                evidence['runtimeErrors']=errors
                evidence['remote']=remote()
                evidence['returned']={'progress':progress(database),'screenshot':capture('returned')}
                evidence['success']=True
                print(json.dumps(evidence,ensure_ascii=False),flush=True)
            except Exception as error:
                evidence['error']=str(error)
                if application_window():evidence['failureScreenshot']=capture('failed')
                raise
            finally:
                stop(process);stop(dmr);input.close()
                (ARTIFACTS/'linux-dlna-release-050.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2))

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--archive',default=str(ARTIFACTS/'aiplayer-linux-x64.tar.gz'))
    parser.add_argument('--fixture',default='/tmp/aiplayer-media-fixture/Example S01E01.mkv')
    parser.add_argument('--port',type=int,default=1446)
    parser.add_argument('--control')
    parser.add_argument('--inside',action='store_true')
    args=parser.parse_args()
    if args.inside:inside(args)
    else:
        subprocess.run(['dbus-run-session','--','xvfb-run','-a','-s','-screen 0 1600x1000x24',sys.executable,
            str(Path(__file__).resolve()),'--inside','--archive',args.archive,'--fixture',args.fixture,
            '--port',str(args.port),*(['--control',args.control] if args.control else [])],check=True)
if __name__=='__main__':main()
