require "../spec_helper"
require "file_utils"

private def set_env(key : String, value : String?) : Nil
  if value
    ENV[key] = value
  else
    ENV.delete(key)
  end
end

# Sets *vars* (nil deletes) for the duration of the block, then restores them.
private def with_env(vars, &)
  saved = vars.keys.to_h { |key| {key, ENV[key]?} }
  begin
    vars.each { |key, value| set_env(key, value) }
    yield
  ensure
    saved.each { |key, value| set_env(key, value) }
  end
end

# Yields the path of an executable shell script standing in for wxc-exec.exe.
private def fake_wxc_exec(body : String, &)
  path = File.tempname("fake-wxc-exec", ".sh")
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
  end
end

# Yields a fresh directory under the system temp dir, removed afterwards.
private def with_scratch_dir(&)
  dir = File.join(Dir.tempdir, "cordon_mxc_#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Failure message showing everything a Result carries.
private def explain(result : Cordon::Result) : String
  "exit code #{result.exit_code}\n--- stdout ---\n#{result.stdout}\n--- stderr ---\n#{result.stderr}"
end

# Policy granting *dir* read-write and running in it.
private def scratch_policy(dir : String) : Cordon::Policy
  Cordon::Policy.build do |p|
    p.read_write dir
    p.working_dir = dir
  end
end

private def config_for(command : Array(String), policy : Cordon::Policy, shell : Bool = false) : JSON::Any
  JSON.parse(Cordon::Mxc.new.build_config(command, policy, shell))
end

private def env_entries(config : JSON::Any, name : String) : Array(String)
  config["process"]["env"].as_a.map(&.as_s).select(&.downcase.starts_with?("#{name.downcase}="))
end

describe Cordon::Mxc do
  base_policy = Cordon::Policy.new

  describe "#build_config" do
    it "declares the schema version and process containment" do
      config = config_for(["cmd.exe"], base_policy)
      config["version"].should eq(Cordon::Mxc::SCHEMA_VERSION)
      config["containment"].should eq("processcontainer")
    end

    it "gives every config a fresh containerId" do
      first = config_for(["cmd.exe"], base_policy)["containerId"].as_s
      second = config_for(["cmd.exe"], base_policy)["containerId"].as_s
      first.should start_with("cordon-")
      first.should_not eq(second)
    end

    it "forbids MXC's ACL-modifying fallback" do
      config_for(["cmd.exe"], base_policy)["fallback"]["allowDaclMutation"].as_bool.should be_false
    end

    it "keeps UI access so PowerShell can start" do
      config_for(["cmd.exe"], base_policy)["ui"]["disable"].as_bool.should be_false
    end

    it "maps read-only and read-write paths" do
      policy = Cordon::Policy.build do |p|
        p.read_only "C:\\cordon-spec\\tools"
        p.read_write "C:\\cordon-spec\\work"
      end
      filesystem = config_for(["cmd.exe"], policy)["filesystem"]
      filesystem["readonlyPaths"].as_a.map(&.as_s).should eq(["C:\\cordon-spec\\tools"])
      filesystem["readwritePaths"].as_a.map(&.as_s).should eq(["C:\\cordon-spec\\work"])
    end

    it "blocks network by default, enforced through capabilities" do
      network = config_for(["cmd.exe"], base_policy)["network"]
      network["defaultPolicy"].should eq("block")
      network["enforcementMode"].should eq("capabilities")
    end

    it "allows network when the policy says so" do
      policy = Cordon::Policy.build { |p| p.allow_network = true }
      config_for(["cmd.exe"], policy)["network"]["defaultPolicy"].should eq("allow")
    end

    it "grants a short-form path in both forms and runs in its long form" do
      {% unless flag?(:win32) %}
        pending!("8.3 short paths exist only on Windows")
      {% end %}
      with_scratch_dir do |dir|
        pending!("the temp dir is not in 8.3 short form on this host") unless dir.includes?('~')

        policy = Cordon::Policy.build do |p|
          p.read_write dir
          p.working_dir = dir
        end
        config = config_for(["cmd.exe"], policy)
        paths = config["filesystem"]["readwritePaths"].as_a.map(&.as_s)
        paths.size.should eq(2)
        paths[0].should eq(dir)
        paths[1].should_not contain('~')
        config["process"]["cwd"].should eq(paths[1])
      end
    end

    it "sets cwd from working_dir, and omits it when unset" do
      policy = Cordon::Policy.build { |p| p.working_dir = "C:\\work" }
      config_for(["cmd.exe"], policy)["process"]["cwd"].should eq("C:\\work")
      config_for(["cmd.exe"], base_policy)["process"]["cwd"]?.should be_nil
    end

    it "raises PolicyError for tmpfs_paths" do
      policy = Cordon::Policy.build(&.tmpfs("C:\\scratch"))
      expect_raises(Cordon::PolicyError, /tmpfs_paths/) do
        Cordon::Mxc.new.build_config(["cmd.exe"], policy)
      end
    end

    it "quotes command elements into one Windows command line" do
      command = ["C:\\Program Files\\tool.exe", "two words", "plain"]
      config_for(command, base_policy)["process"]["commandLine"]
        .should eq(%("C:\\Program Files\\tool.exe" "two words" plain))
    end

    it "refuses a batch file as the command unless shell is true" do
      ["C:\\tools\\build.bat", "run.CMD", "run.cmd. "].each do |program|
        expect_raises(ArgumentError, /batch file/) do
          Cordon::Mxc.new.build_config([program, "arg"], base_policy)
        end
      end
      config_for(["C:\\tools\\build.bat"], base_policy, shell: true)["process"]["commandLine"]
        .should eq(%(cmd.exe /d /s /c "C:\\tools\\build.bat"))
    end

    it "runs a shell script through cmd.exe when shell is true" do
      config_for(["echo hi && dir"], base_policy, shell: true)["process"]["commandLine"]
        .should eq(%(cmd.exe /d /s /c "echo hi && dir"))
    end

    it "raises when shell is true and more than one command element is given" do
      expect_raises(ArgumentError) do
        Cordon::Mxc.new.build_config(["echo", "hi"], base_policy, shell: true)
      end
    end
  end

  describe "#build_config environment" do
    it "includes policy env" do
      policy = Cordon::Policy.build { |p| p.env["CORDON_SPEC_VAR"] = "value" }
      env_entries(config_for(["cmd.exe"], policy), "CORDON_SPEC_VAR").should eq(["CORDON_SPEC_VAR=value"])
    end

    it "passes PATH through from the parent" do
      with_env({"PATH" => "spec-path"}) do
        env_entries(config_for(["cmd.exe"], base_policy), "PATH").should eq(["PATH=spec-path"])
      end
    end

    it "drops parent variables outside the passthrough list" do
      with_env({"CORDON_SPEC_PRIVATE" => "secret"}) do
        env_entries(config_for(["cmd.exe"], base_policy), "CORDON_SPEC_PRIVATE").should be_empty
      end
    end

    it "lets policy env replace a passthrough variable regardless of case" do
      with_env({"PATH" => "spec-path"}) do
        policy = Cordon::Policy.build { |p| p.env["Path"] = "custom-path" }
        env_entries(config_for(["cmd.exe"], policy), "PATH").should eq(["Path=custom-path"])
      end
    end

    it "removes unset_env names regardless of case" do
      with_env({"PATH" => "spec-path"}) do
        policy = Cordon::Policy.build { |p| p.unset_env << "path" }
        env_entries(config_for(["cmd.exe"], policy), "PATH").should be_empty
      end
    end
  end

  describe "#build_argv" do
    it "passes the config to wxc-exec.exe base64-encoded" do
      fake_wxc_exec("exit 0") do |path|
        argv = Cordon::Mxc.new(path).build_argv(["cmd.exe"], base_policy)
        argv[0].should eq(path)
        argv[1].should eq("--config-base64")
        JSON.parse(Base64.decode_string(argv[2]))["process"]["commandLine"].should eq("cmd.exe")
      end
    end
  end

  describe "#wxc_exec_candidates" do
    it "tries the explicit path first, then CORDON_WXC_EXEC" do
      with_env({Cordon::Mxc::WXC_EXEC_ENV => "C:\\env\\wxc-exec.exe"}) do
        candidates = Cordon::Mxc.new("C:\\explicit\\wxc-exec.exe").wxc_exec_candidates
        candidates[0, 2].should eq(["C:\\explicit\\wxc-exec.exe", "C:\\env\\wxc-exec.exe"])
      end
    end

    it "looks in the versioned per-user folder before the all-users folder" do
      with_env({"LOCALAPPDATA" => "C:\\Users\\u\\AppData\\Local", "ProgramFiles" => "C:\\Program Files"}) do
        candidates = Cordon::Mxc.new.wxc_exec_candidates
        version = Cordon::Mxc::MXC_VERSION
        per_user = "C:\\Users\\u\\AppData\\Local\\cordon\\mxc\\#{version}\\wxc-exec.exe"
        all_users = "C:\\Program Files\\cordon\\mxc\\#{version}\\wxc-exec.exe"
        candidates.select { |path| path == per_user || path == all_users }.should eq([per_user, all_users])
      end
    end
  end

  describe "#wxc_exec_path" do
    it "returns the first candidate that exists" do
      fake_wxc_exec("exit 0") do |path|
        with_env({Cordon::Mxc::WXC_EXEC_ENV => path}) do
          Cordon::Mxc.new("C:\\does\\not\\exist\\wxc-exec.exe").wxc_exec_path.should eq(path)
        end
      end
    end
  end

  describe "#available?" do
    it "is true when the probe reports the PSEC tier, skipping any preamble" do
      {% if flag?(:win32) %}
        pending!("uses a shell script as a stand-in for wxc-exec.exe")
      {% end %}
      fake_wxc_exec(%(echo 'warning: preamble'\necho '{"tier": "base-container"}')) do |path|
        runner = Cordon::Mxc.new(path)
        runner.available?.should be_true
        runner.tier.should eq("base-container")
      end
    end

    it "is false when the probe reports another tier, and run says why" do
      {% if flag?(:win32) %}
        pending!("uses a shell script as a stand-in for wxc-exec.exe")
      {% end %}
      fake_wxc_exec(%(echo '{"tier": "appcontainer-dacl"}')) do |path|
        runner = Cordon::Mxc.new(path)
        runner.available?.should be_false
        expect_raises(Cordon::RunnerUnavailableError, /appcontainer-dacl/) do
          runner.run(["cmd.exe"], base_policy)
        end
      end
    end

    it "refuses to run without the environment Windows requires" do
      {% if flag?(:win32) %}
        pending!("uses a shell script as a stand-in for wxc-exec.exe")
      {% end %}
      fake_wxc_exec(%(echo '{"tier": "base-container"}')) do |path|
        with_env({"SystemRoot" => "C:\\Windows", "LOCALAPPDATA" => "C:\\Users\\u\\AppData\\Local"}) do
          policy = Cordon::Policy.build { |p| p.unset_env << "localappdata" }
          expect_raises(Cordon::PolicyError, /LOCALAPPDATA/) do
            Cordon::Mxc.new(path).run(["cmd.exe"], policy)
          end
        end
      end
    end

    it "is false when the probe fails" do
      {% if flag?(:win32) %}
        pending!("uses a shell script as a stand-in for wxc-exec.exe")
      {% end %}
      fake_wxc_exec("exit 1") do |path|
        runner = Cordon::Mxc.new(path)
        runner.available?.should be_false
        runner.tier.should be_nil
      end
    end
  end

  # Real enforcement: runs only where wxc-exec.exe reports the PSEC tier
  # (the windows-11-arm CI runner, after scripts/check-windows.ps1 -Install).
  # Denials are checked with cmd.exe scripts that print STARTED first (the
  # caret keeps the literal out of the command line), so a sandbox that
  # failed to launch cannot pass as enforcement.
  describe "#run" do
    runner = Cordon::Mxc.new
    pending_reason = "wxc-exec.exe with the PSEC tier is not available on this host"

    # TEMPORARY diagnostic, never fails: explicit Import-Module works in the
    # sandbox but autoloading Write-Output does not. Runs Write-Output under
    # environment variants through Mxc#run and prints the results.
    it "DIAGNOSTIC: PowerShell cmdlet autoloading" do
      pending!(pending_reason) unless runner.available?

      script = "try { Write-Output autoload-ok } catch { 'autoload failed: ' + $_ }; " \
               "'MyDocuments=[' + [Environment]::GetFolderPath('MyDocuments') + ']'; " \
               "$cache = $env:LOCALAPPDATA + '\\Microsoft\\Windows\\PowerShell\\ModuleAnalysisCache'; " \
               "'cache exists=' + [IO.File]::Exists($cache); " \
               "try { [void][IO.File]::ReadAllBytes($cache); 'cache readable=True' } catch { 'cache readable=' + $_ }"
      command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script]
      system_modules = "C:\\Windows\\system32\\WindowsPowerShell\\v1.0\\Modules"
      variants = {
        "Mxc env as is"                     => {} of String => String,
        "PSModuleAnalysisCachePath=nul"     => {"PSModuleAnalysisCachePath" => "nul"},
        "PSModulePath=system only"          => {"PSModulePath" => system_modules},
        "cache nul and system PSModulePath" => {"PSModuleAnalysisCachePath" => "nul", "PSModulePath" => system_modules},
      }

      with_scratch_dir do |dir|
        variants.each do |label, extra|
          policy = scratch_policy(dir).merge(Cordon::Policy.build { |p| p.env.merge!(extra) })
          result = runner.run(command, policy)
          puts "\n=== #{label}: exit #{result.exit_code} ===\nstdout:\n#{result.stdout}\nstderr:\n#{result.stderr}"
        end
      end
    end

    it "runs a command and captures its output" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        result = runner.run(["echo hello from the cordon"], scratch_policy(dir), shell: true)
        result.success?.should be_true, explain(result)
        result.stdout.should contain("hello from the cordon"), explain(result)
      end
    end

    it "passes the exit code through" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        result = runner.run(["exit 7"], scratch_policy(dir), shell: true)
        result.exit_code.should eq(7), explain(result)
      end
    end

    it "reports an NTSTATUS exit code as a signed value" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        # 0xC0000142 (STATUS_DLL_INIT_FAILED), which Crystal classes as an
        # abnormal exit.
        result = runner.run(["exit -1073741502"], scratch_policy(dir), shell: true)
        result.exit_code.should eq(-1073741502), explain(result)
      end
    end

    it "refuses to read a file outside the policy" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        with_scratch_dir do |outside|
          target = File.join(outside, "secret.txt")
          File.write(target, "not for the cordon")

          result = runner.run([%(echo STAR^TED& type "#{target}")], scratch_policy(dir), shell: true)
          result.stdout.should contain("STARTED"), explain(result)
          result.success?.should be_false, explain(result)
          result.stdout.should_not contain("not for the cordon"), explain(result)
        end
      end
    end

    it "reads a file inside a granted read-only path" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        with_scratch_dir do |ro|
          target = File.join(ro, "notes.txt")
          File.write(target, "hello from a read-only path")

          policy = scratch_policy(dir).merge(Cordon::Policy.build(&.read_only(ro)))
          result = runner.run([%(type "#{target}")], policy, shell: true)
          result.success?.should be_true, explain(result)
          result.stdout.should contain("hello from a read-only path"), explain(result)
        end
      end
    end

    it "cannot write to a path granted read-only" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        with_scratch_dir do |ro|
          target = File.join(ro, "notes.txt")
          File.write(target, "original")

          policy = scratch_policy(dir).merge(Cordon::Policy.build(&.read_only(ro)))
          result = runner.run([%(echo STAR^TED& echo overwritten> "#{target}")], policy, shell: true)
          result.stdout.should contain("STARTED"), explain(result)
          result.success?.should be_false, explain(result)
          File.read(target).should eq("original")
        end
      end
    end

    it "writes to a path granted read-write" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        target = File.join(dir, "out.txt")
        result = runner.run([%(echo written> "#{target}")], scratch_policy(dir), shell: true)
        result.success?.should be_true, explain(result)
        File.read(target).should contain("written")
      end
    end

    it "passes policy env and drops the rest of the parent environment" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        with_env({"CORDON_SPEC_PRIVATE" => "leaked"}) do
          policy = scratch_policy(dir).merge(Cordon::Policy.build { |p| p.env["CORDON_SPEC_VAR"] = "granted" })
          result = runner.run(["echo [%CORDON_SPEC_VAR%] [%CORDON_SPEC_PRIVATE%]"], policy, shell: true)
          result.stdout.should contain("[granted]"), explain(result)
          result.stdout.should contain("[%CORDON_SPEC_PRIVATE%]"), explain(result)
        end
      end
    end

    it "starts PowerShell with the default environment passthrough" do
      pending!(pending_reason) unless runner.available?

      with_scratch_dir do |dir|
        command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Write-Output ok"]
        result = runner.run(command, scratch_policy(dir))
        result.success?.should be_true, explain(result)
        result.stdout.should contain("ok"), explain(result)
      end
    end

    it "blocks network by default and allows it when granted" do
      pending!(pending_reason) unless runner.available?

      probe = "curl.exe -sS -k -o NUL -m 10 https://1.1.1.1"
      host = Process.run("cmd.exe", ["/d", "/c", probe])
      pending!("this host cannot reach https://1.1.1.1") unless host.success?

      with_scratch_dir do |dir|
        blocked = runner.run(["echo STAR^TED& #{probe}"], scratch_policy(dir), shell: true)
        blocked.stdout.should contain("STARTED"), explain(blocked)
        blocked.success?.should be_false, explain(blocked)

        allowed = scratch_policy(dir).merge(Cordon::Policy.build { |p| p.allow_network = true })
        result = runner.run([probe], allowed, shell: true)
        result.success?.should be_true, explain(result)
      end
    end
  end
end
