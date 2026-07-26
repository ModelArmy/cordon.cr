# Preset spec template — copy this file to add specs for a new preset.
#
# Naming convention:  spec/presets/<name>_spec.cr
# Preset location:    src/cordon/presets/<name>.cr
# Module path:        Cordon::Preset::<Name>
#
# Each preset spec should cover:
#   1. Every constant has the expected root path in read_only_paths (or
#      read_write_paths if the preset requires write access).
#   2. Merging the preset into a user policy preserves both sets of paths.
#   3. The preset does not enable network access by default.
#   4. Any preset-specific behaviour (e.g. additional env vars, working_dir).
#
# Run with:  crystal spec spec/presets/brew_spec.cr

require "../spec_helper"

describe Cordon::Preset::Brew do
  it "MACOS_ARM grants read-only access to /opt/homebrew" do
    Cordon::Preset::Brew::MACOS_ARM.read_only_paths.should contain("/opt/homebrew")
  end

  it "MACOS_INTEL grants read-only access to /usr/local" do
    Cordon::Preset::Brew::MACOS_INTEL.read_only_paths.should contain("/usr/local")
  end

  it "LINUX grants read-only access to /home/linuxbrew/.linuxbrew" do
    Cordon::Preset::Brew::LINUX.read_only_paths.should contain("/home/linuxbrew/.linuxbrew")
  end

  it "merges brew preset into a user policy" do
    policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
    merged = policy.merge(Cordon::Preset::Brew::MACOS_ARM)
    merged.read_write_paths.should contain("/tmp/work")
    merged.read_only_paths.should contain("/opt/homebrew")
  end

  it "brew presets do not enable network by default" do
    Cordon::Preset::Brew::MACOS_ARM.allow_network?.should be_false
    Cordon::Preset::Brew::MACOS_INTEL.allow_network?.should be_false
    Cordon::Preset::Brew::LINUX.allow_network?.should be_false
  end
end
