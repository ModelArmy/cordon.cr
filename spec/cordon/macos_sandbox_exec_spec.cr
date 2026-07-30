require "../spec_helper"

describe Cordon::SandboxExec do
  runner = Cordon::SandboxExec.new
  base_policy = Cordon::Policy.new
  command = ["/usr/bin/true"]

  describe "#generate_profile" do
    it "starts with version and deny default" do
      profile = runner.generate_profile(base_policy, command)
      profile.should contain("(version 1)")
      profile.should contain("(deny default)")
    end

    it "includes the BASELINE" do
      profile = runner.generate_profile(base_policy, command)
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
      profile = runner.generate_profile(base_policy, command)
      profile.should_not contain("(allow process-exec)")
      profile.should_not contain("(allow process-exec-interpreter)")
    end

    it "grants read-only access to read_only_paths" do
      policy = Cordon::Policy.build { |p| p.read_only "/usr/share/myapp" }
      profile = runner.generate_profile(policy, command)
      profile.should contain("(allow file-read*")
      profile.should contain("/usr/share/myapp")
    end

    it "grants read-write access to read_write_paths" do
      policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
      profile = runner.generate_profile(policy, command)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/work")
    end

    it "grants read-write access to tmpfs_paths (no tmpfs on macOS)" do
      policy = Cordon::Policy.build { |p| p.tmpfs "/tmp/scratch" }
      profile = runner.generate_profile(policy, command)
      profile.should contain("(allow file-read* file-write*")
      profile.should contain("/tmp/scratch")
    end

    it "expands relative paths to absolute" do
      policy = Cordon::Policy.build { |p| p.read_only "." }
      profile = runner.generate_profile(policy, command)
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
        profile = runner.generate_profile(policy, command)
        profile.should contain(File.realpath(real_dir))
        profile.should_not contain(link_path)
      ensure
        File.delete(link_path)
        Dir.delete(real_dir)
      end
    end

    it "falls back to expand_path for paths that don't exist yet" do
      policy = Cordon::Policy.build { |p| p.read_write "/tmp/sbx_does_not_exist_yet" }
      profile = runner.generate_profile(policy, command)
      profile.should contain("/tmp/sbx_does_not_exist_yet")
    end

    it "grants network access when allow_network is true" do
      policy = Cordon::Policy.build { |p| p.allow_network = true }
      profile = runner.generate_profile(policy, command)
      profile.should contain("(allow network-outbound)")
    end

    it "does not grant blanket network access by default" do
      # BASELINE always allows the syslog socket specifically (local
      # logging, not network access) — assert the absence of the bare,
      # unrestricted grant rather than the operation name itself.
      runner.generate_profile(base_policy, command).should_not contain("(allow network-outbound)")
    end

    it "adds extra rw grant for working_dir not covered by path lists" do
      policy = Cordon::Policy.build { |p| p.working_dir = "/tmp/myapp" }
      profile = runner.generate_profile(policy, command)
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
      profile = runner.generate_profile(policy, command)
      profile.scan("/tmp/workspace").size.should eq(2)
    end

    describe "process-exec scoping" do
      it "grants exec on the target command's own resolved path" do
        located = Process.find_executable("true")
        pending!("`true` not found on PATH") unless located

        profile = runner.generate_profile(base_policy, [located])
        profile.should contain("(allow process-exec process-exec-interpreter")
        profile.should contain(File.realpath(located))
      end

      it "resolves a bare command name via PATH" do
        # `true` should be found on PATH in any CI/dev environment.
        located = Process.find_executable("true")
        pending!("`true` not found on PATH") unless located

        profile = runner.generate_profile(base_policy, ["true"])
        profile.should contain(File.realpath(located))
      end

      it "grants exec under read_only_paths but nothing outside them" do
        policy = Cordon::Policy.build { |p| p.read_only "/opt/homebrew/bin" }
        profile = runner.generate_profile(policy, command)
        profile.should contain("(allow process-exec process-exec-interpreter")
        profile.should contain("/opt/homebrew/bin")
      end

      it "does not grant exec on /bin or /usr/bin by default" do
        # Regression test for the original discovery: a policy with no
        # explicit grants must not let the sandboxed process exec system
        # binaries like /usr/bin/ruby just because they happen to sit
        # next to /usr/bin/true (the target command in this spec).
        policy = Cordon::Policy.build { |p| p.read_only "/usr/share/myapp" }
        profile = runner.generate_profile(policy, ["/usr/share/myapp/bin/tool"])
        profile.should_not contain("(subpath \"/usr/bin\")")
        profile.should_not contain("(subpath \"/bin\")")
      end

      it "does not duplicate the target path when already covered by a granted path" do
        # Hermetic: uses its own tempdir rather than assuming a real
        # /opt/homebrew layout on the test machine, whose internal symlink
        # structure (Cellar kegs symlinked into bin/) varies by install.
        root = File.join(Dir.tempdir, "sbx_root_#{Random::Secure.hex(4)}")
        bin = File.join(root, "bin")
        Dir.mkdir_p(bin)
        target = File.join(bin, "tool")
        File.write(target, "")
        File.chmod(target, 0o755)

        begin
          policy = Cordon::Policy.build { |p| p.read_only root }
          profile = runner.generate_profile(policy, [target])
          # root appears twice by design: once in file-read*, once in
          # process-exec (read paths feed both). It must NOT appear a
          # third time from the target being redundantly re-added.
          profile.scan(root).size.should eq(2)
        ensure
          File.delete(target)
          Dir.delete(bin)
          Dir.delete(root)
        end
      end

      it "omits the process-exec rule entirely when no paths are grantable" do
        # An empty policy running a command that can't be located (no
        # PATH entry, not an absolute path) has nothing to scope exec to.
        # Note: BASELINE's own comments mention "process-exec" by name,
        # so this checks for the actual rule form, not the bare substring.
        profile = runner.generate_profile(base_policy, ["definitely_not_a_real_command_xyz"])
        profile.should_not contain("(allow process-exec process-exec-interpreter")
      end
    end
  end
end
