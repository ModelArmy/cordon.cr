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

    describe "exec scoping (binary directories)" do
      it "does not mount /usr/bin, /bin, /usr/sbin, or /sbin by default" do
        # Regression test for the discovery that bwrap's mount namespace
        # has no permission distinct from "visible" — unconditionally
        # mounting binary directories would let a sandboxed process exec
        # any system binary (e.g. /usr/bin/ruby) regardless of what the
        # policy actually grants.
        argv = runner.build_argv(["/usr/bin/wc"], base_policy)
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].each do |dir|
          argv.should_not contain(dir)
        end
      end

      it "still mounts system library paths unconditionally" do
        argv = runner.build_argv(["/usr/bin/wc"], base_policy)
        argv.should contain("/usr/lib")
      end

      it "restores /bin and /usr/bin when Preset::System is merged in" do
        # Integration check tying the exec-scoping fix and Preset::System
        # together: merging the preset (as documented) should actually
        # make system binaries mountable/exec-able again, not just appear
        # in the policy's read_only_paths.
        policy = base_policy.merge(Cordon::Preset::System::LINUX)
        argv = runner.build_argv(["/usr/bin/wc"], policy)

        ro_bind_pairs = [] of {String, String}
        argv.each_with_index do |token, i|
          next unless token == "--ro-bind"
          ro_bind_pairs << {argv[i + 1], argv[i + 2]}
        end

        ["/bin", "/usr/bin"].each do |dir|
          ro_bind_pairs.should contain({dir, dir})
        end
      end
    end

    describe "the target command gets no implicit mount" do
      # Hermetic dummy binary — avoids depending on where /usr/bin/echo
      # (or its symlink chain) actually lives on the test machine.
      # Dir.tempdir is pre-resolved via realpath so that literal and
      # resolved forms of paths beneath it agree (macOS CI runners mount
      # /tmp as a symlink to /private/tmp, and this spec runs there too).
      tmp_root = begin
        File.realpath(Dir.tempdir)
      rescue File::Error
        Dir.tempdir
      end
      root = File.join(tmp_root, "bwrap_root_#{Random::Secure.hex(4)}")
      bin_dir = File.join(root, "bin")
      dummy = File.join(bin_dir, "tool")

      before_each do
        Dir.mkdir_p(bin_dir)
        File.write(dummy, "")
        File.chmod(dummy, 0o755)
      end

      after_each do
        File.delete(dummy) if File.exists?(dummy)
        Dir.delete(bin_dir) if Dir.exists?(bin_dir)
        Dir.delete(root) if Dir.exists?(root)
      end

      it "does not bind-mount the command when the policy doesn't cover it" do
        # The central rule: naming a binary is not authority to run it.
        # The binary appears exactly once in argv — as the trailing
        # command after "--" — and gets no --ro-bind of its own, so it
        # will not exist inside the namespace and bwrap will fail its
        # execvp with ENOENT.
        argv = runner.build_argv([dummy], base_policy)
        argv.count { |e| e == dummy }.should eq(1)
        sep = argv.index("--").not_nil!
        argv[sep + 1].should eq(dummy)
      end

      it "does not bind-mount a bare command name resolved via PATH" do
        located = Process.find_executable("true")
        pending!("`true` not found on PATH") unless located

        argv = runner.build_argv(["true"], base_policy)
        real = File.realpath(located.not_nil!)
        argv.should_not contain(located)
        argv.should_not contain(real)
      end

      it "mounts the command only when the policy grants its location" do
        policy = Cordon::Policy.build { |p| p.read_only root }
        argv = runner.build_argv([dummy], policy)
        i = argv.index("--ro-bind").not_nil!
        argv[(i + 1)..(i + 2)].should eq([root, root])
      end
    end
  end
end
