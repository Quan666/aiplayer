#!/usr/bin/env python3
"""Local, deterministic DLNA renderer fixture; does not render or transcode.

Android emulator example:
  adb -s emulator-5554 reverse tcp:1446 tcp:1446
  python3 scripts/dlna_fixture.py --adb /path/to/adb --serial emulator-5554 \
    --report artifacts/dlna-emulator-050.json
Then add http://127.0.0.1:1446/description.xml in the cast device sheet.
The fixture uses adb forward to read the app's temporary relay without relaxing
its selected-renderer IP restriction. Only headers and hashes enter the report.
"""
import argparse
import hashlib
import http.client
import json
import re
import signal
import subprocess
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

DESC = '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>映库投屏测试电视</friendlyName><manufacturer>AIPlayer test fixture</manufacturer>
<UDN>uuid:aiplayer-test-renderer-050</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/control</controlURL><eventSubURL>/event</eventSubURL><SCPDURL>/transport.xml</SCPDURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><controlURL>/volume</controlURL><eventSubURL>/volume-event</eventSubURL><SCPDURL>/volume.xml</SCPDURL></service>
</serviceList></device></root>'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=1446)
    parser.add_argument('--adb')
    parser.add_argument('--serial')
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--report', default='/tmp/aiplayer-dlna-fixture.json')
    parser.add_argument('--fixture', help='Optional local media to compare the first range hash')
    parser.add_argument('--verify-closed', action='store_true', help='Probe the relay after Stop to verify session URL invalidation')
    parser.add_argument('--seek-error', action='store_true', help='Return UPnP 710 for seek testing')
    args = parser.parse_args()
    lock = threading.RLock()
    report = {'fixture': 'DLNA controlled renderer; no real TV rendering', 'commands': [], 'reads': [], 'errors': [], 'descriptions': 0}
    state = {'position': 0.0, 'started': None, 'uri': None, 'volume': 50, 'playing': False, 'probeAddress': None}
    forwards = set()

    def save():
        path = Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + '.tmp')
        with lock:
            temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2))
            temporary.replace(path)

    def adb(*arguments):
        command = [args.adb]
        if args.serial:
            command += ['-s', args.serial]
        return subprocess.check_output(command + list(arguments), text=True, timeout=8).strip()

    def position():
        current = state['position']
        if state['playing'] and state['started'] is not None:
            current += time.monotonic() - state['started']
        return min(args.duration, current)

    def freeze():
        state['position'] = position()
        state['started'] = None

    def clock(seconds):
        value = int(seconds)
        return f'{value // 3600:02}:{value // 60 % 60:02}:{value % 60:02}'

    def probe(value):
        parsed = urllib.parse.urlsplit(value)
        try:
            relay_port = parsed.port
            if args.adb:
                relay_port = int(adb('forward', 'tcp:0', f'tcp:{parsed.port}'))
                with lock:
                    forwards.add(relay_port)
            host = '127.0.0.1' if args.adb else parsed.hostname
            with lock:
                state['probeAddress'] = (host, relay_port, parsed.path)
            def read(method, byte_range=None):
                connection = http.client.HTTPConnection(host, relay_port, timeout=6)
                try:
                    headers = {'Range': byte_range} if byte_range else {}
                    connection.request(method, parsed.path, headers=headers)
                    response = connection.getresponse()
                    data = response.read(65536 if method == 'GET' else 0)
                    item = {'method': method, 'range': byte_range, 'status': response.status,
                        'contentType': response.getheader('Content-Type'),
                        'contentRange': response.getheader('Content-Range'),
                        'contentLength': response.getheader('Content-Length'),
                        'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest() if data else None}
                    with lock:
                        report['reads'].append(item)
                    save()
                    return item
                finally:
                    connection.close()
            head = read('HEAD')
            size = int(head['contentLength'] or 0)
            first = read('GET', f'bytes=0-{min(65535, size - 1)}')
            if args.fixture:
                with Path(args.fixture).open('rb') as fixture_file:
                    expected = fixture_file.read(min(65536, size))
                with lock:
                    report['fixtureHashMatches'] = first['sha256'] == hashlib.sha256(expected).hexdigest()
            if size > 65536:
                offset = size // 2
                middle = read('GET', f'bytes={offset}-{min(size - 1, offset + 65535)}')
                if args.fixture:
                    with Path(args.fixture).open('rb') as fixture_file:
                        fixture_file.seek(offset)
                        expected = fixture_file.read(min(65536, size - offset))
                    with lock:
                        report['middleHashMatches'] = middle['sha256'] == hashlib.sha256(expected).hexdigest()
            save()
        except Exception as error:
            with lock:
                report['errors'].append(type(error).__name__)
            save()

    def verify_closed():
        time.sleep(2)
        with lock:
            address = state['probeAddress']
        if address is None:
            return
        connection = http.client.HTTPConnection(address[0], address[1], timeout=2)
        closed = False
        try:
            connection.request('HEAD', address[2])
            response = connection.getresponse()
            closed = response.status in (403, 404, 410)
            response.read()
        except (OSError, http.client.HTTPException):
            closed = True
        finally:
            connection.close()
        with lock:
            report['relayClosedAfterStop'] = closed
        save()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass
        def send_xml(self, payload, status=200):
            data = payload.encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'text/xml; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        def do_GET(self):
            if self.path == '/description.xml':
                with lock:
                    report['descriptions'] += 1
                save()
            self.send_xml(DESC if self.path == '/description.xml' else '<error/>', 200 if self.path == '/description.xml' else 404)
        def do_POST(self):
            payload = bytearray()
            try:
                if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                    while True:
                        length = int(self.rfile.readline(128).split(b';')[0].strip(), 16)
                        if length == 0:
                            # Consume the trailer terminator, bounding optional headers.
                            for _ in range(64):
                                if self.rfile.readline(8192) in (b'\r\n', b'\n', b''):
                                    break
                            break
                        if length < 0 or len(payload) + length > 1048576:
                            raise ValueError('Request too large')
                        payload.extend(self.rfile.read(length))
                        if self.rfile.read(2) != b'\r\n':
                            raise ValueError('Invalid chunk terminator')
                else:
                    length = int(self.headers.get('Content-Length', 0))
                    if not 0 < length <= 1048576:
                        raise ValueError('Invalid body length')
                    payload.extend(self.rfile.read(length))
                document = ET.fromstring(payload)
            except (ValueError, ET.ParseError):
                self.send_xml('<error/>', 400)
                return
            body = next(element for element in document.iter() if element.tag.split('}')[-1] == 'Body')
            command = list(body)[0]
            action = command.tag.split('}')[-1]
            values = {child.tag.split('}')[-1]: child.text or '' for child in command}
            result = {}
            code = None
            with lock:
                report['commands'].append({'action': action, 'at': time.time(),
                    'target': values.get('Target'), 'volume': values.get('DesiredVolume'),
                    'bodyBytes': len(payload), 'contentLength': self.headers.get('Content-Length'),
                    'transferEncoding': self.headers.get('Transfer-Encoding')})
                if action == 'SetAVTransportURI':
                    value = values.get('CurrentURI', '')
                    parsed = urllib.parse.urlsplit(value)
                    report['temporaryRelayOnly'] = parsed.scheme == 'http' and parsed.hostname == '127.0.0.1' and bool(re.fullmatch(r'/[A-Za-z0-9_-]{43}/video\.[A-Za-z0-9]+', parsed.path))
                    state.update(uri=value, position=0.0, started=None, playing=False)
                    threading.Thread(target=probe, args=(value,), daemon=True).start()
                elif action == 'Play':
                    freeze(); state.update(playing=True, started=time.monotonic())
                elif action in ('Pause', 'Stop'):
                    freeze(); state['playing'] = False
                    if action == 'Stop' and args.verify_closed:
                        threading.Thread(target=verify_closed, daemon=True).start()
                elif action == 'Seek':
                    if args.seek_error:
                        code = 710
                    else:
                        parts = [float(part) for part in values['Target'].split(':')]
                        state['position'] = min(args.duration, parts[0] * 3600 + parts[1] * 60 + parts[2])
                        state['started'] = time.monotonic() if state['playing'] else None
                elif action == 'SetVolume':
                    state['volume'] = int(values['DesiredVolume'])
                elif action == 'GetPositionInfo':
                    result = {'Track': '1', 'TrackDuration': clock(args.duration), 'RelTime': clock(position()),
                        'AbsTime': clock(position()), 'TrackMetaData': '', 'TrackURI': ''}
                elif action == 'GetTransportInfo':
                    result = {'CurrentTransportState': 'PLAYING' if state['playing'] else 'PAUSED_PLAYBACK',
                        'CurrentTransportStatus': 'OK', 'CurrentSpeed': '1'}
                report['lastPosition'] = position()
                report['playing'] = state['playing']
            save()
            if code:
                self.send_xml(f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>{code}</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>', 500)
            else:
                service = 'RenderingControl' if self.path == '/volume' else 'AVTransport'
                fields = ''.join(f'<{name}>{escape(str(value))}</{name}>' for name, value in result.items())
                self.send_xml(f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:{action}Response xmlns:u="urn:schemas-upnp-org:service:{service}:1">{fields}</u:{action}Response></s:Body></s:Envelope>')

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    def shutdown(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f'DLNA fixture: http://127.0.0.1:{args.port}/description.xml', flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        for port in forwards:
            if args.adb:
                try:
                    adb('forward', '--remove', f'tcp:{port}')
                except Exception:
                    pass
        save()

if __name__ == '__main__':
    main()
