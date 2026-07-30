require "../spec_helper"

describe Cordon::Preset::System do
  it "MACOS grants read-only access to /bin and /usr/bin" do
    Cordon::Preset::System::MACOS.read_only_paths.should contain("/bin")
    Cordon::Preset::System::MACOS.read_only_paths.should contain("/usr/bin")
  end

  it "LINUX grants read-only access to /bin and /usr/bin" do
    Cordon::Preset::System::LINUX.read_only_paths.should contain("/bin")
    Cordon::Preset::System::LINUX.read_only_paths.should contain("/usr/bin")
  end

  it "does not grant access to /usr/sbin or /sbin" do
    # Deliberately excluded — see the preset's doc comment. A sandboxed,
    # untrusted process has no ordinary reason to exec system
    # administration tools, and this preset's stated purpose is basic
    # shell/interpreter availability, not full system binary access.
    Cordon::Preset::System::MACOS.read_only_paths.should_not contain("/usr/sbin")
    Cordon::Preset::System::MACOS.read_only_paths.should_not contain("/sbin")
    Cordon::Preset::System::LINUX.read_only_paths.should_not contain("/usr/sbin")
    Cordon::Preset::System::LINUX.read_only_paths.should_not contain("/sbin")
  end

  it "merges into a user policy" do
    policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
    merged = policy.merge(Cordon::Preset::System::MACOS)
    merged.read_write_paths.should contain("/tmp/work")
    merged.read_only_paths.should contain("/bin")
    merged.read_only_paths.should contain("/usr/bin")
  end

  it "does not enable network by default" do
    Cordon::Preset::System::MACOS.allow_network?.should be_false
    Cordon::Preset::System::LINUX.allow_network?.should be_false
  end

  it "grants no read-write or tmpfs access" do
    # Read-only is sufficient: exec-eligibility in Cordon's model derives
    # from read access (see SandboxExec#generate_profile and
    # Bwrap#build_argv's exec-scoping logic), so this preset never needs
    # to grant write access to system binary directories.
    Cordon::Preset::System::MACOS.read_write_paths.should be_empty
    Cordon::Preset::System::MACOS.tmpfs_paths.should be_empty
    Cordon::Preset::System::LINUX.read_write_paths.should be_empty
    Cordon::Preset::System::LINUX.tmpfs_paths.should be_empty
  end

  it "for_current_platform returns the constant matching this compiled platform" do
    known = [Cordon::Preset::System::MACOS, Cordon::Preset::System::LINUX]
    known.should contain(Cordon::Preset::System.for_current_platform)
  end
end
