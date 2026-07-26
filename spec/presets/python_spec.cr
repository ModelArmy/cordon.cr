require "../spec_helper"

class PythonHelper
  # Builds a fake venv directory tree with a base interpreter and a
  # pyvenv.cfg, then yields the venv path and base interpreter path.
  def self.with_fake_venv(cfg_key : String, &)
    tmpdir = Dir.tempdir
    base_root = File.join(tmpdir, "sbx_py_base_#{Random::Secure.hex(4)}")
    base_bin_dir = File.join(base_root, "bin")
    base_bin = File.join(base_bin_dir, "python3.11")
    venv_root = File.join(tmpdir, "sbx_py_venv_#{Random::Secure.hex(4)}")

    Dir.mkdir_p(base_bin_dir)
    File.write(base_bin, "")
    Dir.mkdir_p(venv_root)
    File.write(File.join(venv_root, "pyvenv.cfg"), "#{cfg_key} = #{base_bin}\nversion = 3.11.0\n")

    begin
      yield venv_root, base_root
    ensure
      File.delete(base_bin)
      Dir.delete(base_bin_dir)
      Dir.delete(base_root)
      File.delete(File.join(venv_root, "pyvenv.cfg"))
      Dir.delete(venv_root)
    end
  end
end

describe Cordon::Preset::Python do
  # ── Static presets — path coverage ──────────────────────────────────────────

  describe "MACOS_ARM_BREW" do
    it "grants read-only access to Homebrew ARM Python lib paths" do
      paths = Cordon::Preset::Python::MACOS_ARM_BREW.read_only_paths
      paths.should contain("/opt/homebrew/lib/python3.13")
      paths.should contain("/opt/homebrew/opt/python3")
      paths.should contain("/opt/homebrew/Cellar/python3")
    end
  end

  describe "MACOS_INTEL_BREW" do
    it "grants read-only access to Homebrew Intel Python lib paths" do
      paths = Cordon::Preset::Python::MACOS_INTEL_BREW.read_only_paths
      paths.should contain("/usr/local/lib/python3.13")
      paths.should contain("/usr/local/opt/python3")
      paths.should contain("/usr/local/Cellar/python3")
    end
  end

  describe "LINUX_SYSTEM" do
    it "grants read-only access to system Python lib paths" do
      paths = Cordon::Preset::Python::LINUX_SYSTEM.read_only_paths
      paths.should contain("/usr/lib/python3.13")
      paths.should contain("/usr/local/lib/python3.13")
      paths.should contain("/usr/share/python3")
    end
  end

  describe "LINUX_BREW" do
    it "grants read-only access to Linuxbrew Python lib paths" do
      paths = Cordon::Preset::Python::LINUX_BREW.read_only_paths
      paths.should contain("/home/linuxbrew/.linuxbrew/lib/python3.13")
      paths.should contain("/home/linuxbrew/.linuxbrew/opt/python3")
      paths.should contain("/home/linuxbrew/.linuxbrew/Cellar/python3")
    end
  end

  # ── Static presets — shared invariants ──────────────────────────────────────

  it "no preset enables network access" do
    Cordon::Preset::Python::MACOS_ARM_BREW.allow_network?.should be_false
    Cordon::Preset::Python::MACOS_INTEL_BREW.allow_network?.should be_false
    Cordon::Preset::Python::LINUX_SYSTEM.allow_network?.should be_false
    Cordon::Preset::Python::LINUX_BREW.allow_network?.should be_false
  end

  it "merges into a user policy preserving both path sets" do
    policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
    merged = policy.merge(Cordon::Preset::Python::MACOS_ARM_BREW)
    merged.read_write_paths.should contain("/tmp/work")
    merged.read_only_paths.should contain("/opt/homebrew/lib/python3.13")
  end

  # ── for_executable builder ───────────────────────────────────────────────────

  describe ".for_executable" do
    it "derives the install root by walking up two levels from the binary" do
      python_bin = Process.find_executable("python3")
      pending "python3 not found on this host" unless python_bin

      policy = Cordon::Preset::Python.for_executable(python_bin.not_nil!)
      real = File.realpath(python_bin.not_nil!)
      expected_root = File.dirname(File.dirname(real))
      policy.read_only_paths.should contain(expected_root)
    end

    it "resolves symlinks before deriving the root" do
      tmpdir = Dir.tempdir
      real_root = File.join(tmpdir, "sbx_py_root_#{Random::Secure.hex(4)}")
      bin_dir = File.join(real_root, "bin")
      real_bin = File.join(bin_dir, "python3")
      link_bin = File.join(tmpdir, "sbx_py_link_#{Random::Secure.hex(4)}")

      Dir.mkdir_p(bin_dir)
      File.write(real_bin, "")
      File.symlink(real_bin, link_bin)

      begin
        policy = Cordon::Preset::Python.for_executable(link_bin)
        policy.read_only_paths.should contain(File.realpath(real_root))
        policy.read_only_paths.should_not contain(File.dirname(link_bin))
      ensure
        File.delete(link_bin)
        File.delete(real_bin)
        Dir.delete(bin_dir)
        Dir.delete(real_root)
      end
    end

    it "does not enable network access" do
      python_bin = Process.find_executable("python3")
      pending "python3 not found on this host" unless python_bin

      Cordon::Preset::Python.for_executable(python_bin.not_nil!).allow_network?.should be_false
    end
  end

  # ── for_venv builder ─────────────────────────────────────────────────────────

  describe ".for_venv" do
    it "resolves the base interpreter via the 'executable' key" do
      PythonHelper.with_fake_venv("executable") do |venv_root, base_root|
        policy = Cordon::Preset::Python.for_venv(venv_root)
        policy.read_only_paths.should contain(File.realpath(base_root))
        policy.read_only_paths.should contain(File.realpath(venv_root))
      end
    end

    it "falls back to the 'base-executable' key" do
      PythonHelper.with_fake_venv("base-executable") do |venv_root, base_root|
        policy = Cordon::Preset::Python.for_venv(venv_root)
        policy.read_only_paths.should contain(File.realpath(base_root))
        policy.read_only_paths.should contain(File.realpath(venv_root))
      end
    end

    it "raises KeyError when pyvenv.cfg has neither executable key" do
      tmpdir = Dir.tempdir
      venv_root = File.join(tmpdir, "sbx_py_badvenv_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(venv_root)
      File.write(File.join(venv_root, "pyvenv.cfg"), "home = /usr/bin\nversion = 3.11.0\n")

      begin
        expect_raises(KeyError) do
          Cordon::Preset::Python.for_venv(venv_root)
        end
      ensure
        File.delete(File.join(venv_root, "pyvenv.cfg"))
        Dir.delete(venv_root)
      end
    end

    it "raises when the path has no pyvenv.cfg" do
      tmpdir = Dir.tempdir
      not_a_venv = File.join(tmpdir, "sbx_py_notvenv_#{Random::Secure.hex(4)}")
      Dir.mkdir_p(not_a_venv)

      begin
        expect_raises(File::Error) do
          Cordon::Preset::Python.for_venv(not_a_venv)
        end
      ensure
        Dir.delete(not_a_venv)
      end
    end

    it "does not enable network access" do
      PythonHelper.with_fake_venv("executable") do |venv_root, _base_root|
        Cordon::Preset::Python.for_venv(venv_root).allow_network?.should be_false
      end
    end
  end
end
