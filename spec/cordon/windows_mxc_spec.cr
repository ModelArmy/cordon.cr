require "../spec_helper"

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
        p.read_only "C:\\tools"
        p.read_write "C:\\work"
      end
      filesystem = config_for(["cmd.exe"], policy)["filesystem"]
      filesystem["readonlyPaths"].as_a.map(&.as_s).should eq(["C:\\tools"])
      filesystem["readwritePaths"].as_a.map(&.as_s).should eq(["C:\\work"])
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
end
