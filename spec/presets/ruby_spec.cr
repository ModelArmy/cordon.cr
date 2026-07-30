require "../spec_helper"

describe Cordon::Preset::Ruby do
  # ── Static presets — path coverage ──────────────────────────────────────────

  describe "MACOS_ARM_BREW" do
    it "grants read-only access to Homebrew ARM Ruby lib paths" do
      paths = Cordon::Preset::Ruby::MACOS_ARM_BREW.read_only_paths
      paths.should contain("/opt/homebrew/lib/ruby")
      paths.should contain("/opt/homebrew/opt/ruby")
      paths.should contain("/opt/homebrew/Cellar/ruby")
    end

    it "includes the user gem directory" do
      paths = Cordon::Preset::Ruby::MACOS_ARM_BREW.read_only_paths
      home = ENV["HOME"]?
      paths.any? { |p| p.ends_with?(".gem") }.should be_true if home
    end
  end

  describe "MACOS_INTEL_BREW" do
    it "grants read-only access to Homebrew Intel Ruby lib paths" do
      paths = Cordon::Preset::Ruby::MACOS_INTEL_BREW.read_only_paths
      paths.should contain("/usr/local/lib/ruby")
      paths.should contain("/usr/local/opt/ruby")
      paths.should contain("/usr/local/Cellar/ruby")
    end

    it "includes the user gem directory" do
      paths = Cordon::Preset::Ruby::MACOS_INTEL_BREW.read_only_paths
      home = ENV["HOME"]?
      paths.any? { |p| p.ends_with?(".gem") }.should be_true if home
    end
  end

  describe "LINUX_SYSTEM" do
    it "grants read-only access to system Ruby lib paths" do
      paths = Cordon::Preset::Ruby::LINUX_SYSTEM.read_only_paths
      paths.should contain("/usr/lib/ruby")
      paths.should contain("/usr/local/lib/ruby")
      paths.should contain("/usr/share/ruby")
      paths.should contain("/var/lib/gems")
    end

    it "includes the user gem directory" do
      paths = Cordon::Preset::Ruby::LINUX_SYSTEM.read_only_paths
      home = ENV["HOME"]?
      paths.any? { |p| p.ends_with?(".gem") }.should be_true if home
    end
  end

  describe "LINUX_BREW" do
    it "grants read-only access to Linuxbrew Ruby lib paths" do
      paths = Cordon::Preset::Ruby::LINUX_BREW.read_only_paths
      paths.should contain("/home/linuxbrew/.linuxbrew/lib/ruby")
      paths.should contain("/home/linuxbrew/.linuxbrew/opt/ruby")
      paths.should contain("/home/linuxbrew/.linuxbrew/Cellar/ruby")
    end

    it "includes the user gem directory" do
      paths = Cordon::Preset::Ruby::LINUX_BREW.read_only_paths
      home = ENV["HOME"]?
      paths.any? { |p| p.ends_with?(".gem") }.should be_true if home
    end
  end

  # ── Static presets — shared invariants ──────────────────────────────────────

  it "no preset enables network access" do
    Cordon::Preset::Ruby::MACOS_ARM_BREW.allow_network?.should be_false
    Cordon::Preset::Ruby::MACOS_INTEL_BREW.allow_network?.should be_false
    Cordon::Preset::Ruby::LINUX_SYSTEM.allow_network?.should be_false
    Cordon::Preset::Ruby::LINUX_BREW.allow_network?.should be_false
  end

  it "merges into a user policy preserving both path sets" do
    policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
    merged = policy.merge(Cordon::Preset::Ruby::MACOS_ARM_BREW)
    merged.read_write_paths.should contain("/tmp/work")
    merged.read_only_paths.should contain("/opt/homebrew/lib/ruby")
  end

  # ── for_executable builder ───────────────────────────────────────────────────

  describe ".for_executable" do
    it "derives the install root by walking up two levels from the binary" do
      # Use a real file the CI runner is guaranteed to have.
      ruby_bin = Process.find_executable("ruby")
      pending "ruby not found on this host" unless ruby_bin

      policy = Cordon::Preset::Ruby.for_executable(ruby_bin.not_nil!)
      real = File.realpath(ruby_bin.not_nil!)
      expected_root = File.dirname(File.dirname(real))
      policy.read_only_paths.should contain(expected_root)
    end

    it "resolves symlinks before deriving the root" do
      # Create a temp tree: real_root/bin/ruby (file), link -> real_root/bin/ruby
      tmpdir = Dir.tempdir
      real_root = File.join(tmpdir, "sbx_ruby_root_#{Random::Secure.hex(4)}")
      bin_dir = File.join(real_root, "bin")
      real_bin = File.join(bin_dir, "ruby")
      link_bin = File.join(tmpdir, "sbx_ruby_link_#{Random::Secure.hex(4)}")

      Dir.mkdir_p(bin_dir)
      File.write(real_bin, "")
      File.symlink(real_bin, link_bin)

      begin
        policy = Cordon::Preset::Ruby.for_executable(link_bin)
        policy.read_only_paths.should contain(File.realpath(real_root))
        policy.read_only_paths.should_not contain(File.dirname(link_bin))
      ensure
        File.delete(link_bin)
        File.delete(real_bin)
        Dir.delete(bin_dir)
        Dir.delete(real_root)
      end
    end

    it "includes the user gem directory" do
      ruby_bin = Process.find_executable("ruby")
      pending "ruby not found on this host" unless ruby_bin

      policy = Cordon::Preset::Ruby.for_executable(ruby_bin.not_nil!)
      home = ENV["HOME"]?
      policy.read_only_paths.any? { |p| p.ends_with?(".gem") }.should be_true if home
    end

    it "does not enable network access" do
      ruby_bin = Process.find_executable("ruby")
      pending "ruby not found on this host" unless ruby_bin

      Cordon::Preset::Ruby.for_executable(ruby_bin.not_nil!).allow_network?.should be_false
    end
  end

  # ── for_current_platform ─────────────────────────────────────────────────────

  describe ".for_current_platform" do
    {% if flag?(:darwin) %}
      it "returns the Homebrew preset for this Mac when with_brew: true" do
        policy = Cordon::Preset::Ruby.for_current_platform(with_brew: true)
        known = [Cordon::Preset::Ruby::MACOS_ARM_BREW, Cordon::Preset::Ruby::MACOS_INTEL_BREW]
        known.should contain(policy)
      end

      it "raises UnsupportedPlatformError for with_brew: false — no static macOS system-Ruby preset exists" do
        expect_raises(Cordon::UnsupportedPlatformError, /macOS system-Ruby/) do
          Cordon::Preset::Ruby.for_current_platform(with_brew: false)
        end
      end
    {% elsif flag?(:linux) %}
      it "returns LINUX_BREW for with_brew: true" do
        Cordon::Preset::Ruby.for_current_platform(with_brew: true).should eq(Cordon::Preset::Ruby::LINUX_BREW)
      end

      it "returns LINUX_SYSTEM for with_brew: false" do
        Cordon::Preset::Ruby.for_current_platform(with_brew: false).should eq(Cordon::Preset::Ruby::LINUX_SYSTEM)
      end
    {% end %}
  end
end
