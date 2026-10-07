// SPDX-License-Identifier: Apache-2.0
//
// exp218 — the cases, written by model/Cases.lean: each program's words through
// lean/Pio's proved encode, and what lean/Pio/Machine.lean says the chip holds
// when it stops. Do not edit; check.sh holds this file to what Lean writes.
//
// case 1: readout: four words through OSR into X, Y, ISR and OSR, read back
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x12345678, 0x9abcdef0, 0x0f1e2d3c, 0xa5a5c3c3} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   a027  mov x, osr
//       6   80a0  pull block
//       7   a047  mov y, osr
//       8   80a0  pull block
//       9   a0c7  mov isr, osr
//       10   80a0  pull block
//       11   80a0  pull block
//     the model: pc 11  X 0x12345678  Y 0x9abcdef0  ISR 0x0f1e2d3c  OSR 0xa5a5c3c3  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 2: push iffull, 4 bits of 8, no autopush: nothing is pushed (rp2040js pushes)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x008c0000  PINCTRL 0x14000000  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e025  set x, 5
//       5   4024  in x, 4
//       6   8040  push iffull noblock
//       7   80a0  pull block
//     the model: pc 7  X 0x00000005  Y 0x00000000  ISR 0x50000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 3: push iffull, 8 bits of 8: pushed
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x008c0000  PINCTRL 0x14000000  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e025  set x, 5
//       5   4024  in x, 4
//       6   4024  in x, 4
//       7   8040  push iffull noblock
//       8   80a0  pull block
//     the model: pc 8  X 0x00000005  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {0x55000000} then {}
// case 4: pull ifempty, 4 bits of 8 out: no pull; 8 of 8: pulled (both emulators part)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x100c0000  PINCTRL 0x14000000  TX {0x87654321, 0xcafef00d} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   6024  out x, 4
//       6   80c0  pull ifempty noblock
//       7   a047  mov y, osr
//       8   6064  out null, 4
//       9   80c0  pull ifempty noblock
//       10   80a0  pull block
//     the model: pc 10  X 0x00000001  Y 0x08765432  ISR 0x00000000  OSR 0xcafef00d  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 5: out x, 32: OSR is shifted by 32 (rp2040js leaves it)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0xdeadbeef} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   6020  out x, 32
//       6   80a0  pull block
//     the model: pc 6  X 0xdeadbeef  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 6: mov's bit-reverse and invert (rp2040-pio-emulator copies)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x12345678} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   a037  mov x, ::osr
//       6   a04f  mov y, ~osr
//       7   80a0  pull block
//     the model: pc 7  X 0x1e6a2c48  Y 0xedcba987  ISR 0x00000000  OSR 0x12345678  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 7: jmp !osre, 8 bits out of a threshold of 8: not taken (rp2040-pio-emulator takes it)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x100c0000  PINCTRL 0x14000000  TX {0x0000ffff} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   6068  out null, 8
//       6   00e9  jmp !osre, 9
//       7   e041  set y, 1
//       8   000a  jmp 10
//       9   e042  set y, 2
//       10   80a0  pull block
//     the model: pc 10  X 0x00000000  Y 0x00000001  ISR 0x00000000  OSR 0x000000ff  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 8: a wrap from 0 to 0: instruction 0, again and again (rp2040-pio-emulator goes on to 1)
//     EXECCTRL 0x00000000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
//       0   e045  set y, 5
//       1   e047  set y, 7
//       2 ← a0c3  mov isr, null
//       3   a0e3  mov osr, null
//       4   a023  mov x, null
//       5   a043  mov y, null
//       6   0000  jmp 0
//     the model: pc 0  X 0x00000000  Y 0x00000005  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 9: a wrap from 5 to 3, round a jmp x-- loop that shifts X into ISR
//     EXECCTRL 0x00005180  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
//       0 ← e024  set x, 4
//       1   a0c3  mov isr, null
//       2   a043  mov y, null
//       3   0026  jmp !x, 6
//       4   0045  jmp x--, 5
//       5   4024  in x, 4
//       6   80a0  pull block
//     the model: pc 6  X 0x00000000  Y 0x00000000  ISR 0x01230000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 10: in pins, 8 from IN_BASE 2: GPIO2..9 (rp2040-pio-emulator reads from GPIO0)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14010000  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   4008  in pins, 8
//       5   80a0  pull block
//     the model: pc 5  X 0x00000000  Y 0x00000000  ISR 0xb2000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 11: wait pin, jmp pin, wait gpio, wait jmppin: pass where high, wait where low
//     EXECCTRL 0x0601f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14010000  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   20a1  wait 1 pin 1
//       5   e041  set y, 1
//       6   00c8  jmp pin, 8
//       7   e042  set y, 2
//       8   2087  wait 1 gpio 7
//       9   20e1  wait 1 jmppin + 1
//       10   e023  set x, 3
//       11   20a0  wait 1 pin 0
//     the model: pc 11  X 0x00000003  Y 0x00000001  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 12: mov pins and mov pindirs through the OUT mapping (rp2040-pio-emulator writes 32 from 0)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14400004  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e036  set x, 22
//       5   a001  mov pins, x
//       6   a061  mov pindirs, x
//       7   80a0  pull block
//     the model: pc 7  X 0x00000016  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000060  dirs 0x00000060  TX level 0  RX {} then {}
// case 13: OUT pins from 31, three of them: they wrap to 0 (both emulators stop at 31)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x1430001f  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e026  set x, 6
//       5   a001  mov pins, x
//       6   a061  mov pindirs, x
//       7   80a0  pull block
//     the model: pc 7  X 0x00000006  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000003  dirs 0x00000003  TX level 0  RX {} then {}
// case 14: SET pins 30 and 31: the machine drives 32 pins (rp2040js keeps 30)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x080003c0  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e003  set pins, 3
//       5   e083  set pindirs, 3
//       6   80a0  pull block
//     the model: pc 6  X 0x00000000  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0xc0000000  dirs 0xc0000000  TX level 0  RX {} then {}
// case 15: out exec: a word from TX runs as an instruction
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x0000e049} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   60f0  out exec, 16
//       6   80a0  pull block
//     the model: pc 6  X 0x00000000  Y 0x00000009  ISR 0x00000000  OSR 0x00000000  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 16: mov exec: X runs as an instruction
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x0000a04b} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   80a0  pull block
//       5   a027  mov x, osr
//       6   a081  mov exec, x
//       7   80a0  pull block
//     the model: pc 7  X 0x0000a04b  Y 0xffffffff  ISR 0x00000000  OSR 0x0000a04b  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 17: mov from STATUS, TX level against N = 2: 0 at 3 words, all ones at 1
//     EXECCTRL 0x0001f002  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {0x00000001, 0x00000002, 0x00000003} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   a045  mov y, status
//       5   80a0  pull block
//       6   80a0  pull block
//       7   a025  mov x, status
//       8   80a0  pull block
//       9   80a0  pull block
//     the model: pc 9  X 0xffffffff  Y 0x00000000  ISR 0x00000000  OSR 0x00000003  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 18: irq set, clear, wait irq clearing its flag, and irq wait: flags 2 and 6 left
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   c003  irq set 3
//       5   c043  irq clear 3
//       6   c005  irq set 5
//       7   20c5  wait 1 irq 5
//       8   c006  irq set 6
//       9   c022  irq wait 2
//     the model: pc 9  X 0x00000000  Y 0x00000000  ISR 0x00000000  OSR 0x00000000  IRQ 0x44
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}
// case 19: push block on a full RX waits, then pushes when there is room (rp2040js empties ISR)
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x000c0000  PINCTRL 0x14000000  TX {} then {0x0000600d}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e021  set x, 1
//       5   a0c1  mov isr, x
//       6   8020  push block
//       7   e022  set x, 2
//       8   a0c1  mov isr, x
//       9   8020  push block
//       10   e023  set x, 3
//       11   a0c1  mov isr, x
//       12   8020  push block
//       13   e024  set x, 4
//       14   a0c1  mov isr, x
//       15   8020  push block
//       16   e025  set x, 5
//       17   a0c1  mov isr, x
//       18   8020  push block
//       19   80a0  pull block
//       20   a047  mov y, osr
//       21   80a0  pull block
//     the model: pc 21  X 0x00000005  Y 0x0000600d  ISR 0x00000000  OSR 0x0000600d  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {0x00000001, 0x00000002, 0x00000003, 0x00000004} then {0x00000005}
// case 20: shifting left both ways, jmp x-- past 0, and pull noblock on an empty TX taking X
//     EXECCTRL 0x0001f000  SHIFTCTRL 0x00000000  PINCTRL 0x14000000  TX {0xf0e1d2c3} then {}
//       0 ← a0c3  mov isr, null
//       1   a0e3  mov osr, null
//       2   a023  mov x, null
//       3   a043  mov y, null
//       4   e023  set x, 3
//       5   0045  jmp x--, 5
//       6   80a0  pull block
//       7   6048  out y, 8
//       8   40ec  in osr, 12
//       9   8080  pull noblock
//       10   80a0  pull block
//     the model: pc 10  X 0xffffffff  Y 0x000000f0  ISR 0x00000300  OSR 0xffffffff  IRQ 0x00
//                pins 0x00000000  dirs 0x00000000  TX level 0  RX {} then {}

#pragma once
#include "case.h"

#define NCASES 20
#define EXT_PULLED_UP 0x000002c8u   // GPIO2..9, pulled up where set and down elsewhere
// What the shell executes on the stopped machine to read it, through encode:
#define I_PUSH        0x8000u   // push noblock
#define I_MOV_ISR_X   0xa0c1u   // mov isr, x
#define I_MOV_ISR_Y   0xa0c2u   // mov isr, y
#define I_MOV_ISR_OSR 0xa0c7u   // mov isr, osr

static const struct pio_case CASES[NCASES] = {
    { 12, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0xa027, 0x80a0, 0xa047, 0x80a0, 0xa0c7, 0x80a0, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      4, {0x12345678, 0x9abcdef0, 0x0f1e2d3c, 0xa5a5c3c3}, 0, {},
      { 11, 0x12345678, 0x9abcdef0, 0x0f1e2d3c, 0xa5a5c3c3, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 8, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe025, 0x4024, 0x8040, 0x80a0}, 0x0000, 0x0001f000, 0x008c0000, 0x14000000,
      0, {}, 0, {},
      { 7, 0x00000005, 0x00000000, 0x50000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 9, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe025, 0x4024, 0x4024, 0x8040, 0x80a0}, 0x0000, 0x0001f000, 0x008c0000, 0x14000000,
      0, {}, 0, {},
      { 8, 0x00000005, 0x00000000, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        1, {0x55000000}, 0, {} } },
    { 11, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0x6024, 0x80c0, 0xa047, 0x6064, 0x80c0, 0x80a0}, 0x0000, 0x0001f000, 0x100c0000, 0x14000000,
      2, {0x87654321, 0xcafef00d}, 0, {},
      { 10, 0x00000001, 0x08765432, 0x00000000, 0xcafef00d, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 7, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0x6020, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      1, {0xdeadbeef}, 0, {},
      { 6, 0xdeadbeef, 0x00000000, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 8, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0xa037, 0xa04f, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      1, {0x12345678}, 0, {},
      { 7, 0x1e6a2c48, 0xedcba987, 0x00000000, 0x12345678, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 11, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0x6068, 0x00e9, 0xe041, 0x000a, 0xe042, 0x80a0}, 0x0000, 0x0001f000, 0x100c0000, 0x14000000,
      1, {0x0000ffff}, 0, {},
      { 10, 0x00000000, 0x00000001, 0x00000000, 0x000000ff, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 7, {0xe045, 0xe047, 0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x0000}, 0x0002, 0x00000000, 0x000c0000, 0x14000000,
      0, {}, 0, {},
      { 0, 0x00000000, 0x00000005, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 7, {0xe024, 0xa0c3, 0xa043, 0x0026, 0x0045, 0x4024, 0x80a0}, 0x0000, 0x00005180, 0x000c0000, 0x14000000,
      0, {}, 0, {},
      { 6, 0x00000000, 0x00000000, 0x01230000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 6, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x4008, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14010000,
      0, {}, 0, {},
      { 5, 0x00000000, 0x00000000, 0xb2000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 12, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x20a1, 0xe041, 0x00c8, 0xe042, 0x2087, 0x20e1, 0xe023, 0x20a0}, 0x0000, 0x0601f000, 0x000c0000, 0x14010000,
      0, {}, 0, {},
      { 11, 0x00000003, 0x00000001, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 8, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe036, 0xa001, 0xa061, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14400004,
      0, {}, 0, {},
      { 7, 0x00000016, 0x00000000, 0x00000000, 0x00000000, 0x00, 0x00000060, 0x00000060, 0,
        0, {}, 0, {} } },
    { 8, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe026, 0xa001, 0xa061, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x1430001f,
      0, {}, 0, {},
      { 7, 0x00000006, 0x00000000, 0x00000000, 0x00000000, 0x00, 0x00000003, 0x00000003, 0,
        0, {}, 0, {} } },
    { 7, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe003, 0xe083, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x080003c0,
      0, {}, 0, {},
      { 6, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00, 0xc0000000, 0xc0000000, 0,
        0, {}, 0, {} } },
    { 7, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0x60f0, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      1, {0x0000e049}, 0, {},
      { 6, 0x00000000, 0x00000009, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 8, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0x80a0, 0xa027, 0xa081, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      1, {0x0000a04b}, 0, {},
      { 7, 0x0000a04b, 0xffffffff, 0x00000000, 0x0000a04b, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 10, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xa045, 0x80a0, 0x80a0, 0xa025, 0x80a0, 0x80a0}, 0x0000, 0x0001f002, 0x000c0000, 0x14000000,
      3, {0x00000001, 0x00000002, 0x00000003}, 0, {},
      { 9, 0xffffffff, 0x00000000, 0x00000000, 0x00000003, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 10, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xc003, 0xc043, 0xc005, 0x20c5, 0xc006, 0xc022}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      0, {}, 0, {},
      { 9, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x44, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
    { 22, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe021, 0xa0c1, 0x8020, 0xe022, 0xa0c1, 0x8020, 0xe023, 0xa0c1, 0x8020, 0xe024, 0xa0c1, 0x8020, 0xe025, 0xa0c1, 0x8020, 0x80a0, 0xa047, 0x80a0}, 0x0000, 0x0001f000, 0x000c0000, 0x14000000,
      0, {}, 1, {0x0000600d},
      { 21, 0x00000005, 0x0000600d, 0x00000000, 0x0000600d, 0x00, 0x00000000, 0x00000000, 0,
        4, {0x00000001, 0x00000002, 0x00000003, 0x00000004}, 1, {0x00000005} } },
    { 11, {0xa0c3, 0xa0e3, 0xa023, 0xa043, 0xe023, 0x0045, 0x80a0, 0x6048, 0x40ec, 0x8080, 0x80a0}, 0x0000, 0x0001f000, 0x00000000, 0x14000000,
      1, {0xf0e1d2c3}, 0, {},
      { 10, 0xffffffff, 0x000000f0, 0x00000300, 0xffffffff, 0x00, 0x00000000, 0x00000000, 0,
        0, {}, 0, {} } },
};
