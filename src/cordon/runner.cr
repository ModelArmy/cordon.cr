module Cordon
  # Abstract base for platform-specific sandbox runners.
  # Concrete subclasses translate a Policy into a native invocation.
  abstract class Runner
    # Returns true if the underlying sandbox binary is present and usable.
    abstract def available? : Bool

    # Runs *command* inside the sandbox described by *policy*.
    abstract def run(command : Array(String), policy : Policy) : Result

    # Replaces the current process with *command*, inside the sandbox
    # described by *policy*. Used for self-relaunch (Cordon.relaunch) —
    # the caller does not resume; either the sandboxed command takes over
    # the process image, or this raises.
    abstract def exec(command : Array(String), policy : Policy) : NoReturn

    # Launches *argv* as a subprocess, capturing stdout and stderr.
    # stdin is inherited from the parent process.
    #
    # Exit code follows Unix convention:
    #   - Normal exit: the process's own exit code.
    #   - Signal exit: 128 + signal number (e.g. SIGKILL → 137).
    #     sandbox-exec delivers a signal when a policy violation occurs at
    #     the process level (e.g. a required dylib cannot be loaded), so
    #     callers should treat exit codes ≥ 128 as likely sandbox violations.
    protected def execute(argv : Array(String)) : Result
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      status = Process.run(
        argv[0],
        argv[1..],
        output: stdout,
        error: stderr
      )

      exit_code = if status.normal_exit?
                    status.exit_code
                  else
                    # Process was killed by a signal. status.exit_code raises here,
                    # so we compute the conventional 128 + signal_number instead.
                    128 + (status.exit_signal?.try(&.value) || 128)
                  end

      Result.new(exit_code, stdout.to_s, stderr.to_s)
    end

    # Replaces the current process image with *argv*, inside the sandbox.
    # Unlike #execute, this does not spawn a child — the calling process
    # itself becomes the sandboxed process. Used by Cordon.relaunch for
    # self-relaunch (see cordon.cr). Only returns if execve(2) fails.
    protected def replace_process(argv : Array(String)) : NoReturn
      Process.exec(argv[0], argv[1..])
    end

    # Note: `covers?` (boundary-safe subpath check) and `locate_command`
    # (PATH lookup for bare command names) used to live here, shared by
    # both runners so each could grant the target command's own binary an
    # implicit exec exception. That exception is gone — the policy alone
    # defines what may be exec'd — so neither helper has a caller. They
    # were removed rather than left dangling; recover them from git
    # history if a future runner needs the same primitives.
  end
end
