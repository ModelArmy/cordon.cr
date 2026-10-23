require "../spec_helper"

# Read-only grants for the host's Crystal install: its root, the stdlib
# and library paths `crystal env` reports, and Homebrew where present.
private def crystal_install_policy(crystal : String) : Cordon::Policy
  policy = Cordon::Policy.build do |p|
    p.read_only File.dirname(File.dirname(File.realpath(crystal)))
    {"CRYSTAL_PATH", "CRYSTAL_LIBRARY_PATH"}.each do |name|
      value = `#{Process.quote(crystal)} env #{name}`.strip
      value.split(Process::PATH_DELIMITER).each do |dir|
        p.read_only dir if Path[dir].absolute? && Dir.exists?(dir)
      end
    end
  end
  {% if flag?(:darwin) %}
    policy = policy.merge(Cordon::Preset::Brew.for_current_platform)
  {% end %}
  policy.merge(Cordon::Preset::System.for_current_platform)
end

describe Cordon::Preset::Crystal do
  {% if flag?(:win32) %}
    it "raises UnsupportedPlatformError on Windows" do
      expect_raises(Cordon::UnsupportedPlatformError) do
        Cordon::Preset::Crystal.build(cache_dir: File.tempname, temp_dir: File.tempname)
      end
    end
  {% else %}
    describe ".build" do
      it "grants both directories read-write and points the compiler at them" do
        cache_dir = File.tempname("crystal_cache_")
        temp_dir = File.tempname("crystal_temp_")
        begin
          policy = Cordon::Preset::Crystal.build(cache_dir: cache_dir, temp_dir: temp_dir)
          policy.read_write_paths.should contain(cache_dir)
          policy.read_write_paths.should contain(temp_dir)
          policy.env["CRYSTAL_CACHE_DIR"].should eq(cache_dir)
          policy.env["TMPDIR"].should eq(temp_dir)
          policy.env["SHARDS_CACHE_PATH"].should eq(File.join(temp_dir, "shards"))
          Dir.exists?(File.join(temp_dir, "shards")).should be_true
          policy.allow_network?.should be_false
        ensure
          FileUtils.rm_rf(cache_dir)
          FileUtils.rm_rf(temp_dir)
        end
      end

      it "creates missing directories" do
        cache_dir = File.join(File.tempname("crystal_cache_"), "nested")
        temp_dir = File.tempname("crystal_temp_")
        begin
          Cordon::Preset::Crystal.build(cache_dir: cache_dir, temp_dir: temp_dir)
          Dir.exists?(cache_dir).should be_true
          Dir.exists?(temp_dir).should be_true
        ensure
          FileUtils.rm_rf(File.dirname(cache_dir))
          FileUtils.rm_rf(temp_dir)
        end
      end

      it "grants and points shards at a shards cache directory it is given" do
        cache_dir = File.tempname("crystal_cache_")
        temp_dir = File.tempname("crystal_temp_")
        shards_dir = File.join(File.tempname("shards_cache_"), "nested")
        begin
          policy = Cordon::Preset::Crystal.build(cache_dir: cache_dir, temp_dir: temp_dir, shards_cache_dir: shards_dir)
          policy.read_write_paths.should contain(shards_dir)
          policy.env["SHARDS_CACHE_PATH"].should eq(shards_dir)
          Dir.exists?(shards_dir).should be_true
          Dir.exists?(File.join(temp_dir, "shards")).should be_false
        ensure
          FileUtils.rm_rf(cache_dir)
          FileUtils.rm_rf(temp_dir)
          FileUtils.rm_rf(File.dirname(shards_dir))
        end
      end

      it "expands relative paths, which would otherwise resolve against the sandbox's working directory" do
        dir = File.tempname("crystal_rel_")
        Dir.mkdir(dir)
        begin
          Dir.cd(dir) do
            policy = Cordon::Preset::Crystal.build(cache_dir: "cache", temp_dir: "temp", shards_cache_dir: "shards")
            policy.env["CRYSTAL_CACHE_DIR"].should eq(File.expand_path("cache"))
            policy.env["TMPDIR"].should eq(File.expand_path("temp"))
            policy.env["SHARDS_CACHE_PATH"].should eq(File.expand_path("shards"))
          end
        ensure
          FileUtils.rm_rf(dir)
        end
      end
    end

    {% if flag?(:darwin) %}
      describe ".build on macOS" do
        it "grants the developer tools and routes PATH and SDKROOT past xcrun" do
          pending!("xcrun not found") unless Process.find_executable("xcrun")

          Cordon::Preset::Crystal.with_temp_dir(cache_dir: File.tempname("crystal_cache_"), path_env: "/custom/bin") do |policy|
            developer_dir = `xcode-select -p`.strip
            cc_dir = File.dirname(`xcrun --find cc`.strip)
            policy.read_only_paths.should contain(developer_dir)
            policy.env["PATH"].should eq("#{cc_dir}:/custom/bin")
            policy.env["SDKROOT"].should eq(`xcrun --show-sdk-path`.strip)
            FileUtils.rm_rf(policy.env["CRYSTAL_CACHE_DIR"])
          end
        end
      end
    {% else %}
      describe ".build on Linux" do
        it "leaves PATH to the runner's passthrough" do
          Cordon::Preset::Crystal.with_temp_dir(cache_dir: File.tempname("crystal_cache_"), path_env: "/custom/bin") do |policy|
            policy.env.has_key?("PATH").should be_false
            FileUtils.rm_rf(policy.env["CRYSTAL_CACHE_DIR"])
          end
        end

        it "grants the linker paths that exist, and skips those that don't" do
          Cordon::Preset::Crystal.with_temp_dir(cache_dir: File.tempname("crystal_cache_")) do |policy|
            Cordon::Preset::Crystal::LINUX_TOOLCHAIN_PATHS.each do |path|
              policy.read_only_paths.includes?(path).should eq(Dir.exists?(path))
            end
            FileUtils.rm_rf(policy.env["CRYSTAL_CACHE_DIR"])
          end
        end
      end
    {% end %}

    describe ".with_temp_dir" do
      it "yields a private directory under Dir.tempdir and deletes it afterwards" do
        cache_dir = File.tempname("crystal_cache_")
        seen = [] of String
        begin
          value = Cordon::Preset::Crystal.with_temp_dir(cache_dir: cache_dir) do |policy|
            dir = policy.env["TMPDIR"]
            seen << dir
            File.dirname(dir).should eq(Dir.tempdir)
            File.basename(dir).should start_with(Cordon::Preset::Crystal::TEMP_DIR_PREFIX)
            (File.info(dir).permissions.value & 0o777).should eq(0o700)
            File.write(File.join(dir, "scratch"), "x")
            :done
          end
          value.should eq(:done)
          seen.size.should eq(1)
          Dir.exists?(seen.first).should be_false
        ensure
          FileUtils.rm_rf(cache_dir)
        end
      end

      it "deletes the directory when the block raises, and re-raises" do
        cache_dir = File.tempname("crystal_cache_")
        seen = [] of String
        begin
          expect_raises(Exception, "boom") do
            Cordon::Preset::Crystal.with_temp_dir(cache_dir: cache_dir) do |policy|
              seen << policy.env["TMPDIR"]
              raise "boom"
            end
          end
          seen.size.should eq(1)
          Dir.exists?(seen.first).should be_false
        ensure
          FileUtils.rm_rf(cache_dir)
        end
      end

      it "keeps the cache directories it is given, and deletes the default shards cache" do
        cache_dir = File.tempname("crystal_cache_")
        shards_dir = File.tempname("shards_cache_")
        default_shards_dir = ""
        begin
          Cordon::Preset::Crystal.with_temp_dir(cache_dir: cache_dir, shards_cache_dir: shards_dir) { }
          Cordon::Preset::Crystal.with_temp_dir(cache_dir: cache_dir) do |policy|
            default_shards_dir = policy.env["SHARDS_CACHE_PATH"]
          end
          Dir.exists?(cache_dir).should be_true
          Dir.exists?(shards_dir).should be_true
          Dir.exists?(default_shards_dir).should be_false
        ensure
          FileUtils.rm_rf(cache_dir)
          FileUtils.rm_rf(shards_dir)
        end
      end
    end

    describe ".shared_cache_dir" do
      it "prefers CRYSTAL_CACHE_DIR, as the compiler does" do
        dir = File.tempname("crystal_shared_")
        begin
          with_env({"CRYSTAL_CACHE_DIR" => dir, "XDG_CACHE_HOME" => "/nonexistent-xdg"}) do
            Cordon::Preset::Crystal.shared_cache_dir.should eq(dir)
          end
        ensure
          FileUtils.rm_rf(dir)
        end
      end

      it "falls back to XDG_CACHE_HOME, then HOME" do
        root = File.tempname("crystal_shared_")
        begin
          with_env({"CRYSTAL_CACHE_DIR" => nil, "XDG_CACHE_HOME" => File.join(root, "xdg"), "HOME" => File.join(root, "home")}) do
            Cordon::Preset::Crystal.shared_cache_dir.should eq(File.join(root, "xdg", "crystal"))
          end
          with_env({"CRYSTAL_CACHE_DIR" => nil, "XDG_CACHE_HOME" => nil, "HOME" => File.join(root, "home")}) do
            Cordon::Preset::Crystal.shared_cache_dir.should eq(File.join(root, "home", ".cache", "crystal"))
          end
        ensure
          FileUtils.rm_rf(root)
        end
      end

      it "skips a candidate it cannot create" do
        root = File.tempname("crystal_shared_")
        Dir.mkdir(root)
        blocker = File.join(root, "file")
        File.write(blocker, "")
        begin
          with_env({"CRYSTAL_CACHE_DIR" => File.join(blocker, "cache"), "XDG_CACHE_HOME" => File.join(root, "xdg")}) do
            Cordon::Preset::Crystal.shared_cache_dir.should eq(File.join(root, "xdg", "crystal"))
          end
        ensure
          FileUtils.rm_rf(root)
        end
      end
    end

    describe ".shared_shards_cache_dir" do
      it "prefers SHARDS_CACHE_PATH, as shards does" do
        dir = File.tempname("shards_shared_")
        begin
          with_env({"SHARDS_CACHE_PATH" => dir, "XDG_CACHE_HOME" => "/nonexistent-xdg"}) do
            Cordon::Preset::Crystal.shared_shards_cache_dir.should eq(dir)
          end
        ensure
          FileUtils.rm_rf(dir)
        end
      end

      it "falls back to XDG_CACHE_HOME, then HOME" do
        root = File.tempname("shards_shared_")
        begin
          with_env({"SHARDS_CACHE_PATH" => nil, "XDG_CACHE_HOME" => File.join(root, "xdg"), "HOME" => File.join(root, "home")}) do
            Cordon::Preset::Crystal.shared_shards_cache_dir.should eq(File.join(root, "xdg", "shards"))
          end
          with_env({"SHARDS_CACHE_PATH" => nil, "XDG_CACHE_HOME" => nil, "HOME" => File.join(root, "home")}) do
            Cordon::Preset::Crystal.shared_shards_cache_dir.should eq(File.join(root, "home", ".cache", "shards"))
          end
        ensure
          FileUtils.rm_rf(root)
        end
      end

      it "skips a candidate it cannot create" do
        root = File.tempname("shards_shared_")
        Dir.mkdir(root)
        blocker = File.join(root, "file")
        File.write(blocker, "")
        begin
          with_env({"SHARDS_CACHE_PATH" => File.join(blocker, "cache"), "XDG_CACHE_HOME" => File.join(root, "xdg")}) do
            Cordon::Preset::Crystal.shared_shards_cache_dir.should eq(File.join(root, "xdg", "shards"))
          end
        ensure
          FileUtils.rm_rf(root)
        end
      end
    end

    describe "inside the sandbox" do
      it "runs a Crystal program with `crystal run`" do
        runner = Cordon.platform_runners.find(&.available?)
        pending!("no sandbox runner available") unless runner
        crystal = Process.find_executable("crystal")
        pending!("crystal not found on PATH") unless crystal

        dir = File.tempname("crystal_project_")
        Dir.mkdir(dir)
        begin
          source = File.join(dir, "hello.cr")
          File.write(source, %(puts "hello from a cordoned compiler"))
          project = Cordon::Policy.build do |p|
            p.read_only dir
            p.working_dir = dir
          end
          output = Cordon::Preset::Crystal.with_temp_dir(cache_dir: File.join(dir, "cache")) do |preset|
            policy = project.merge(crystal_install_policy(crystal)).merge(preset)
            runner.spawn([crystal, "run", source], policy, output: :pipe, error: :pipe) do |process|
              stdout = Channel(String).new(1)
              stderr = Channel(String).new(1)
              spawn { stdout.send(process.output.gets_to_end) }
              spawn { stderr.send(process.error.gets_to_end) }
              select
              when text = stdout.receive then {text, stderr.receive}
              when timeout(300.seconds) then {"", "timed out"}
              end
            end
          end
          output[0].should eq("hello from a cordoned compiler\n"), output[1]
        ensure
          FileUtils.rm_rf(dir)
        end
      end
    end
  {% end %}
end
