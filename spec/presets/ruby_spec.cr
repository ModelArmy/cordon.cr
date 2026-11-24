require "../spec_helper"
require "file_utils"

describe Cordon::Preset::Ruby do
  # ── Static presets — path coverage ──────────────────────────────────────────

  describe "MACOS_ARM_BREW" do
    it "grants read-only access to Homebrew ARM Ruby lib paths" do
      paths = Cordon::Preset::Ruby::MACOS_ARM_BREW.read_only_paths
      paths.should contain("/opt/homebrew/lib/ruby")
      paths.should contain("/opt/homebrew/opt/ruby")
      paths.should contain("/opt/homebrew/Cellar/ruby")
    end

    it "includes the user gem directories that exist" do
      paths = Cordon::Preset::Ruby::MACOS_ARM_BREW.read_only_paths
      Cordon::Preset::Ruby.user_gem_dirs.each { |dir| paths.should contain(dir) }
    end
  end

  describe "MACOS_INTEL_BREW" do
    it "grants read-only access to Homebrew Intel Ruby lib paths" do
      paths = Cordon::Preset::Ruby::MACOS_INTEL_BREW.read_only_paths
      paths.should contain("/usr/local/lib/ruby")
      paths.should contain("/usr/local/opt/ruby")
      paths.should contain("/usr/local/Cellar/ruby")
    end

    it "includes the user gem directories that exist" do
      paths = Cordon::Preset::Ruby::MACOS_INTEL_BREW.read_only_paths
      Cordon::Preset::Ruby.user_gem_dirs.each { |dir| paths.should contain(dir) }
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

    it "includes the user gem directories that exist" do
      paths = Cordon::Preset::Ruby::LINUX_SYSTEM.read_only_paths
      Cordon::Preset::Ruby.user_gem_dirs.each { |dir| paths.should contain(dir) }
    end
  end

  describe "LINUX_BREW" do
    it "grants read-only access to Linuxbrew Ruby lib paths" do
      paths = Cordon::Preset::Ruby::LINUX_BREW.read_only_paths
      paths.should contain("/home/linuxbrew/.linuxbrew/lib/ruby")
      paths.should contain("/home/linuxbrew/.linuxbrew/opt/ruby")
      paths.should contain("/home/linuxbrew/.linuxbrew/Cellar/ruby")
    end

    it "includes the user gem directories that exist" do
      paths = Cordon::Preset::Ruby::LINUX_BREW.read_only_paths
      Cordon::Preset::Ruby.user_gem_dirs.each { |dir| paths.should contain(dir) }
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
      pending!("ruby not found on this host") unless ruby_bin

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

    it "includes the user gem directories that exist" do
      ruby_bin = Process.find_executable("ruby")
      pending!("ruby not found on this host") unless ruby_bin

      policy = Cordon::Preset::Ruby.for_executable(ruby_bin.not_nil!)
      Cordon::Preset::Ruby.user_gem_dirs.each { |dir| policy.read_only_paths.should contain(dir) }
    end

    it "does not enable network access" do
      ruby_bin = Process.find_executable("ruby")
      pending!("ruby not found on this host") unless ruby_bin

      Cordon::Preset::Ruby.for_executable(ruby_bin.not_nil!).allow_network?.should be_false
    end
  end

  # ── user_gem_dirs ────────────────────────────────────────────────────────────

  describe ".user_gem_dirs" do
    it "returns nothing when there is no home" do
      Cordon::Preset::Ruby.user_gem_dirs(nil).should be_empty
    end

    it "returns nothing when neither directory exists" do
      with_ruby_spec_dir do |home|
        Cordon::Preset::Ruby.user_gem_dirs(home).should be_empty
      end
    end

    it "returns ~/.gem when it exists" do
      with_ruby_spec_dir do |home|
        Dir.mkdir_p(File.join(home, ".gem"))
        Cordon::Preset::Ruby.user_gem_dirs(home).should eq([File.join(home, ".gem")])
      end
    end

    it "returns ~/.local/share/gem, which RubyGems uses when ~/.gem is absent" do
      with_ruby_spec_dir do |home|
        Dir.mkdir_p(File.join(home, ".local", "share", "gem"))
        Cordon::Preset::Ruby.user_gem_dirs(home).should eq([File.join(home, ".local", "share", "gem")])
      end
    end

    it "returns both when both exist" do
      with_ruby_spec_dir do |home|
        Dir.mkdir_p(File.join(home, ".gem"))
        Dir.mkdir_p(File.join(home, ".local", "share", "gem"))
        Cordon::Preset::Ruby.user_gem_dirs(home).size.should eq(2)
      end
    end
  end

  # ── for_executable: GEM_HOME and GEM_PATH ────────────────────────────────────

  describe ".for_executable with gem_home and gem_path" do
    it "sets no variables by default" do
      with_ruby_spec_binary do |ruby|
        policy = Cordon::Preset::Ruby.for_executable(ruby)
        policy.env.should be_empty
      end
    end

    it "grants an existing gem_home read-only and sets GEM_HOME" do
      with_ruby_spec_binary do |ruby, dir|
        gems = File.join(dir, "gems")
        Dir.mkdir_p(gems)
        policy = Cordon::Preset::Ruby.for_executable(ruby, gem_home: gems)
        policy.read_only_paths.should contain(gems)
        policy.read_write_paths.should_not contain(gems)
        policy.env["GEM_HOME"].should eq(gems)
      end
    end

    it "sets GEM_HOME without a grant when the directory does not exist yet" do
      with_ruby_spec_binary do |ruby, dir|
        gems = File.join(dir, "not-yet")
        policy = Cordon::Preset::Ruby.for_executable(ruby, gem_home: gems)
        policy.read_only_paths.should_not contain(gems)
        policy.env["GEM_HOME"].should eq(gems)
      end
    end

    it "makes a relative gem_home absolute" do
      with_ruby_spec_binary do |ruby|
        policy = Cordon::Preset::Ruby.for_executable(ruby, gem_home: "relative/gems")
        policy.env["GEM_HOME"].should eq(File.expand_path("relative/gems"))
      end
    end

    it "ignores an empty gem_home and gem_path" do
      with_ruby_spec_binary do |ruby|
        policy = Cordon::Preset::Ruby.for_executable(ruby, gem_home: "", gem_path: "")
        policy.env.should be_empty
      end
    end

    it "splits gem_path, grants each existing entry once and sets GEM_PATH" do
      with_ruby_spec_binary do |ruby, dir|
        first = File.join(dir, "first")
        second = File.join(dir, "second")
        missing = File.join(dir, "missing")
        Dir.mkdir_p(first)
        Dir.mkdir_p(second)
        value = [first, missing, second, first].join(Process::PATH_DELIMITER)
        policy = Cordon::Preset::Ruby.for_executable(ruby, gem_path: value)
        policy.read_only_paths.count(first).should eq(1)
        policy.read_only_paths.should contain(second)
        policy.read_only_paths.should_not contain(missing)
        policy.env["GEM_PATH"].should eq([first, missing, second].join(Process::PATH_DELIMITER))
      end
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

# Yields a fresh temporary directory, deleted afterwards.
private def with_ruby_spec_dir(&)
  dir = File.tempname("cordon-ruby-spec", nil)
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Yields the path of an empty file at `<dir>/root/bin/ruby`, and *dir*.
private def with_ruby_spec_binary(&)
  with_ruby_spec_dir do |dir|
    bin = File.join(dir, "root", "bin")
    Dir.mkdir_p(bin)
    ruby = File.join(bin, "ruby")
    File.write(ruby, "")
    yield ruby, dir
  end
end
