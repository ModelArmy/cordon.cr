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
      policy = Cordon::Policy.build do |p|
        p.read_write "/tmp/workspace"
        p.working_dir = "/tmp/workspace"
      end
      profile = runner.generate_profile(policy)
      profile.scan("/tmp/workspace").size.should eq(1)
    end
  end
end
