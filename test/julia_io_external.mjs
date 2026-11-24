// The embedder's handles of js/julia_io.mjs (`events.external`, `ready`), as a host library uses them,
// without a Julia module: `poll` is called from a tiny Wasm module that only forwards to the import (a suspension
// needs a Wasm frame under WebAssembly.promising). Prints "what: true|false" per check (test/tasks.jl).
import { makeJuliaIOEvents } from '../js/julia_io.mjs';

const out = [];
const check = (what, ok) => out.push(`${what}: ${!!ok}`);
const turns = (ms) => new Promise((r) => setTimeout(r, ms));

function pollModule() {
  // (module (import "io" "poll" (func $p (param i32 i32 i64 i32 i32) (result i32)))
  //         (memory (import "io" "mem") 1) (func (export "poll") (param i32 i32 i64 i32 i32) (result i32)
  //           local.get 0 local.get 1 local.get 2 local.get 3 local.get 4 call $p))
  const type = [0x60, 5, 0x7f, 0x7f, 0x7e, 0x7f, 0x7f, 1, 0x7f];
  const sec = (id, body) => [id, body.length, ...body];
  const str = (s) => [s.length, ...[...s].map((c) => c.charCodeAt(0))];
  const types = sec(1, [1, ...type]);
  const imports = sec(2, [2, ...str('io'), ...str('poll'), 0, 0, ...str('io'), ...str('mem'), 2, 0, 1]);
  const funcs = sec(3, [1, 0]);
  const exps = sec(7, [1, ...str('poll'), 0, 1]);
  const body = [0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0x10, 0, 0x0b];
  const code = sec(10, [1, body.length, ...body]);
  return new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...types, ...imports, ...funcs, ...exps, ...code]);
}
const pollBytes = pollModule();
// the events of a new instance, and its poll: interest at 0, out at 64
function setup() {
  const mem = new WebAssembly.Memory({ initial: 1 });
  const events = makeJuliaIOEvents({ memory: mem });
  const dv = new DataView(mem.buffer);
  const inst = new WebAssembly.Instance(new WebAssembly.Module(pollBytes), { io: { poll: events.imports.poll, mem } });
  const poll = WebAssembly.promising(inst.exports.poll);
  const pollOf = async (hs, timeout) => {
    hs.forEach((h, i) => dv.setInt32(4 * i, h, true));
    const n = await poll(0, hs.length, BigInt(timeout), 64, 8);
    return [...Array(Math.max(n, 0))].map((_, i) => dv.getInt32(64 + 4 * i, true));
  };
  // errmsg(h), at 128
  const errmsg = (h) => Buffer.from(mem.buffer, 128, events.imports.errmsg(h, 128, 256)).toString();
  return { events, pollOf, errmsg };
}
const { events, pollOf, errmsg } = setup();

let closed = 0;
const a = events.external({ onClose: () => { closed++; } });
const b = events.external();
check('a pending external handle is not ready', events.handleState(a).ready === false && events.handleState(a).kind === 'external');
check('ready makes it ready (once)', events.ready(a) === true && events.handleState(a).ready && events.ready(a) === true);
check('a poll finds the ready one only', JSON.stringify(await pollOf([a, b], 0)) === JSON.stringify([a]));
// a poll that suspends until b is ready
setTimeout(() => events.ready(b), 20);
const t0 = performance.now();
const pending = pollOf([b], -1);
await new Promise((r) => setTimeout(r, 5));
const got = await pending;
check('an indefinite poll of a pending one waits until ready()', got[0] === b && performance.now() - t0 >= 15);
events.imports.close(a);
check('close: onClose, and ready() of a closed handle is false', closed === 1 && events.ready(a) === false);
// cancelled by the module: ready, with a message of its own (the embedder's ready() then changes nothing)
const d = events.external();
check('cancel: ready, its message not a timer\'s', events.imports.cancel(d) === 0 && events.handleState(d).cancelled &&
      errmsg(d) === 'cancelled' && events.ready(d, 'late') === true && errmsg(d) === 'cancelled');
// a message that cannot be a string: ready() throws, the handle stays pending (a poll of it is woken by the next one)
const c = events.external();
const waiting = pollOf([c], -1);
let threw = false;
try { events.ready(c, Object.create(null)); } catch (e) { threw = true; }
check('ready with a message that is no string throws, and leaves it pending', threw && events.handleState(c).ready === false);
check('... a later ready() wakes its poll', events.ready(c) === true && (await Promise.race([waiting, turns(200)]))?.[0] === c);
const e = events.external({ onClose: () => { closed++; } });
events.stop();
check('stop: the open external handles closed', closed === 2);
check('... and released: ready() is false, none open', events.ready(e) === false && events.stats().open === 0);
// stop() in the turn of the ready() that woke a suspended poll: the poll does not resume
{
  const { events, pollOf } = setup();
  const h = events.external();
  let resumed = false;
  pollOf([h], -1).then(() => { resumed = true; });
  await turns(5);
  events.ready(h);
  events.stop();
  await turns(20);
  check('stop after ready, in one turn: the suspended poll does not resume', !resumed);
}
process.stdout.write(out.join('\n') + '\n');
