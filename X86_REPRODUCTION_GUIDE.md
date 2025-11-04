# YJIT Fiber GC Bug - x86_64 Reproduction Guide

## Quick Setup on x86_64 Linux

```bash
# 1. Build Ruby with YJIT on x86_64
./configure --enable-yjit
make -j$(nproc)

# 2. Run the test with the BUGGY version (to reproduce crash)
RUBY_YJIT_ENABLE=1 ./miniruby test.rb
# Expected: Segmentation fault in RVALUE_MARKED

# 3. Apply the fix and rebuild
# (The fix is already in gc.c - using gc_mark_maybe_internal)
make clean
make -j$(nproc)

# 4. Run test again (should NOT crash)
RUBY_YJIT_ENABLE=1 ./miniruby test.rb
# Expected: All tests complete successfully
```

## To Test with the Buggy Version

Edit `gc.c` line 2374 to restore the bug:

```c
// Change FROM:
gc_mark_maybe_internal(values[i]);

// Change TO (buggy version):
gc_mark_and_pin_internal(values[i]);
```

Then rebuild and run:
```bash
make
RUBY_YJIT_ENABLE=1 ./miniruby test.rb
```

## Expected Crash (without fix)

```
test.rb: Segmentation fault at 0x... 
#0  RVALUE_MARKED (obj=...) at gc/default/default.c:1163
#1  gc_mark_set at gc/default/default.c:4382
#2  gc_mark at gc/default/default.c:4441
#3  gc_mark_and_pin at gc/default/default.c:4482
#4  rb_gc_impl_mark_and_pin at gc/default/default.c:4514
#5  gc_mark_and_pin_internal at gc.c:2276
#6  rb_gc_mark_vm_stack_values at gc.c:2365
...
#N  cont_mark (fiber marking)
```

## What to Look For

When the bug reproduces, check:
1. The crashing value (should be a JIT code address like `0x7f...`)
2. Compare to `cfp->jit_return` (should be very close, within ~10 bytes)
3. The stack index (likely around `values[1400-1500]`)

## Core Dump Commands (if crash occurs)

```bash
# Save core dump
ulimit -c unlimited
RUBY_YJIT_ENABLE=1 ./miniruby test.rb
# Creates core dump

# Analyze
gdb ./miniruby core
(gdb) bt
(gdb) frame <N>  # Where N is rb_gc_mark_vm_stack_values
(gdb) p n
(gdb) p values[n-1]
(gdb) p/x values[n-1]
(gdb) frame <M>  # Where M is cont_mark
(gdb) p ((struct rb_fiber_struct *)ptr)->cont.saved_ec.cfp->jit_return
```

## Files

- `gc.c`: The fix
- `test.rb`: Reproduction test
- `YJIT_FIBER_GC_BUG_ANALYSIS.md`: Detailed analysis
- `analyze_core_dump.md`: Memory layout analysis

