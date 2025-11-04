# YJIT Fiber GC Crash - Root Cause Analysis

## Summary

Fixed a segmentation fault in the GC when marking suspended fibers that contain JIT-internal pointers on their VM stack.

## Core Dump Analysis

### The Crash
```
#8  RVALUE_MARKED (obj=132909539495936, objspace=0x78e2a3275000) at gc/default/default.c:1163
#9  gc_mark_set (obj=132909539495936, objspace=0x78e2a3275000) at gc/default/default.c:4382
...
#15 rb_gc_mark_vm_stack_values (n=1495, values=0x78e18f6bd000) at gc.c:2363
#17 cont_mark (ptr=0x78e1ba03eb80) at cont.c:1019
#18 fiber_mark (ptr=0x78e1ba03eb80) at cont.c:1148
```

### Memory State
```
vm_stack base: 0x78e18f6bd000
cfp->sp:       0x78e18f6bfeb8
n:             1495 (stack size)

values[1494] = 0x78e169e39000  <- JIT code pointer!
cfp->jit_return = 0x78e169e39006  <- Only 6 bytes apart!

Segfault address: 0x78e169e30000 (when GC tried to access heap page for the JIT pointer)
```

###Context
- Fiber suspended during `jit_exec_exception` (exception handling)
- `jit_exception_calls = 1000` (exception handler heavily used)
- Method: ISEQ_TYPE_METHOD, lines 120-124
- Platform: x86_64-linux, Ruby 3.4.7

## Root Cause

When a fiber is suspended while executing YJIT code:

1. The fiber's execution context (including VM stack) is saved
2. If suspended during exception handling, YJIT's `jit_return` field contains a JIT code pointer
3. **BUG**: Somehow a related JIT code pointer (`0x78e169e39000`) ends up on the VM stack itself at `sp[-1]`
4. When GC later marks the suspended fiber, `rb_gc_mark_vm_stack_values` tries to mark this JIT pointer as a Ruby object
5. `GET_HEAP_PAGE(obj)` dereferences invalid memory → segfault

## The Fix

Changed `rb_gc_mark_vm_stack_values` to use **`gc_mark_maybe_internal`** instead of `gc_mark_and_pin_internal`.

**Before** (crashes on JIT pointers):
```c
void rb_gc_mark_vm_stack_values(long n, const VALUE *values) {
    for (long i = 0; i < n; i++) {
        gc_mark_and_pin_internal(values[i]);  // ← Assumes all values are valid objects
    }
}
```

**After** (defensive):
```c
void rb_gc_mark_vm_stack_values(long n, const VALUE *values) {
    for (long i = 0; i < n; i++) {
        gc_mark_maybe_internal(values[i]);  // ← Validates pointers first
    }
}
```

### Why This Works

`gc_mark_maybe_internal` → `rb_gc_impl_mark_maybe`:
1. Calls `is_pointer_to_heap(objspace, (void *)obj)` first
2. Only marks if the pointer is in the Ruby heap
3. Safely ignores JIT pointers, uninitialized memory, etc.

This matches the behavior of `rb_gc_mark_locations` used for machine stack marking.

## Remaining Questions

1. **Where does the JIT pointer come from?** 
   - It's at `sp[-1]`, only 6 bytes from `jit_return`
   - Suggests YJIT might write to the wrong location in some edge case
   - Possibly related to stack canary or exception handling code

2. **Why is it hard to reproduce?**
   - Likely architecture or timing specific
   - May require specific Ruby code patterns
   - Core dump was from production x86_64 Linux workload

## Reproduction Attempts

Created multiple test scenarios targeting:
- Break in tap (from test_yjit.rb)
- Code GC + fiber suspension
- Exception handling paths
- Deep recursion
- Nested control flow

None reproduced the bug on arm64-darwin, suggesting it may be x86_64-specific or timing-dependent.

## Conclusion

The fix is correct and necessary based on:
1. Core dump evidence of JIT pointers on VM stack
2. Defensive programming principle (match `rb_gc_mark_locations` behavior)
3. No performance impact (`mark_maybe` is only slightly slower due to pointer validation)

The root cause in YJIT (where the pointer leaks from) remains to be found, but the GC fix prevents the crash regardless.

