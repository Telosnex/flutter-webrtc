const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
let Processor;
const code = fs.readFileSync('assets/local_pcm_playout_processor.js','utf8');
vm.runInNewContext(code, {
  AudioWorkletProcessor: class { constructor() { this.port={postMessage:m=>this.last=m}; } },
  Float32Array, Uint8Array, DataView, Number, Math,
  registerProcessor: (_, p) => Processor=p,
});
const source = new Processor({processorOptions:{generation:1}});
let id=0;
const send = (type,extra={}) => {source.port.onmessage({data:{id:++id,generation:1,epoch:0,type,...extra}});return source.last;};
const render = () => {const out=new Float32Array(128);source.process([],[[out]]);return out;};
const pcm=new Uint8Array(48000);new DataView(pcm.buffer).setInt16(0,-32768,true);
assert.equal(send('write',{pcm}).error,undefined);
assert.equal(render()[0],-1);
assert.equal(source.consumed,128);
for(let i=0;i<4;i++)assert.equal(send('write',{pcm}).error,undefined);
const queued=source.size;
assert.match(send('write',{pcm}).error,/backlog/);
assert.equal(source.size,queued);
assert.equal(send('clear',{epoch:1}).error,undefined);
assert.equal(source.size,0);
assert.equal(render().every(v=>v===0),true);
assert.match(send('write',{pcm}).error,/epoch/);
assert.match(send('write',{generation:2,epoch:1,pcm}).error,/generation/);
assert.match(send('write',{epoch:1,pcm:new Uint8Array(3)}).error,/Invalid/);
assert.equal(send('write',{epoch:1,pcm}).error,undefined);
assert.equal(send('stop').error,undefined);
assert.equal(source.stopped,true);
assert.match(send('write',{epoch:1,pcm}).error,/generation/);
assert.equal(render().every(v=>v===0),true);
const dart=fs.readFileSync('lib/src/web/local_pcm_playout_processor_source.dart','utf8');
assert.equal(dart.split("r'''\n")[1].split("''';")[0],code);
console.log('PASS: PCM worklet bounds, PCM16LE, epochs, clear, stop, embedded-source equality');
