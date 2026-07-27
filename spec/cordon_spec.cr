require "./spec_helper"

# A fake Runner that records the exec call instead of replacing the
# process, so #relaunch's depth-guard logic can be tested without
# actually exec'ing over the spec process.
private class RecordingRunner < Cordon::Runner
  getter exec_calls = [] of {Array(String), Cordon::Policy}

  def available? : Bool
    true
  end

  def run(command : Array(String), policy : Cordon::Policy) : Cordon::Result
    Cordon::Result.new(0, "", "")
  end

  def exec(command : Array(String), policy : Cordon::Policy) : NoReturn
    @exec_calls << {command, policy}
    raise "RecordingRunner#exec called (test double, not a real NoReturn)"
  end
end

describe Cordon do
  describe ".relaunch" do
    it "relaunches when no depth env is set" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.new

      expect_raises(Exception, "RecordingRunner#exec called") do
        Cordon.relaunch(policy, depth_env: "TEST_DEPTH_UNSET", runner: runner)
      end

      runner.exec_calls.size.should eq(1)
    end

    it "sets the depth env to 1 on first relaunch" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.new

      expect_raises(Exception) do
        Cordon.relaunch(policy, depth_env: "TEST_DEPTH_FIRST", runner: runner)
      end

      _, launched_policy = runner.exec_calls.first
      launched_policy.env["TEST_DEPTH_FIRST"].should eq("1")
    end

    it "does not relaunch when depth has reached max_depth" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.new
      ENV["TEST_DEPTH_MAXED"] = "1"

      begin
        Cordon.relaunch(policy, depth_env: "TEST_DEPTH_MAXED", runner: runner)
      ensure
        ENV.delete("TEST_DEPTH_MAXED")
      end

      runner.exec_calls.should be_empty
    end

    it "respects a custom max_depth" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.new
      ENV["TEST_DEPTH_CUSTOM"] = "1"

      begin
        expect_raises(Exception) do
          Cordon.relaunch(policy, depth_env: "TEST_DEPTH_CUSTOM", max_depth: 3, runner: runner)
        end
      ensure
        ENV.delete("TEST_DEPTH_CUSTOM")
      end

      runner.exec_calls.size.should eq(1)
      _, launched_policy = runner.exec_calls.first
      launched_policy.env["TEST_DEPTH_CUSTOM"].should eq("2")
    end

    it "includes the executable's directory as a read-only path" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.new

      expect_raises(Exception) do
        Cordon.relaunch(policy, depth_env: "TEST_DEPTH_RO", runner: runner)
      end

      _, launched_policy = runner.exec_calls.first
      exe_dir = File.dirname(Process.executable_path.not_nil!)
      launched_policy.read_only_paths.should contain(exe_dir)
    end

    it "merges the caller's policy in rather than replacing it" do
      runner = RecordingRunner.new
      policy = Cordon::Policy.build(&.read_only("/usr/share/myapp"))

      expect_raises(Exception) do
        Cordon.relaunch(policy, depth_env: "TEST_DEPTH_MERGE", runner: runner)
      end

      _, launched_policy = runner.exec_calls.first
      launched_policy.read_only_paths.should contain("/usr/share/myapp")
    end
  end
end
