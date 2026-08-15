require "random/secure"

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

    # Short platform-facing name for this runner (e.g. "bwrap",
    # "sandbox-exec"), used in ConfirmReport output.
    abstract def name : String

    # Confirms that this runner does not merely exist (see #available?)
    # but actually enforces isolation on the current host.
    #
    # #available? only checks that the sandbox binary is on PATH — it
    # can't see kernel restrictions (e.g. unprivileged user namespaces
    # disabled), a restrictive AppArmor/SELinux profile, or a container
    # missing the right capabilities. Some of these failure modes are
    # silent: the tool runs and exits 0 without actually confining
    # anything, which #available? has no way to detect at all.
    #
    # Runs a handful of real, spawned probes — using #run, so they go
    # through the real platform-native invocation, the same path #run
    # itself takes — and reports pass/fail for each with captured
    # stdout/stderr for diagnosis. This spawns several subprocesses, so
    # call it explicitly (e.g. from `cordon confirm`), not as part of
    # every #run.
    def confirm : ConfirmReport
      unless available?
        return ConfirmReport.new(name, [
          ProbeResult.new(
            "availability", "#{name} found on PATH",
            false, false, nil, "", "#{name} not found in PATH.", nil
          ),
        ], unavailable_hint)
      end

      probes = [] of ProbeResult

      if system_policy = confirm_system_policy
        isolation_probe, grant_probe = confirm_isolation_and_grant_probes(system_policy)
        probes << isolation_probe
        probes << grant_probe
        probes << confirm_network_probe(system_policy)
      else
        probes << ProbeResult.skip(
          "isolation", "denies reading a file outside the policy",
          "Preset::System has no static preset for this platform; " \
          "cannot exec probe commands to test isolation."
        )
        probes << ProbeResult.skip(
          "grant", "allows reading a file inside a granted path",
          "Preset::System has no static preset for this platform."
        )
        probes << ProbeResult.skip(
          "network", "denies outbound network access by default",
          "Preset::System has no static preset for this platform."
        )
      end

      failing = probes.reject(&.skipped?).reject(&.passed?)
      ConfirmReport.new(name, probes, failing.empty? ? nil : failure_hint)
    end

    # Hint shown when the sandbox binary isn't found at all. Overridden
    # per-runner with the platform-appropriate install/availability note.
    protected def unavailable_hint : String
      "#{name} was not found on PATH."
    end

    # Hint shown when at least one probe ran and failed. Overridden
    # per-runner with platform-specific troubleshooting steps for the
    # most common causes of silent enforcement failure.
    protected def failure_hint : String?
      nil
    end

    # Returns the System preset for the current platform, or nil if this
    # platform has none. Confirm's probes need *some* exec grant to run
    # `cat` at all — without it, "denied" would just mean "couldn't exec
    # cat", not "the target was correctly outside the policy" — so the
    # probes are skipped rather than run against a meaningless policy.
    private def confirm_system_policy : Policy?
      Preset::System.for_current_platform
    rescue UnsupportedPlatformError
      nil
    end

    private def confirm_isolation_and_grant_probes(system_policy : Policy) : {ProbeResult, ProbeResult}
      tmp_root = begin
        File.realpath(Dir.tempdir)
      rescue File::Error
        Dir.tempdir
      end

      probe_dir = File.join(tmp_root, "cordon_confirm_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(probe_dir)
      target = File.join(probe_dir, "canary.txt")
      File.write(target, "cordon-confirm-canary")

      begin
        # Isolation: system_policy alone grants no read access to
        # probe_dir, so `cat` can be exec'd but must not be able to read
        # the target — a real denial, not a missing-tool false positive.
        deny_result = run(["cat", target], system_policy)
        isolation = ProbeResult.from_result(
          "isolation", "denies reading a file outside the policy",
          deny_result, expect_success: false
        )

        # Grant: same target, now explicitly granted read-only, proving
        # the runner isn't just failing closed on everything.
        grant_policy = Policy.build(&.read_only(probe_dir)).merge(system_policy)
        allow_result = run(["cat", target], grant_policy)
        passed = allow_result.success? && allow_result.stdout.includes?("cordon-confirm-canary")
        grant = ProbeResult.new(
          "grant", "allows reading a file inside a granted path",
          passed, false, nil, allow_result.stdout, allow_result.stderr, allow_result.exit_code
        )

        {isolation, grant}
      ensure
        File.delete(target) if File.exists?(target)
        Dir.delete(probe_dir) if Dir.exists?(probe_dir)
      end
    end

    # TEST-NET-1 (RFC 5737): reserved for documentation, never routed on
    # the public internet. A short --connect-timeout keeps this fast
    # rather than hanging if this ever runs unsandboxed.
    CONFIRM_NETWORK_TEST_ADDR = "192.0.2.1"

    private def confirm_network_probe(system_policy : Policy) : ProbeResult
      cmd = confirm_network_command
      return ProbeResult.skip(
        "network", "denies outbound network access by default",
        "None of nc, curl, or wget were found on PATH to probe with."
      ) unless cmd

      # A raw TCP connect, not a DNS/lookup helper — a name lookup can be
      # satisfied by a system resolver daemon (nscd, mDNSResponder)
      # reachable outside the sandbox's own network grant, which would
      # let this probe "pass" without the sandboxed process's actual
      # network access ever being exercised.
      result = run(cmd, system_policy)
      ProbeResult.from_result(
        "network", "denies outbound network access by default",
        result, expect_success: false
      )
    end

    # First of nc / curl / wget found on PATH, each invoked to attempt a
    # raw connection to CONFIRM_NETWORK_TEST_ADDR:80 with a short timeout.
    # Falls back through the list since not every environment ships nc —
    # curl and wget are the next most commonly preinstalled alternatives.
    private def confirm_network_command : Array(String)?
      if Process.find_executable("nc")
        ["nc", "-w", "2", CONFIRM_NETWORK_TEST_ADDR, "80"]
      elsif Process.find_executable("curl")
        ["curl", "--connect-timeout", "2", "-s", "-o", "/dev/null",
         "http://#{CONFIRM_NETWORK_TEST_ADDR}/"]
      elsif Process.find_executable("wget")
        ["wget", "--timeout=2", "-q", "-O", "/dev/null",
         "http://#{CONFIRM_NETWORK_TEST_ADDR}/"]
      end
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
