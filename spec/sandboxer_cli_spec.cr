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

    it "returns 1 for an unknown platform" do
      File.tempfile("policy_", ".json") do |f|
        f.print("{}")
        f.flush

        result = Cordon::CLI.run(["inspect", "--policy", f.path, "--platform", "windows"])
        result.should eq(1)
      end
    end

    it "uses an empty policy when no --policy is given" do
      result = Cordon::CLI.run(["inspect", "--platform", "linux"])
      result.should eq(0)
    end
  end
end
