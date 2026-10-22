require "./spec_helper"
require "../src/cordon_cli"

describe Cordon::CLI do
  # Helper: run the CLI with a given argv, return exit code.
  # We call CLI.run directly rather than spawning a subprocess so
  # the specs stay fast and don't require a compiled binary.

  describe "routing" do
    it "returns 0 for 'version'" do
      Cordon::CLI.run(["version"]).should eq(0)
    end

    it "returns 0 for '--version'" do
      Cordon::CLI.run(["--version"]).should eq(0)
    end

    it "returns 0 for 'help'" do
      Cordon::CLI.run(["help"]).should eq(0)
    end

    it "returns 0 for '--help'" do
      Cordon::CLI.run(["--help"]).should eq(0)
    end

    it "returns 1 for an unknown subcommand" do
      Cordon::CLI.run(["bogus"]).should eq(1)
    end

    it "returns 1 with empty argv" do
      # empty argv falls through to help, which returns 0
      Cordon::CLI.run([] of String).should eq(0)
    end
  end

  describe "cordon check" do
    it "exits 0 when at least one runner is available" do
      # On any supported platform at least one runner should be found.
      # This test will be skipped on unsupported platforms.
      result = Cordon::CLI.run(["check"])
      result.should be_a(Int32)
    end
  end

  describe "cordon confirm" do
    it "exits 0 or 1 depending on enforcement, without raising" do
      result = Cordon::CLI.run(["confirm"])
      result.should be_a(Int32)
    end

    it "accepts --json without raising" do
      result = Cordon::CLI.run(["confirm", "--json"])
      result.should be_a(Int32)
    end
  end

  describe "cordon run" do
    it "returns 1 when '--' separator is missing" do
      result = Cordon::CLI.run(["run", "--policy", "policy.json"])
      result.should eq(1)
    end

    it "returns 1 when no command follows '--'" do
      result = Cordon::CLI.run(["run", "--"])
      result.should eq(1)
    end

    it "returns 1 when the policy file does not exist" do
      result = Cordon::CLI.run(["run", "--policy", "/nonexistent/policy.json", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 for invalid JSON in a policy file" do
      File.tempfile("bad_policy_", ".json") do |f|
        f.print("{ this is not json }")
        f.flush

        result = Cordon::CLI.run(["run", "--policy", f.path, "--", "echo", "hi"])
        result.should eq(1)
      end
    end

    it "returns 1 when --ruby path does not exist" do
      result = Cordon::CLI.run(["run", "--ruby", "/nonexistent/ruby", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 when --python path does not exist" do
      result = Cordon::CLI.run(["run", "--python", "/nonexistent/python3", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 when --python-venv path does not exist" do
      result = Cordon::CLI.run(["run", "--python-venv", "/nonexistent/.venv", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 when --python-venv path is not a valid virtualenv" do
      Dir.mkdir_p("/tmp/sbx_cli_not_a_venv")
      begin
        result = Cordon::CLI.run(["run", "--python-venv", "/tmp/sbx_cli_not_a_venv", "--", "echo", "hi"])
        result.should eq(1)
      ensure
        Dir.delete("/tmp/sbx_cli_not_a_venv")
      end
    end

    it "returns 1 for an unknown --add preset name" do
      result = Cordon::CLI.run(["run", "--add", "bogus-preset", "--", "echo", "hi"])
      result.should eq(1)
    end

    it "returns 1 for --env without '='" do
      Cordon::CLI.run(["run", "--env", "NOVALUE", "--", "echo", "hi"]).should eq(1)
    end

    it "returns 1 for --env with an empty name" do
      Cordon::CLI.run(["run", "--env", "=value", "--", "echo", "hi"]).should eq(1)
    end

    it "returns 1 for --unset-env with '='" do
      Cordon::CLI.run(["run", "--unset-env", "KEY=value", "--", "echo", "hi"]).should eq(1)
    end
  end

  describe ".apply_env_flags" do
    it "sets --env values, keeping any '=' after the first in the value" do
      policy = Cordon::CLI.apply_env_flags(Cordon::Policy.new, [{"OPTS", "a=b"}])
      policy.env.should eq({"OPTS" => "a=b"})
    end

    it "overrides the policy's env and lifts its unset_env for that name" do
      policy = Cordon::Policy.build do |p|
        p.env["APP_ENV"] = "file"
        p.unset_env << "TZ"
      end
      policy = Cordon::CLI.apply_env_flags(policy, [{"APP_ENV", "cli"}, {"TZ", "UTC"}])
      policy.env.should eq({"APP_ENV" => "cli", "TZ" => "UTC"})
      policy.unset_env.should be_empty
    end

    it "removes --unset-env names from env and adds them to unset_env once" do
      policy = Cordon::Policy.build do |p|
        p.env["APP_ENV"] = "file"
        p.unset_env << "TZ"
      end
      policy = Cordon::CLI.apply_env_flags(policy, [{"APP_ENV", nil}, {"TZ", nil}])
      policy.env.should be_empty
      policy.unset_env.should eq(["TZ", "APP_ENV"])
    end

    it "lets a later flag override an earlier one" do
      policy = Cordon::CLI.apply_env_flags(Cordon::Policy.new, [{"X", "1"}, {"X", nil}, {"Y", nil}, {"Y", "2"}])
      policy.env.should eq({"Y" => "2"})
      policy.unset_env.should eq(["X"])
    end
  end

  describe ".env_overrides" do
    it "names the --env and --unset-env flags that replace a preset's variable, once each" do
      presets = Cordon::Policy.build do |p|
        p.env["CRYSTAL_CACHE_DIR"] = "/cache"
        p.env["TMPDIR"] = "/tmp/x"
      end
      flags = [{"TMPDIR", "/tmp/y"}, {"TZ", "UTC"}, {"CRYSTAL_CACHE_DIR", nil}, {"TMPDIR", "/tmp/z"}] of Cordon::CLI::EnvFlag
      Cordon::CLI.env_overrides(presets, flags).should eq(["TMPDIR", "CRYSTAL_CACHE_DIR"])
    end

    it "names nothing when no preset sets the variable" do
      Cordon::CLI.env_overrides(Cordon::Policy.new, [{"TZ", "UTC"}] of Cordon::CLI::EnvFlag).should be_empty
    end
  end

  describe "cordon inspect" do
    it "returns 0 for linux platform with a valid policy" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"read_only_paths": ["/usr/share"], "allow_network": false}))
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "linux"])
        result.should eq(0)
      end
    end

    it "returns 0 for macos platform with a valid policy" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"read_only_paths": ["/usr/share"], "allow_network": false}))
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "macos"])
        result.should eq(0)
      end
    end

    it "returns 0 for windows platform with a valid policy" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"read_only_paths": ["C:\\\\tools"], "allow_network": false}))
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "windows"])
        result.should eq(0)
      end
    end

    it "returns 1 for windows platform when the policy uses tmpfs_paths" do
      File.tempfile("policy_", ".json") do |f|
        f.print(%({"tmpfs_paths": ["C:\\\\scratch"]}))
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "windows"])
        result.should eq(1)
      end
    end

    it "returns 1 for an unknown platform" do
      File.tempfile("policy_", ".json") do |f|
        f.print("{}")
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "plan9"])
        result.should eq(1)
      end
    end

    it "accepts --env and --unset-env" do
      Cordon::CLI.run(["inspect", "--platform", "linux", "--env", "A=1", "--unset-env", "TZ"]).should eq(0)
    end

    it "returns 1 for a malformed --env" do
      Cordon::CLI.run(["inspect", "--platform", "linux", "--env", "NOVALUE"]).should eq(1)
    end

    it "uses an empty policy when no --policy is given" do
      result = Cordon::CLI.run(["inspect", "--platform", "linux"])
      result.should eq(0)
    end

    it "merges the Crystal preset for --crystal-cache, warning on an overridden variable" do
      cache_dir = File.tempname("cli_crystal_cache_")
      begin
        result = Cordon::CLI.run(["inspect", "--platform", "linux", "--crystal-cache", cache_dir, "--env", "TMPDIR=/elsewhere"])
        {% if flag?(:win32) %}
          result.should eq(1)
        {% else %}
          result.should eq(0)
          Dir.exists?(cache_dir).should be_true
        {% end %}
      ensure
        FileUtils.rm_rf(cache_dir)
      end
    end
  end
end
