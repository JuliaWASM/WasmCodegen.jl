// js/julia_io.mjs's `poll` called (through a module: it suspends) with ranges of the memory
// it has and has not: the count of the ready handles, or `-EINVAL`. Prints the failed
// checks, one per line.
import { makeJuliaIOEvents } from '../js/julia_io.mjs';

const failures = [];
const check = (what, got, want) => { if (got !== want) failures.push(`${what}: ${got}, expected ${want}`); };
const memory = new WebAssembly.Memory({ initial: 1 });
const events = makeJuliaIOEvents({ memory });
// (module (import "e" "poll" (func (param i32 i32 i64 i32 i32) (result i32)))
//   (func (export "poll") (param i32 i32 i64 i32 i32) (result i32)
//     (call 0 (local.get 0) (local.get 1) (local.get 2) (local.get 3) (local.get 4))))
const wasm = Uint8Array.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
  1, 10, 1, 0x60, 5, 0x7f, 0x7f, 0x7e, 0x7f, 0x7f, 1, 0x7f,
  2, 10, 1, 1, 0x65, 4, 0x70, 0x6f, 0x6c, 0x6c, 0, 0,
  3, 2, 1, 0,
  7, 8, 1, 4, 0x70, 0x6f, 0x6c, 0x6c, 0, 1,
  10, 16, 1, 14, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0x10, 0, 0x0b]);
const { instance } = await WebAssembly.instantiate(wasm, { e: { poll: events.imports.poll } });
const poll = WebAssembly.promising(instance.exports.poll);
const END = memory.buffer.byteLength, EINVAL = 28;
new DataView(memory.buffer).setInt32(0, 999, true); // (a handle the host does not know: ready)

check('one handle, room for one', await poll(0, 1, 0n, END - 4, 1), 1);
check('room for two past the end', await poll(0, 1, 0n, END - 4, 2), -EINVAL);
// (a capacity whose size in bytes is no i32)
check('room for 2^30 past the end', await poll(0, 1, 0n, END - 4, 2 ** 30), -EINVAL);
check('room for 2^30 at the end', await poll(0, 1, 0n, END, 2 ** 30), -EINVAL);
check('room for 2^30 + 1 past the end', await poll(0, 1, 0n, END - 4, 2 ** 30 + 1), -EINVAL);
check('room for -1 past the end', await poll(0, 1, 0n, END - 4, -1), -EINVAL);
check('interest past the end', await poll(END - 4, 2, 0n, 16, 2), -EINVAL);

if (failures.length) console.log(failures.join('\n'));
