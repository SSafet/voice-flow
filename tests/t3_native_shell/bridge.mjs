import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(process.argv[2], 'utf8');
const messages = [];
const page = {webkit: {messageHandlers: {voiceFlowShell: {postMessage: async body => {
  messages.push(body); return body.type === 'describe' ? {version: 1, documentId: 'doc', capabilities: []} : {accepted: true};
}}}}};
page.top = page;
vm.runInNewContext(source, {window: page, location: {origin: 'http://127.0.0.1:28471'}});
const bridge = page.voiceFlowShell;
assert.equal(bridge.version, 1);
assert.equal(page.desktopBridge, undefined);
assert(Object.isFrozen(bridge));
assert.equal(Object.getOwnPropertyDescriptor(page, 'voiceFlowShell').writable, false);
assert.equal((await bridge.describe()).documentId, 'doc');
await bridge.publishComposerTarget('doc', null);
assert.deepEqual(JSON.parse(JSON.stringify(messages[1])), {version: 1, type: 'composer', documentId: 'doc', target: null});
const captureRequest = {deliveryId: 'd', captureId: 'shot:s', offset: 0, maxBytes: 524288};
await bridge.readCapture(captureRequest);
assert.deepEqual(JSON.parse(JSON.stringify(messages.at(-1))), {version: 1, type: 'readCapture', request: captureRequest});
const input = {deliveryId: 'same-stable-id'};
assert.equal((await bridge.__deliver(input)).status, 'unavailable');
const unsubscribe = bridge.onInput(async x => ({deliveryId: x.deliveryId, status: 'accepted'}));
assert.throws(() => bridge.onInput(async () => {}));
assert.equal((await bridge.__deliver(input)).deliveryId, input.deliveryId);
assert.equal((await bridge.__deliver(input)).status, 'accepted');
unsubscribe();
bridge.onInput(async () => { throw Error('effect may already have committed'); });
assert.equal((await bridge.__deliver(input)).status, 'unconfirmed');
let wakeups = 0;
const remove = bridge.onCredentialsChanged(() => wakeups++);
bridge.__credentialsChanged();
remove();
bridge.__credentialsChanged();
assert.equal(wakeups, 1);
for (const context of [
  {window: {top: {}}, location: {origin: 'http://127.0.0.1:28471'}},
  {window: {}, location: {origin: 'http://127.0.0.1:28472'}},
]) {
  context.window.top ??= context.window;
  vm.runInNewContext(source, context);
  assert.equal(context.window.voiceFlowShell, undefined);
}
console.log('ok - native JS bridge registration, replies, conservative failures and auth wakeup');
