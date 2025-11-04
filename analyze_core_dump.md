# Core Dump Analysis - Finding the Root Cause

## Memory Layout

From GDB:
```
p = vm_stack base = 0x78e18f6bd000
sp = 0x78e18f6bfeb8
n = sp - p = 1495 values

values[1494] address = p + (1494 * 8) = 0x78e18f6bd000 + 0x2EA0 = 0x78e18f6bfea0
values[1494] content = 0x78e169e39000  (JIT code pointer!)

cfp->sp = 0x78e18f6bfeb8
cfp->jit_return = 0x78e169e39006
```

## Critical Observation

```
values[1494] is at: 0x78e18f6bfea0
cfp->sp points to:  0x78e18f6bfeb8

Difference: 0x78e18f6bfeb8 - 0x78e18f6bfea0 = 0x18 = 24 bytes = 3 VALUEs

So values[1494] = sp[-3]
```

Wait, let me recalculate:
- `values[0]` is at `p = 0x78e18f6bd000`
- `values[1494]` is at `p + 1494*8 = 0x78e18f6bd000 + 0x2EA0 = 0x78e18f6bfea0`
- `sp` points to `0x78e18f6bfeb8`
- Distance from values[1494] to sp: `0x78e18f6bfeb8 - 0x78e18f6bfea0 = 0x18 = 24 bytes`

Hmm, but `sp` should point to the next free slot. Let me check the actual stack content:

```
x/8gx (values + 1490)
0x78e18f6bfe90:	0x0000000000000004	0x000078e278a507e8   <- values[1490], [1491]
0x78e18f6bfea0:	0x0000000000000000	0x0000000011110003   <- values[1492], [1493]
0x78e18f6bfeb0:	0x000078e169e39000	0x000078e278a82720   <- values[1494], [1495] !!!
0x78e18f6bfec0:	0x000078e21f808020	0x000078e278a50748
```

So `values[1495]` is at `0x78e18f6bfeb8` which IS where `sp` points!

This means `values[1494]` is at `sp - 8`, i.e., **the value right below the stack pointer**.

## The Smoking Gun

The bad value `0x78e169e39000` is **on the valid stack**, just below SP. It's not uninitialized memory - it was explicitly written there by something!

And it's only 6 bytes away from `jit_return = 0x78e169e39006`.

## Hypothesis

YJIT code is computing `lea_jump_target` for the jit_return address and:
1. Correctly storing it to `cfp->jit_return` 
2. BUT ALSO accidentally storing a related address (6 bytes earlier) onto the stack at `sp[-1]`

This could happen if:
- YJIT uses `sp[-1]` as a temporary during some operation
- YJIT has an off-by-one error when saving/restoring state
- YJIT's exception handling code leaves JIT addresses on the stack

## Next Steps

Search YJIT code for:
1. Code that writes to `sp[-1]` or `Opnd::mem(64, sp, -8)`
2. Code that manipulates both `jit_return` AND the stack pointer
3. Exception handling code that might leave state on the stack
4. The `rb_yjit_set_exception_return` function and how it interacts with SP

