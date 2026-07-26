module Cordon
  # Abstract base for platform-specific sandbox runners.
  # Concrete subclasses translate a Policy into a native invocation.
  abstract class Runner
    # Returns true if the underlying sandbox binary is present and usable.
    abstract def available? : Bool

    # Runs *command* inside the sandbox described by *policy*.
    abstract def run(command : Array(String), policy : Policy) : Result

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
  end
end
