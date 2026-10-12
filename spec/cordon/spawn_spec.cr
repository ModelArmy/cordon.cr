require "../spec_helper"

# Runs its argv unsandboxed and records a launcher file per launch, so
# Runner#spawn's lifecycle can be tested on any host.
private class LocalRunner < Cordon::Runner
  getter files = [] of String

  def initialize(@argv : Array(String))
  end

  def available? : Bool
    true
  end

  def name : String
    "local"
  end

  def exec(command : Array(String), policy : Cordon::Policy) : NoReturn
    raise "LocalRunner#exec is not used"
  end

  protected def launch(command : Array(String), policy : Cordon::Policy, shell : Bool) : Cordon::Launch
    file = File.tempfile("cordon_spawn_spec_", &.print("launcher file"))
    @files << file.path
    Cordon::Launch.new(@argv, [file.path])
  end
end

# A command that copies stdin to stdout and runs until stdin closes.
# sort.exe writes only at end of input; cat writes each line as it arrives.
private def stdin_echo_command : Array(String)
  {% if flag?(:win32) %}
    ["sort.exe"]
  {% else %}
    ["cat"]
  {% end %}
end

# Returns everything *io* yields until end of file, or nil if that takes
# longer than *limit*.
private def read_to_end_within(io : IO, limit : Time::Span) : String?
  done = Channel(String).new(1)
  spawn do
    begin
      done.send(io.gets_to_end)
    rescue IO::Error
      done.send("")
    end
  end
  select
  when text = done.receive
    text
  when timeout(limit)
    nil
  end
end

private def files_gone?(runner : LocalRunner) : Bool
  runner.files.none? { |path| File.exists?(path) }
end

describe Cordon::Runner do
  describe "#spawn" do
    policy = Cordon::Policy.new

    it "returns the block's value" do
      runner = LocalRunner.new(stdin_echo_command)
      value = runner.spawn([] of String, policy, input: :pipe, output: :pipe) { 42 }
      value.should eq(42)
    end

    it "kills a process still running after the block, waits for it and deletes the launcher's files" do
      runner = LocalRunner.new(stdin_echo_command)
      process = runner.spawn([] of String, policy, input: :pipe, output: :pipe) { |spawned| spawned }

      process.waited?.should be_true
      files_gone?(runner).should be_true
    end

    it "re-raises the block's exception after cleaning up" do
      runner = LocalRunner.new(stdin_echo_command)
      yielded = nil

      expect_raises(Exception, "raised in the block") do
        runner.spawn([] of String, policy, input: :pipe, output: :pipe) do |process|
          yielded = process
          raise "raised in the block"
        end
      end

      yielded.try(&.waited?).should be_true
      files_gone?(runner).should be_true
    end

    it "cleans up when the block breaks out" do
      runner = LocalRunner.new(stdin_echo_command)
      process = runner.spawn([] of String, policy, input: :pipe, output: :pipe) { |spawned| break spawned }

      process.waited?.should be_true
      files_gone?(runner).should be_true
    end

    it "lets the block wait for the process itself" do
      runner = LocalRunner.new(stdin_echo_command)
      status = runner.spawn([] of String, policy, input: :pipe, output: :pipe) do |process|
        process.input.close
        process.wait.should be(process.wait)
        process.wait
      end

      status.success?.should be_true
      files_gone?(runner).should be_true
    end

    it "deletes the launcher's files and raises when the process can't start" do
      missing = File.join(Dir.tempdir, "cordon_missing_#{Random::Secure.hex(4)}")
      runner = LocalRunner.new([missing])

      expect_raises(File::Error) do
        runner.spawn([] of String, policy) { }
      end
      files_gone?(runner).should be_true
    end
  end
end

describe "Cordon.spawn in the platform sandbox" do
  pending_reason = "no sandbox runner is available on this host"

  it "passes stdin and stdout through to the sandboxed command" do
    pending!(pending_reason) unless Cordon.platform_runners.any?(&.available?)

    policy = Cordon::Preset::System.for_current_platform
    text = Cordon.spawn(stdin_echo_command, policy, input: :pipe, output: :pipe, error: :pipe) do |process|
      process.input.puts "hello from the cordon"
      process.input.close
      process.output.gets_to_end
    end

    text.strip.should eq("hello from the cordon")
  end

  it "ends the sandboxed command when the yielded process is killed" do
    pending!(pending_reason) unless Cordon.platform_runners.any?(&.available?)

    policy = Cordon::Preset::System.for_current_platform
    text = Cordon.spawn(stdin_echo_command, policy, input: :pipe, output: :pipe, error: :pipe) do |process|
      # Kill only once the command itself is running, not just its launcher.
      {% unless flag?(:win32) %}
        process.input.puts "ready"
        process.output.gets.should eq("ready")
      {% end %}
      process.terminate(graceful: false)
      read_to_end_within(process.output, 5.seconds)
    end

    text.should_not be_nil, "stdout stayed open after the yielded process was killed"
  end
end
