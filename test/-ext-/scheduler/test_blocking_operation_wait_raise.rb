# frozen_string_literal: true
require 'test/unit'
require '-test-/scheduler'

# Tests that rb_fiber_scheduler_blocking_operation_wait correctly invalidates
# the blocking-operation object when the scheduler hook raises a Ruby exception.
#
# Background
# ----------
# rb_fiber_scheduler_blocking_operation_wait creates a BlockingOperation object
# whose state is embedded directly in the heap-allocated Ruby object, then calls
# the scheduler's #blocking_operation_wait hook via rb_funcall.  If the hook
# raises, rb_funcall performs a longjmp.  The invariant we enforce is:
#
#   After the hook exits (normally or by raising), rb_fiber_scheduler_blocking_operation_wait
#   nullifies the operation's function pointer.  Any subsequent call to
#   rb_fiber_scheduler_blocking_operation_execute must therefore return -1
#   (function is NULL — invalid operation), not 0 (ran the function).
#
# Because state is now embedded in the Ruby object rather than pointing into
# rb_nogvl's stack frame, stale writes from a buggy scheduler write to
# heap memory rather than a dead stack frame — but the function-pointer
# invalidation still prevents the operation from running again after the hook.
class TestBlockingOperationWaitRaise < Test::Unit::TestCase
  def test_hook_raising_invalidates_state_pointer
    stashed_op = nil

    scheduler = Object.new
    scheduler.define_singleton_method(:blocking_operation_wait) do |op|
      stashed_op = op
      raise RuntimeError, "deliberate raise from scheduler hook"
    end

    raised = Bug::Scheduler.invoke_blocking_operation_wait_rescued(scheduler)

    assert raised,
      "Bug::Scheduler.invoke_blocking_operation_wait_rescued should report that " \
      "the hook raised"

    assert_not_nil stashed_op,
      "the scheduler hook should have been called and should have received an operation"

    # rb_fiber_scheduler_blocking_operation_execute returns:
    #  0  => it ran the function  (function pointer was NOT invalidated — the bug)
    # -1  => refused as invalid   (function pointer was NULL  — correct behaviour)
    result = Bug::Scheduler.try_execute_blocking_operation(stashed_op)

    assert_equal(-1, result,
      "After the scheduler hook raises, rb_fiber_scheduler_blocking_operation_execute " \
      "must return -1 (invalid/no-op).  A return of 0 means the function pointer was " \
      "not cleared on the exception path, allowing the operation to run against an " \
      "already-unwound call frame.")
  end

  # When an asynchronous interrupt (signal, fiber exception) causes the
  # scheduler hook to exit while the operation status is EXECUTING,
  # rb_fiber_scheduler_blocking_operation_wait must cancel the operation
  # gracefully and return — not abort the process.
  #
  # We test this with a real blocking operation (pipe-read) that stays in
  # EXECUTING state until the cancel unblock-callback fires.
  def test_hook_returning_while_executing_is_cancelled_gracefully
    stashed_op = nil

    # Creates two internal pipe pairs; returns the read end of the
    # "started" pipe as a raw fd.  The worker writes one byte to it when
    # it enters EXECUTING state, letting the hook know it is safe to return.
    started_fd = Bug::Scheduler.setup_executing_test_pipes
    started_io = IO.new(started_fd, 'r')

    scheduler = Object.new
    scheduler.define_singleton_method(:blocking_operation_wait) do |op|
      stashed_op = op
      Thread.new { op.call }
      # Block until the worker has done the QUEUED→EXECUTING CAS.
      started_io.read(1)
      started_io.close
      # Return while the operation is still EXECUTING — simulates an
      # async interrupt that prevented the scheduler from waiting.
    end

    raised = Bug::Scheduler.invoke_blocking_operation_wait_rescued_executing(scheduler)

    assert !raised,
      "blocking_operation_wait should not raise when the hook exits while EXECUTING; " \
      "it should cancel the operation and return gracefully"

    assert_not_nil stashed_op

    # Function pointer must be nullified regardless of how the hook exited.
    result = Bug::Scheduler.try_execute_blocking_operation(stashed_op)
    assert_equal(-1, result,
      "After the hook exits while EXECUTING, the function pointer must be nullified " \
      "so the now-cancelled operation cannot be re-executed")
  end
end
