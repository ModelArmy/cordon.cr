require "../spec_helper"

describe Cordon::Bwrap do
  runner = Cordon::Bwrap.new
  base_policy = Cordon::Policy.new

  describe "#build_argv" do
    it "starts with the bwrap binary" do
      runner.build_argv(["echo", "hi"], base_policy).first.should eq("bwrap")
    end

    it "clears environment and passes through defaults" do
      argv = runner.build_argv(["echo"], base_policy)
      argv.should contain("--clearenv")
    end

    it "mounts proc and dev" do
      argv = runner.build_argv(["echo"], base_policy)
      argv.should contain("--proc")
      argv.should contain("--dev")
    end

    it "always unshares PID namespace" do
      runner.build_argv(["echo"], base_policy).should contain("--unshare-pid")
    end

    it "denies network by default" do
      runner.build_argv(["echo"], base_policy).should contain("--unshare-net")
    end

    it "allows network when policy says so" do
      policy = Cordon::Policy.build { |p| p.allow_network = true }
      argv = runner.build_argv(["echo"], policy)
      argv.should_not contain("--unshare-net")
      argv.should contain("--ro-bind-try")
    end

    it "binds read-only paths with --ro-bind" do
      policy = Cordon::Policy.build { |p| p.read_only "/usr/share" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--ro-bind")
      i.should_not be_nil
      argv[(i.not_nil! + 1)..(i.not_nil! + 2)].should eq(["/usr/share", "/usr/share"])
    end

    it "binds read-write paths with --bind" do
      policy = Cordon::Policy.build { |p| p.read_write "/tmp/work" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--bind")
      i.should_not be_nil
      argv[(i.not_nil! + 1)..(i.not_nil! + 2)].should eq(["/tmp/work", "/tmp/work"])
    end

    it "mounts tmpfs paths with --tmpfs" do
      policy = Cordon::Policy.build { |p| p.tmpfs "/tmp/scratch" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--tmpfs")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/scratch")
    end

    it "sets working directory with --chdir" do
      policy = Cordon::Policy.build { |p| p.working_dir = "/tmp/work" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--chdir")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("/tmp/work")
    end

    it "adds --new-session when new_session is true" do
      runner.build_argv(["echo"], base_policy).should contain("--new-session")
    end

    it "omits --new-session when new_session is false" do
      policy = Cordon::Policy.build { |p| p.new_session = false }
      runner.build_argv(["echo"], policy).should_not contain("--new-session")
    end

    it "appends -- and the command at the end" do
      argv = runner.build_argv(["ls", "-la"], base_policy)
      sep = argv.index("--").not_nil!
      argv[(sep + 1)..].should eq(["ls", "-la"])
    end

    it "passes through policy env vars" do
      policy = Cordon::Policy.build { |p| p.env["MY_VAR"] = "hello" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("MY_VAR")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("hello")
    end

    it "adds --unsetenv for unset_env entries" do
      policy = Cordon::Policy.build { |p| p.unset_env << "SECRET" }
      argv = runner.build_argv(["echo"], policy)
      i = argv.index("--unsetenv")
      i.should_not be_nil
      argv[i.not_nil! + 1].should eq("SECRET")
    end
  end
end
