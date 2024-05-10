#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Thread support for Nim.
##
## **Note**: This is part of the system module. Do not import it directly.
## To activate thread support you need to compile
## with the `--threads:on`:option: command line switch.
##
## Nim's memory model for threads is quite different from other common
## programming languages (C, Pascal): Each thread has its own
## (garbage collected) heap and sharing of memory is restricted. This helps
## to prevent race conditions and improves efficiency. See `the manual for
## details of this memory model <manual.html#threads>`_.
##
## Examples
## ========
##
## .. code-block:: Nim
##
##  import std/locks
##
##  var
##    thr: array[0..4, Thread[tuple[a,b: int]]]
##    L: Lock
##
##  proc threadFunc(interval: tuple[a,b: int]) {.thread.} =
##    for i in interval.a..interval.b:
##      acquire(L) # lock stdout
##      echo i
##      release(L)
##
##  initLock(L)
##
##  for i in 0..high(thr):
##    thr[i] = createThread(threadFunc, (i*10, i*10+5))
##  joinThreads(thr)
##
##  deinitLock(L)

when not declared(ThisIsSystem):
  {.error: "You must not import this module explicitly".}

const
  StackGuardSize = 4096
  ThreadStackMask = 1024*256*sizeof(int)-1
  ThreadStackSize = ThreadStackMask+1 - StackGuardSize

#const globalsSlot = ThreadVarSlot(0)
#sysAssert checkSlot.int == globalsSlot.int

# We jump through some hops here to ensure that Nim thread procs can have
# the Nim calling convention. This is needed because thread procs are
# ``stdcall`` on Windows and ``noconv`` on UNIX. Alternative would be to just
# use ``stdcall`` since it is mapped to ``noconv`` on UNIX anyway.

type
  ThreadCore[TArg] = object
    ## The internal managnement data associated with a thread. Allocated
    ## by the spawning thread, and - initially - owned by both the spawning
    ## and spawned thread (shared ownership). If the spawned thread finishes
    ## before the `Thread <#Thread>` handle owned by the spawning thread goes
    ## out of scope, the spawning thread frees the instance, otherwise the
    ## spawned thread does.
    when emulatedThreadVars:
      tls: ThreadLocalStorage

    rc: int
      ## ref-counter. Has a maximum value of 2. All operations on it must be
      ## atomic

    when TArg is void:
      dataFn: proc () {.nimcall, gcsafe.}
    else:
      dataFn: proc (m: TArg) {.nimcall, gcsafe.}
      data: TArg

  Thread*[TArg] = object
    core: ptr ThreadCore[TArg]
    sys: SysThread

proc `=copy`*[TArg](x: var Thread[TArg], y: Thread[TArg]) {.error.}
proc `=destroy`[TArg](x: var Thread[TArg])

proc release[TArg](core: ptr ThreadCore[TArg]) =
  if atomicDec(core.rc, 1, ATOMIC_ACQ_REL) == 0:
    deallocShared(core)

proc `=destroy`[TArg](x: var Thread[TArg]) =
  if x.core != nil:
    # the spawning thread doesn't own the data passed along to the thread,
    # so don't touch it
    release(x.core)

var
  threadDestructionHandlers {.rtlThreadVar.}: seq[proc () {.closure, gcsafe, raises: [].}]

proc onThreadDestruction*(handler: proc () {.closure, gcsafe, raises: [].}) =
  ## Registers a *thread local* handler that is called at the thread's
  ## destruction.
  ##
  ## A thread is destructed when the `.thread` proc returns
  ## normally or when it raises an exception. Note that unhandled exceptions
  ## in a thread nevertheless cause the whole process to die.
  threadDestructionHandlers.add handler

template afterThreadRuns() =
  for i in countdown(threadDestructionHandlers.len-1, 0):
    threadDestructionHandlers[i]()

proc deallocOsPages() {.rtl, raises: [].}

proc threadTrouble() {.raises: [], gcsafe.}
  ## defined in system/excpt.nim

when true:
  proc threadProcWrapDispatch[TArg](thrd: ptr ThreadCore[TArg]) {.raises: [].} =
    try:
      when TArg is void:
        thrd.dataFn()
      else:
        thrd.dataFn(thrd.data)
    except:
      threadTrouble()
    finally:
      afterThreadRuns()

template threadProcWrapperBody(closure: untyped): untyped =
  let core = cast[ptr ThreadCore[TArg]](closure)
  when declared(globalsSlot):
    threadVarSetValue(globalsSlot, addr(core.tls))
  threadProcWrapDispatch(core)
  # Since an unhandled exception terminates the whole process (!), there is
  # no need for a ``try finally`` here, nor would it be correct: The current
  # exception is tried to be re-raised by the code-gen after the ``finally``!
  # However this is doomed to fail, because we already unmapped every heap
  # page!

  when TArg isnot void:
    # the spawned thread has ownership of the extra data, destroy it:
    reset(core.data)

  when compileOption("gc", "orc"):
    # run a full garbage collection pass in order to free all cells
    # kept alive only through reference cycles
    GC_fullCollect()

  release(core)

{.push stack_trace:off.}
# NOTE: the `threadProcWrapper` is currently special-cased by the compiler to
# not access the error flag
when defined(windows):
  proc threadProcWrapper[TArg](closure: pointer): int32 {.stdcall.} =
    threadProcWrapperBody(closure)
    # implicitly return 0
else:
  proc threadProcWrapper[TArg](closure: pointer): pointer {.noconv.} =
    threadProcWrapperBody(closure)
{.pop.}

proc createThreadCore[TArg](tp: proc (arg: TArg) {.thread, nimcall.},
                           ): ptr ThreadCore[TArg] =
  ## Allocates and sets up a ``ThreadCore`` instance.
  result = createShared(ThreadCore[TArg])
  result.rc = 2 # both threads initially own the data
  result.dataFn = tp

proc running*[TArg](t: Thread[TArg]): bool {.inline.} =
  ## Returns true if `t` is running.
  # if the spawning thread has unique ownership of the spawned thread's
  # management data, the thread isn't running anymore
  result = t.core != nil and atomicLoadN(addr t.core.rc, ATOMIC_RELAXED) == 2

proc handle*[TArg](t: Thread[TArg]): SysThread {.inline.} =
  ## Returns the thread handle of `t`.
  result = t.sys

when hostOS == "windows":
  const MAXIMUM_WAIT_OBJECTS = 64

  proc joinThread*[TArg](t: Thread[TArg]) {.inline.} =
    ## Waits for the thread `t` to finish.
    discard waitForSingleObject(t.sys, -1'i32)

  proc joinThreads*[TArg](t: varargs[Thread[TArg]]) =
    ## Waits for every thread in `t` to finish.
    var a: array[MAXIMUM_WAIT_OBJECTS, SysThread]
    var k = 0
    while k < len(t):
      var count = min(len(t) - k, MAXIMUM_WAIT_OBJECTS)
      for i in 0..(count - 1): a[i] = t[i + k].sys
      discard waitForMultipleObjects(int32(count),
                                     cast[ptr SysThread](addr(a)), 1, -1)
      inc(k, MAXIMUM_WAIT_OBJECTS)
else:
  proc joinThread*[TArg](t: Thread[TArg]) {.inline.} =
    ## Waits for the thread `t` to finish.
    discard pthread_join(t.sys, nil)

  proc joinThreads*[TArg](t: varargs[Thread[TArg]]) =
    ## Waits for every thread in `t` to finish.
    for i in 0..t.high: joinThread(t[i])

when false:
  # XXX a thread should really release its heap here somehow:
  proc destroyThread*[TArg](t: var Thread[TArg]) =
    ## Forces the thread `t` to terminate. This is potentially dangerous if
    ## you don't have full control over `t` and its acquired resources.
    when hostOS == "windows":
      discard TerminateThread(t.sys, 1'i32)
    else:
      discard pthread_cancel(t.sys)
    when declared(registerThread): unregisterThread(addr(t))
    t.dataFn = nil
    ## if thread `t` already exited, `t.core` will be `null`.
    if not isNil(t.core):
      deallocShared(t.core)
      t.core = nil

when hostOS == "windows":
  proc createThread*[TArg](tp: proc (arg: TArg) {.thread, nimcall.},
                           param: TArg): Thread[TArg] =
    ## Creates a new thread, starts its execution, and returns a handle of the
    ## thread.
    ##
    ## Entry point is the proc `tp`.
    ## `param` is passed to `tp`. `TArg` can be `void` if you
    ## don't need to pass any data to the thread.
    result.core = (createThreadCore[TArg])(tp)
    when TArg isnot void:
      result.core.data = param

    var dummyThreadId: int32
    result.sys = createThread(nil, ThreadStackSize, threadProcWrapper[TArg],
                              result.core, 0'i32, dummyThreadId)
    if result.sys <= 0:
      raise newException(ResourceExhaustedError, "cannot create thread")

  proc pinToCpu*[Arg](t: var Thread[Arg]; cpu: Natural) =
    ## Pins a thread to a `CPU`:idx:.
    ##
    ## In other words sets a thread's `affinity`:idx:.
    ## If you don't know what this means, you shouldn't use this proc.
    setThreadAffinityMask(t.sys, uint(1 shl cpu))

else:
  proc createThread*[TArg](tp: proc (arg: TArg) {.thread, nimcall.},
                           param: TArg): Thread[TArg] =
    ## Creates a new thread, starts its execution, and returns a handle of the
    ## thread.
    ##
    ## Entry point is the proc `tp`. `param` is passed to `tp`.
    ## `TArg` can be `void` if you
    ## don't need to pass any data to the thread.
    result.core = (createThreadCore[TArg])(tp)
    when TArg isnot void:
      result.core.data = param

    var a {.noinit.}: Pthread_attr
    doAssert pthread_attr_init(a) == 0
    let setstacksizeResult = pthread_attr_setstacksize(a, ThreadStackSize)
    when not defined(ios):
      # This fails on iOS
      doAssert(setstacksizeResult == 0)
    if pthread_create(result.sys, a, threadProcWrapper[TArg], result.core) != 0:
      raise newException(ResourceExhaustedError, "cannot create thread")
    doAssert pthread_attr_destroy(a) == 0

  proc pinToCpu*[Arg](t: var Thread[Arg]; cpu: Natural) =
    ## Pins a thread to a `CPU`:idx:.
    ##
    ## In other words sets a thread's `affinity`:idx:.
    ## If you don't know what this means, you shouldn't use this proc.
    when not defined(macosx):
      var s {.noinit.}: CpuSet
      cpusetZero(s)
      cpusetIncl(cpu.cint, s)
      setAffinity(t.sys, csize_t(sizeof(s)), s)

proc createThread*(t: var Thread[void], tp: proc () {.thread, nimcall.}) =
  t = (createThread[void])(tp)

proc createThread*[TArg](t: var Thread[TArg],
                         tp: proc(arg: TArg) {.thread, nimcall.},
                         param: TArg) =
  ## Convenience short-hand for creating and assigning a thread in-place.
  when TArg isnot void:
    t = createThread[TArg](tp, param)
  else:
    t = (createThread[void])(tp)

when not defined(gcOrc):
  include threadids
