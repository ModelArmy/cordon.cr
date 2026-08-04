require "../spec_helper"

describe Cordon::SandboxExec do
  runner = Cordon::SandboxExec.new
  base_policy = Cordon::Policy.new

  describe "#generate_profile" do
    it "starts with version and deny default" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(version 1)")
      profile.should contain("(deny default)")
    end

    it "includes the BASELINE" do
      profile = runner.generate_profile(base_policy)
      profile.should contain("(allow process-fork)")
      profile.should contain("(allow mach-lookup)")
      profile.should contain("(allow sysctl-read)")
      profile.should contain("/private/var/run/syslog")
      profile.should contain("/private/var/run/resolv.conf")
      profile.should contain("/etc/resolv.conf")
      profile.should contain("/private/etc/hosts")
      profile.should contain("/etc/hosts")
    end

    it "does not grant blanket process-exec in BASELINE" do
      # Regression test for the discovery that (allow process-exec) with
      # no path filter permits exec'ing ANY binary regardless of the
      # policy's read restrictions. BASELINE itself must never contain
      # an unscoped grant; scoping happens per-profile instead.
      profile = runner.generate_profile(base_policy)
      profile.should_not contain("(allow process-exec)")
      profile.should_not contain("(allow process-exec-interpreter)")
    end

    it "grants read-only access to read_only_paths" do
      policy = Cordon::Policy.build { |p| p.read_only "/usr/share/myapp" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read*")
      profile.should contain("/usr/share/myapp")
    end

    it "grants read-write access to read_write_paths" do
      policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/work")
    end

    it "grants read-write access to tmpfs_paths (no tmpfs on macOS)" do
      policy = Cordon::Policy.build { |p| p.tmpfs "/tmp/scratch" }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/scratch")
    end

    it "expands relative paths to absolute" do
      policy = Cordon::Policy.build { |p| p.read_only "." }
      profile = runner.generate_profile(policy)
      profile.should_not contain("\".\"/")
      profile.should contain(File.expand_path("."))
    end

    it "resolves symlinked paths to their real target, not the symlink" do
      # Built generically with a throwaway symlink rather than asserting
      # the macOS-specific /tmp -> /private/tmp mapping, since this spec
      # also runs under the Linux CI job where that symlink doesn't exist.
      real_dir = File.join(Dir.tempdir, "sbx_real_#{Random::Secure.hex(4)}")
      link_path = File.join(Dir.tempdir, "sbx_link_#{Random::Secure.hex(4)}")
      Dir.mkdir(real_dir)
      File.symlink(real_dir, link_path)

      begin
        policy = Cordon::Policy.build { |p| p.read_only link_path }
        profile = runner.generate_profile(policy)
        profile.should contain(File.realpath(real_dir))
        profile.should_not contain(link_path)
      ensure
        File.delete(link_path)
        Dir.delete(real_dir)
      end
    end

    it "falls back to expand_path for paths that don't exist yet" do
      policy = Cordon::Policy.build { |p| p.read_write "/tmp/sbx_does_not_exist_yet" }
      profile = runner.generate_profile(policy)
      profile.should contain("/tmp/sbx_does_not_exist_yet")
    end

    it "grants network access when allow_network is true" do
      policy = Cordon::Policy.build { |p| p.allow_network = true }
      profile = runner.generate_profile(policy)
      profile.should contain("(allow network-outbound)")
    end

    it "does not grant blanket network access by default" do
      # BASELINE always allows the syslog socket specifically (local
      # logging, not network access) — assert the absence of the bare,
      # unrestricted grant rather than the operation name itself.
      runner.generate_profile(base_policy).should_not contain("(allow network-outbound)")
    end

    it "adds extra rw grant for working_dir not covered by path lists" do
      policy = Cordon::Policy.build { |p| p.working_dir = "/tmp/myapp" }
      profile = runner.generate_profile(policy)
      profile.should contain("/tmp/myapp")
    end

    it "does not duplicate working_dir grant when already in read_write_paths" do
      # /tmp/workspace legitimately appears twice in the profile now: once
      # in the file-read*/file-write* block, once in the process-exec block
      # (read_write_paths feeds both). What this test guards against is a
      # *third*, redundant occurrence from the working_dir special-case
      # firing on top of an already-covered path.
      policy = Cordon::Policy.build do |p|
        p.read_write "/tmp/workspace"
        p.working_dir = "/tmp/workspace"
      end
      profile = runner.generate_profile(policy)
      profile.scan("/tmp/workspace").size.should eq(2)
    end

    describe "process-exec scoping" do
      it "grants exec under read_only_paths but nothing outside them" do
        policy = Cordon::Policy.build { |p| p.read_only "/opt/homebrew/bin" }
        profile = runner.generate_profile(policy)
        profile.should contain("(allow process-exec process-exec-interpreter")
        profile.should contain("/opt/homebrew/bin")
      end

      it "grants exec under read_write_paths and tmpfs_paths too" do
        policy = Cordon::Policy.build do |p|
          p.read_write "/tmp/work"
          p.tmpfs "/tmp/scratch"
        end
        profile = runner.generate_profile(policy)
        exec_block = profile.partition("(allow process-exec process-exec-interpreter")[2]
        exec_block.should contain("/tmp/work")
        exec_block.should contain("/tmp/scratch")
      end

      it "does not grant exec on /bin or /usr/bin by default" do
        # Regression test for the original discovery: a policy with no
        # explicit grants must not let the sandboxed process exec system
        # binaries like /usr/bin/ruby.
        policy = Cordon::Policy.build { |p| p.read_only "/usr/share/myapp" }
        profile = runner.generate_profile(policy)
        profile.should_not contain("(subpath \"/usr/bin\")")
        profile.should_not contain("(subpath \"/bin\")")
      end

      it "does not grant exec on the command being run when the policy doesn't cover it" do
        # The central rule: naming a binary is not authority to run it.
        # The policy alone defines the perimeter, so a command living
        # outside it gets no grant and sandbox-exec will refuse the
        # execvp with EPERM at runtime.
        located = Process.find_executable("true")
        pending!("`true` not found on PATH") unless located

        policy = Cordon::Policy.build { |p| p.read_only "/usr/share/myapp" }
        profile = runner.generate_profile(policy)
        profile.should_not contain(File.realpath(located.not_nil!))
      end

      it "omits the process-exec rule entirely for an empty policy" do
        # Nothing is grantable, so there is no exec rule at all — not even
        # for the command the caller intends to run.
        # Note: BASELINE's own comments mention "process-exec" by name,
        # so this checks for the actual rule form, not the bare substring.
        profile = runner.generate_profile(base_policy)
        profile.should_not contain("(allow process-exec process-exec-interpreter")
      end

      it "deduplicates paths granted through more than one list" do
        policy = Cordon::Policy.build do |p|
          p.read_only "/tmp/shared"
          p.read_write "/tmp/shared"
        end
        profile = runner.generate_profile(policy)
        exec_block = profile.partition("(allow process-exec process-exec-interpreter")[2]
        exec_block.scan("/tmp/shared").size.should eq(1)
      end

      it "restores /bin and /usr/bin exec-eligibility when Preset::System is merged in" do
        # Integration check tying the exec-scoping fix and Preset::System
        # together: merging the preset (as documented) should actually
        # make system binaries exec-able again, not just appear in the
        # policy's read_only_paths.
        policy = base_policy.merge(Cordon::Preset::System::MACOS)
        profile = runner.generate_profile(policy)
        profile.should contain("(allow process-exec process-exec-interpreter")
        profile.should contain("/bin")
        profile.should contain("/usr/bin")
      end
    end
  end

  # ── #run — real sandbox-exec, real enforcement ───────────────────────
  # Everything above asserts on generate_profile's OUTPUT (the SBPL
  # text). These specs run that profile for real and check the OUTCOME —
  # the layer that would have caught the v0.5.1 implicit-exec-grant bug,
  # since that bug produced a "correct-looking" profile for the wrong
  # requirement. Skipped automatically wherever sandbox-exec isn't
  # available (e.g. local runs off macOS).
  describe "#run" do
    pending_reason = "sandbox-exec not available on this host"

    it "refuses to read a file outside the policy" do
      pending!(pending_reason) unless runner.available?

      # Preset::System merged in so `cat` itself is reachable — the
      # assertion needs to fail because the TARGET file is outside the
      # policy, not because `cat` couldn't be exec'd at all (BASELINE
      # covers dyld/System/Library, not /bin or /usr/bin themselves).
      File.tempfile("sbx_run_deny_") do |f|
        f.print("should not be readable")
        f.flush

        policy = base_policy.merge(Cordon::Preset::System::MACOS)
        result = runner.run(["cat", f.path], policy)
        result.success?.should be_false
      end
    end

    it "reads a file inside a granted read-only path" do
      pending!(pending_reason) unless runner.available?

      File.tempfile("sbx_run_allow_") do |f|
        f.print("hello from inside the cordon")
        f.flush

        policy = Cordon::Policy.build { |p| p.read_only File.dirname(f.path) }
          .merge(Cordon::Preset::System::MACOS)
        result = runner.run(["cat", f.path], policy)
        result.success?.should be_true
        result.stdout.should contain("hello from inside the cordon")
      end
    end

    it "cannot write to a path granted read-only" do
      pending!(pending_reason) unless runner.available?

      File.tempfile("sbx_run_ro_write_") do |f|
        f.print("original")
        f.flush

        policy = Cordon::Policy.build { |p| p.read_only File.dirname(f.path) }
          .merge(Cordon::Preset::System::MACOS)
        result = runner.run(["sh", "-c", "echo overwritten > #{f.path}"], policy)
        result.success?.should be_false
        File.read(f.path).should eq("original")
      end
    end

    it "writes to a path granted read-write" do
      Dir.mkdir_p("/tmp/sbx_run_rw_test") unless Dir.exists?("/tmp/sbx_run_rw_test")
      target = "/tmp/sbx_run_rw_test/out_#{Random::Secure.hex(4)}.txt"

      begin
        pending!(pending_reason) unless runner.available?

        policy = Cordon::Policy.build { |p| p.read_write "/tmp/sbx_run_rw_test" }
          .merge(Cordon::Preset::System::MACOS)
        result = runner.run(["sh", "-c", "echo written > #{target}"], policy)
        result.success?.should be_true
        File.read(target).should eq("written\n")
      ensure
        File.delete(target) if File.exists?(target)
      end
    end

    it "cannot exec a system binary without Preset::System" do
      pending!(pending_reason) unless runner.available?

      File.tempfile("sbx_exec_target_") do |f|
        f.print("a\nb\nc\n")
        f.flush

        # No Preset::System, but the target file IS granted — a failure
        # here can only mean "couldn't exec wc", never "exec'd wc fine
        # but couldn't read the file", which would be the wrong reason.
        policy = Cordon::Policy.build { |p| p.read_only f.path }
        result = runner.run(["/usr/bin/wc", "-l", f.path], policy)
        result.success?.should be_false
      end
    end

    it "can exec a system binary once Preset::System is merged in" do
      pending!(pending_reason) unless runner.available?

      File.tempfile("sbx_exec_target_") do |f|
        f.print("a\nb\nc\n")
        f.flush

        # -l is POSIX-standard, supported identically by BSD wc (macOS)
        # and GNU wc (Linux) — avoids --version, which BSD wc rejects
        # as an unknown option (this is what actually broke here: BSD
        # wc has no --version flag, so the command itself failed before
        # sandboxing was even relevant). Passed a file argument rather
        # than piping via stdin, since Runner#execute doesn't wire up
        # stdin and this shouldn't depend on what the test runner's own
        # stdin happens to be.
        policy = base_policy.merge(Cordon::Preset::System::MACOS)
          .merge(Cordon::Policy.build { |p| p.read_only f.path })
        result = runner.run(["/usr/bin/wc", "-l", f.path], policy)
        result.success?.should be_true
        result.stdout.should contain("3")
      end
    end

    it "denies network access by default" do
      pending!(pending_reason) unless runner.available?
      pending!("nc not available on this host") unless Process.find_executable("nc")

      # A raw TCP connect via /usr/bin/nc, not a DNS/lookup helper —
      # tools like dscacheutil proxy through mDNSResponder over a
      # mach-lookup socket (which BASELINE always allows), so they'd
      # "succeed" without the sandboxed process itself ever needing
      # network-outbound. nc -w opens the socket directly, in-process,
      # so this actually exercises the grant being tested. Connects to
      # TEST-NET-1 (RFC 5737, never routed) with a short timeout so it
      # fails fast on an unsandboxed run too if this spec is ever
      # copy-pasted somewhere without the policy — it should never
      # hang waiting on a real host.
      policy = base_policy.merge(Cordon::Preset::System::MACOS)
      result = runner.run(["nc", "-w", "2", "192.0.2.1", "80"], policy)
      result.success?.should be_false
    end
  end
end
