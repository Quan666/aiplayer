import pathlib
import shutil
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("node"), "Node is required for the browser logic regression")
class RemoteControlPageTest(unittest.TestCase):
    def test_password_drafts_are_masked_and_cleared_at_session_boundaries(self):
        source = (ROOT / "client/lib/remote/remote_control_page.dart").read_text()
        script = source.split("const remoteControlJs = r'''", 1)[1].split("''';", 1)[0]
        harness = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');
let source = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', data => source += data);
process.stdin.on('end', () => {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      value: '', hidden: false, disabled: false, events: {},
      addEventListener(event, callback) { this.events[event] = callback; },
    });
    return elements.get(id);
  }
  const document = {hidden: false, events: {}, getElementById: element,
    querySelectorAll: () => [],
    addEventListener(event, callback) { this.events[event] = callback; }};
  const window = {events: {}, addEventListener(event, callback) { this.events[event] = callback; }};
  const sockets = [];
  class WebSocket {
    static OPEN = 1;
    static CLOSED = 3;
    readyState = 1;
    sent = [];
    constructor() { sockets.push(this); }
    send(value) { this.sent.push(JSON.parse(value)); }
    close() {}
  }
  vm.runInNewContext(source, {document, window, WebSocket,
    location: {hash: '', pathname: '/', host: '127.0.0.1', protocol: 'http:'},
    history: {replaceState() {}}, setTimeout() {}, clearTimeout() {}});
  const socket = sockets[0];
  socket.onopen();
  const publish = status => socket.onmessage({data: JSON.stringify({type: 'status', ...status})});
  publish({editing: true, editSession: 3, obscured: true});
  assert.equal(element('text').hidden, true);
  assert.equal(element('password').hidden, false);
  element('password').value = 'remote-secret';
  element('send').events.click();
  assert.equal(socket.sent.at(-1).text, 'remote-secret');
  assert.equal(socket.sent.at(-1).editSession, 3);
  assert.equal(element('password').value, '');
  element('password').value = 'unfinished';
  publish({editing: true, editSession: 3, obscured: true, playing: true});
  assert.equal(element('password').value, 'unfinished');
  publish({editing: true, editSession: 4, obscured: false});
  assert.equal(element('password').value, '');
  assert.equal(element('text').hidden, false);
  assert.equal(element('password').hidden, true);
  element('text').value = 'different-field-draft';
  publish({editing: true, editSession: 5, obscured: true});
  assert.equal(element('text').value, '');
  element('password').value = 'background-secret';
  document.hidden = true;
  document.events.visibilitychange();
  assert.equal(element('password').value, '');
  element('password').value = 'disconnected-secret';
  socket.onclose();
  assert.equal(element('password').value, '');
  assert.equal(element('send').disabled, true);
  assert.equal(element('password').disabled, true);
});
"""
        subprocess.run(["node", "-e", harness], input=script, text=True, check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
