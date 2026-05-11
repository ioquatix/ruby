#include "ruby/ruby.h"
#include "ruby/thread.h"
#include "ruby/io.h"
#include "ruby/fiber/scheduler.h"
#include <unistd.h>

/* -----------------------------------------------------------------------
 * Helpers for testing rb_fiber_scheduler_blocking_operation_wait exception
 * safety.
 * ----------------------------------------------------------------------- */

/* A trivial no-op blocking function used only in tests. */
static void *
noop_blocking_function(void *data)
{
    return NULL;
}

static VALUE
do_blocking_operation_wait(VALUE scheduler)
{
    struct rb_fiber_scheduler_blocking_operation_state state = {0};
    return rb_fiber_scheduler_blocking_operation_wait(
        scheduler, noop_blocking_function, NULL, NULL, NULL, 0,
        &state);
}

/*
 * Pipe pair used by the "hook exits while EXECUTING" test.
 * [0] = read end, [1] = write end.
 * executing_test_started_pipe: worker writes when it enters EXECUTING state.
 * executing_test_wait_pipe:    worker blocks here; unblock callback writes to it.
 */
static int executing_test_started_pipe[2] = {-1, -1};
static int executing_test_wait_pipe[2]   = {-1, -1};

static void *
blocking_function_executing_test(void *data)
{
    /* Signal to the scheduler hook that we are now EXECUTING. */
    ssize_t ret = write(executing_test_started_pipe[1], "x", 1);
    (void)ret;
    /* Block until the cancel unblock-callback writes to the wait pipe. */
    char buf[1];
    ret = read(executing_test_wait_pipe[0], buf, 1);
    (void)ret;
    return NULL;
}

static void
unblock_function_executing_test(void *data)
{
    ssize_t ret = write(executing_test_wait_pipe[1], "x", 1);
    (void)ret;
}

static VALUE
do_blocking_operation_wait_executing(VALUE scheduler)
{
    struct rb_fiber_scheduler_blocking_operation_state state = {0};
    return rb_fiber_scheduler_blocking_operation_wait(
        scheduler,
        blocking_function_executing_test, NULL,
        unblock_function_executing_test, NULL,
        0, &state);
}

/*
 * Bug::Scheduler.invoke_blocking_operation_wait_rescued(scheduler) -> true|false
 *
 * Calls rb_fiber_scheduler_blocking_operation_wait via rb_protect so that any
 * Ruby exception raised by the scheduler hook (which propagates directly out of
 * the function after the fix) is caught rather than escaping.  Returns true if
 * the hook raised, false otherwise.  The pending exception is cleared.
 */
static VALUE
invoke_blocking_operation_wait_rescued(VALUE self, VALUE scheduler)
{
    int protect_state = 0;
    rb_protect(do_blocking_operation_wait, scheduler, &protect_state);

    if (protect_state) {
        rb_set_errinfo(Qnil);
    }

    return protect_state != 0 ? Qtrue : Qfalse;
}

/*
 * Bug::Scheduler.try_execute_blocking_operation(op) -> Integer
 *
 * Calls rb_fiber_scheduler_blocking_operation_execute on the given opaque
 * blocking-operation VALUE and returns the raw integer result:
 *   0  => the operation ran (state pointer was NOT invalidated — the bug)
 *  -1  => the operation was refused as invalid (state pointer was NULL — correct)
 */
static VALUE
try_execute_blocking_operation(VALUE self, VALUE op_value)
{
    rb_fiber_scheduler_blocking_operation_t *op =
        rb_fiber_scheduler_blocking_operation_extract(op_value);

    if (!op) return INT2NUM(-2);

    return INT2NUM(rb_fiber_scheduler_blocking_operation_execute(op));
}

/*
 * Test extension for reproducing the gRPC interrupt handling bug.
 *
 * This reproduces the exact issue from grpc/grpc commit 69f229e (June 2025):
 * https://github.com/grpc/grpc/commit/69f229edd1d79ab7a7dfda98e3aef6fd807adcad
 *
 * The bug occurs when:
 * 1. A fiber scheduler uses Thread.handle_interrupt(::SignalException => :never)
 *    (like Async::Scheduler does)
 * 2. Native code uses rb_thread_call_without_gvl in a retry loop that checks
 *    the interrupted flag and retries (like gRPC's completion queue)
 * 3. A signal (SIGINT/SIGTERM) is sent
 * 4. The unblock_func sets interrupted=1, but Thread.handle_interrupt defers the signal
 * 5. The loop sees interrupted=1 and retries without yielding to the scheduler
 * 6. The deferred interrupt never gets processed -> infinite hang
 *
 * The fix is in vm_check_ints_blocking() in thread.c, which should yield to
 * the fiber scheduler when interrupts are pending, allowing the scheduler to
 * detect Thread.pending_interrupt? and exit its run loop.
 */

struct blocking_state {
    int notify_descriptor;
    volatile int interrupted;
};

static void
unblock_callback(void *argument)
{
    struct blocking_state *blocking_state = (struct blocking_state *)argument;
    blocking_state->interrupted = 1;
}

static void *
blocking_operation(void *argument)
{
    struct blocking_state *blocking_state = (struct blocking_state *)argument;

    ssize_t ret = write(blocking_state->notify_descriptor, "x", 1);
    (void)ret; // ignore the result for now

    while (!blocking_state->interrupted) {
        struct timeval tv = {1, 0};  // 1 second timeout.
        int result = select(0, NULL, NULL, NULL, &tv);

        if (result == -1 && errno == EINTR) {
            blocking_state->interrupted = 1;
        }

        // Otherwise, timeout -> loop again.
    }

    return NULL;
}

static VALUE
scheduler_blocking_loop(VALUE self, VALUE notify)
{
    struct blocking_state blocking_state = {
        .notify_descriptor = rb_io_descriptor(notify),
        .interrupted = 0,
    };

    while (true) {
        blocking_state.interrupted = 0;

        rb_thread_call_without_gvl(
            blocking_operation, &blocking_state,
            unblock_callback, &blocking_state
        );

        // The bug: When interrupted, loop retries without yielding to scheduler.
        // With Thread.handle_interrupt(:never), this causes an infinite hang,
        // because the deferred interrupt never gets a chance to be processed.
    } while (blocking_state.interrupted);

    return Qnil;
}

/*
 * Bug::Scheduler.setup_executing_test_pipes -> Integer (fd)
 *
 * Creates the pipe pair used by invoke_blocking_operation_wait_rescued_executing.
 * Returns the read end of the "started" pipe as a raw file descriptor.
 * The caller should wrap it with IO.new(fd, 'r') and read one byte from it
 * inside the scheduler hook to wait until the worker enters EXECUTING state.
 */
static VALUE
setup_executing_test_pipes(VALUE self)
{
    /* Close any leftover fds from a previous run. */
    for (int i = 0; i < 2; i++) {
        if (executing_test_started_pipe[i] != -1) {
            close(executing_test_started_pipe[i]);
            executing_test_started_pipe[i] = -1;
        }
        if (executing_test_wait_pipe[i] != -1) {
            close(executing_test_wait_pipe[i]);
            executing_test_wait_pipe[i] = -1;
        }
    }
    if (pipe(executing_test_started_pipe) != 0) rb_sys_fail("pipe");
    if (pipe(executing_test_wait_pipe)   != 0) rb_sys_fail("pipe");
    /* Return the read end of the started pipe so Ruby can IO.new(fd,'r').read(1). */
    return INT2NUM(executing_test_started_pipe[0]);
}

/*
 * Bug::Scheduler.invoke_blocking_operation_wait_rescued_executing(scheduler) -> true|false
 *
 * Like invoke_blocking_operation_wait_rescued but uses blocking_function_executing_test
 * (blocks on a pipe until cancelled) instead of noop_blocking_function.
 * Must be preceded by a call to setup_executing_test_pipes.
 */
static VALUE
invoke_blocking_operation_wait_rescued_executing(VALUE self, VALUE scheduler)
{
    int protect_state = 0;
    rb_protect(do_blocking_operation_wait_executing, scheduler, &protect_state);

    if (protect_state) rb_set_errinfo(Qnil);

    /* Close all remaining pipe ends. */
    for (int i = 0; i < 2; i++) {
        if (executing_test_started_pipe[i] != -1) {
            close(executing_test_started_pipe[i]);
            executing_test_started_pipe[i] = -1;
        }
        if (executing_test_wait_pipe[i] != -1) {
            close(executing_test_wait_pipe[i]);
            executing_test_wait_pipe[i] = -1;
        }
    }

    return protect_state != 0 ? Qtrue : Qfalse;
}

void
Init_scheduler(void)
{
    VALUE mBug = rb_define_module("Bug");
    VALUE mScheduler = rb_define_module_under(mBug, "Scheduler");

    rb_define_module_function(mScheduler, "blocking_loop", scheduler_blocking_loop, 1);
    rb_define_module_function(mScheduler, "invoke_blocking_operation_wait_rescued", invoke_blocking_operation_wait_rescued, 1);
    rb_define_module_function(mScheduler, "try_execute_blocking_operation", try_execute_blocking_operation, 1);
    rb_define_module_function(mScheduler, "setup_executing_test_pipes", setup_executing_test_pipes, 0);
    rb_define_module_function(mScheduler, "invoke_blocking_operation_wait_rescued_executing", invoke_blocking_operation_wait_rescued_executing, 1);
}
