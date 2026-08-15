module Cordon
  # Outcome of one enforcement probe run by Runner#confirm.
  #
  # A probe is a real, spawned attempt to do something the sandbox should
  # either allow or deny — not a static check. `passed` means the probe's
  # expected outcome (allowed or denied) actually happened.
  struct ProbeResult
    getter name : String
    getter description : String
    getter? passed : Bool
    getter? skipped : Bool
    getter skip_reason : String?
    getter stdout : String
    getter stderr : String
    getter exit_code : Int32?

    def initialize(
      @name : String,
      @description : String,
      @passed : Bool,
      @skipped : Bool,
      @skip_reason : String?,
      @stdout : String,
      @stderr : String,
      @exit_code : Int32?,
    )
    end

    def self.from_result(name : String, description : String, result : Result, expect_success : Bool) : ProbeResult
      passed = result.success? == expect_success
      new(name, description, passed, false, nil, result.stdout, result.stderr, result.exit_code)
    end

    def self.skip(name : String, description : String, reason : String) : ProbeResult
      new(name, description, false, true, reason, "", "", nil)
    end
  end

  # Result of Runner#confirm: a live check that a sandbox runner not only
  # is present (see Runner#available?) but actually enforces isolation on
  # this host. Presence and enforcement are different things — a runner
  # can be installed and still fail at runtime (disabled kernel features,
  # a restrictive AppArmor/SELinux profile, a container without the right
  # capabilities), sometimes without ever raising, e.g. exiting 0 without
  # actually confining the process.
  struct ConfirmReport
    getter runner_name : String
    getter probes : Array(ProbeResult)
    getter hint : String?

    def initialize(@runner_name : String, @probes : Array(ProbeResult), @hint : String? = nil)
    end

    # True only if every probe that actually ran passed, and at least one
    # probe ran at all. A report where every probe was skipped (e.g. no
    # network tool found) is inconclusive, not confirmed — ok? is false,
    # distinct from a probe actively failing.
    def ok? : Bool
      ran = probes.reject(&.skipped?)
      !ran.empty? && ran.all?(&.passed?)
    end

    # Multi-line human-readable report, suitable for logging or printing
    # directly to a user who needs to fix their environment.
    def to_s(io : IO) : Nil
      io << "cordon confirm: " << runner_name << '\n'

      probes.each do |probe|
        status = probe.skipped? ? "SKIP" : (probe.passed? ? "PASS" : "FAIL")
        io << "  [" << status << "] " << probe.name << " — " << probe.description << '\n'

        if probe.skipped?
          io << "         " << probe.skip_reason << '\n'
        elsif !probe.passed?
          io << "         exit_code=" << probe.exit_code << '\n'
          unless probe.stderr.blank?
            io << "         stderr: " << probe.stderr.strip << '\n'
          end
          unless probe.stdout.blank?
            io << "         stdout: " << probe.stdout.strip << '\n'
          end
        end
      end

      io << '\n'
      if ok?
        io << "Result: OK — sandboxing appears to be enforced.\n"
      else
        io << "Result: NOT CONFIRMED — sandboxing is not reliably enforced on this host.\n"
      end

      if h = hint
        io << '\n' << h << '\n'
      end
    end
  end
end
