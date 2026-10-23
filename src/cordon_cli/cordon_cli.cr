require "../cordon"

require "option_parser"
require "json"

# sandbox_cli.cr — command-line interface for the cordon shard.
#
# Build:   shards build
# Binary:  ./bin/cordon
#
# Usage:
#   cordon run     --policy policy.json -- command [args...]
#   cordon inspect --policy policy.json [--platform linux|macos|windows]
#   cordon check
#   cordon help

module Cordon
  module CLI
    VERSION_BANNER = "cordon #{Cordon::VERSION} — platform-agnostic sandbox runner"

    def self.run(argv : Array(String)) : Int32
      return help(status: 0) if argv.empty?

      subcommand = argv.shift

      case subcommand
      when "run"                  then cmd_run(argv)
      when "inspect"              then cmd_inspect(argv)
      when "check"                then cmd_check(argv)
      when "confirm"              then cmd_confirm(argv)
      when "help", "--help", "-h" then help(status: 0)
      when "version", "--version" then puts VERSION_BANNER; 0
      else
        STDERR.puts "Unknown subcommand: #{subcommand.inspect}"
        STDERR.puts "Run 'cordon help' for usage."
        1
      end
    end

    # ── cordon run ──────────────────────────────────────────────────────────
    # Loads a policy file and executes a command inside the cordon.
    #
    #   cordon run --policy policy.json -- python3 script.py
    #   cordon run --policy policy.json --allow-network -- curl https://example.com
    #   cordon run --policy policy.json --add brew -- brew list

    private def self.cmd_run(argv : Array(String)) : Int32
      policy_path = nil
      allow_network_override = nil
      preset_names = [] of String
      ruby_path = nil
      python_path = nil
      venv_path = nil
      crystal_cache = nil
      shards_cache = nil
      env_flags = [] of EnvFlag
      invalid_env = [] of String

      # Split argv on "--" to separate cordon flags from the command.
      sep = argv.index("--")
      unless sep
        STDERR.puts "cordon run: missing '--' separator before command."
        STDERR.puts "Usage: cordon run --policy policy.json -- command [args...]"
        return 1
      end

      sandbox_args = argv[0, sep]
      command = argv[(sep + 1)..]

      if command.empty?
        STDERR.puts "cordon run: no command given after '--'."
        return 1
      end

      OptionParser.parse(sandbox_args) do |opts|
        opts.banner = "Usage: cordon run [options] -- command [args...]"

        opts.on("-p FILE", "--policy FILE", "Path to JSON policy file") do |file|
          policy_path = file
        end

        opts.on("--allow-network", "Override policy: permit network access") do
          allow_network_override = true
        end

        opts.on("--no-network", "Override policy: deny network access") do
          allow_network_override = false
        end

        opts.on("--add PRESET", "Merge a named preset into the policy (e.g. brew)") do |name|
          preset_names << name
        end

        opts.on("--ruby PATH", "Merge a Ruby preset derived from the given binary path") do |path|
          ruby_path = path
        end

        opts.on("--python PATH", "Merge a Python preset derived from the given binary path") do |path|
          python_path = path
        end

        opts.on("--python-venv PATH", "Merge a Python preset derived from the given virtualenv directory") do |path|
          venv_path = path
        end

        opts.on("--crystal-cache DIR", "Merge the Crystal preset, with DIR as the compiler cache ('shared': your own builds' cache)") do |dir|
          crystal_cache = dir
        end

        opts.on("--shards-cache DIR", "With --crystal-cache, DIR as the shards cache ('shared': your own shards' cache)") do |dir|
          shards_cache = dir
        end

        add_env_options(opts, env_flags, invalid_env)

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end

        opts.invalid_option do |flag|
          STDERR.puts "cordon run: unknown option #{flag.inspect}"
          STDERR.puts opts
          exit 1
        end
      end

      policy = load_policy(policy_path)
      return 1 if policy.nil?

      return report_invalid_env("cordon run", invalid_env) unless invalid_env.empty?

      presets = apply_presets(presets_base, "cordon run", preset_names, ruby_path, python_path, venv_path)
      return 1 if presets.nil?

      with_crystal_preset("cordon run", crystal_cache, shards_cache) do |crystal|
        all_presets = crystal ? presets.merge(crystal) : presets
        warn_env_overrides("cordon run", all_presets, env_flags)
        merged = policy.merge(all_presets)

        # Apply CLI overrides on top of the policy file and presets.
        if override = allow_network_override
          merged.allow_network = override
        end
        merged = apply_env_flags(merged, env_flags)

        begin
          runner = Cordon.runner
          result = runner.run(command, merged)
          STDOUT.puts
          STDOUT.print result.stdout
          STDERR.print result.stderr
          result.exit_code
        rescue ex : RunnerUnavailableError | PolicyError | ArgumentError
          STDERR.puts "cordon: #{ex.message}"
          1
        end
      end
    end

    # ── cordon inspect ───────────────────────────────────────────────────────
    # Prints the native invocation (bwrap argv, SBPL profile or MXC config) that would be
    # used for a given policy, without executing anything.
    #
    #   cordon inspect --policy policy.json
    #   cordon inspect --policy policy.json --platform macos
    #   cordon inspect --policy policy.json --add brew --platform macos

    private def self.cmd_inspect(argv : Array(String)) : Int32
      policy_path = nil
      platform = detect_platform
      preset_names = [] of String
      ruby_path = nil
      python_path = nil
      venv_path = nil
      crystal_cache = nil
      shards_cache = nil
      env_flags = [] of EnvFlag
      invalid_env = [] of String

      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: cordon inspect [options]"

        opts.on("-p FILE", "--policy FILE", "Path to JSON policy file") do |file|
          policy_path = file
        end

        opts.on("--platform PLATFORM", "Platform to inspect for: linux, macos, windows") do |name|
          platform = name
        end

        opts.on("--add PRESET", "Merge a named preset into the policy (e.g. brew)") do |name|
          preset_names << name
        end

        opts.on("--ruby PATH", "Merge a Ruby preset derived from the given binary path") do |path|
          ruby_path = path
        end

        opts.on("--python PATH", "Merge a Python preset derived from the given binary path") do |path|
          python_path = path
        end

        opts.on("--python-venv PATH", "Merge a Python preset derived from the given virtualenv directory") do |path|
          venv_path = path
        end

        opts.on("--crystal-cache DIR", "Merge the Crystal preset, with DIR as the compiler cache ('shared': your own builds' cache)") do |dir|
          crystal_cache = dir
        end

        opts.on("--shards-cache DIR", "With --crystal-cache, DIR as the shards cache ('shared': your own shards' cache)") do |dir|
          shards_cache = dir
        end

        add_env_options(opts, env_flags, invalid_env)

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end

        opts.invalid_option do |flag|
          STDERR.puts "cordon inspect: unknown option #{flag.inspect}"
          exit 1
        end
      end

      policy = load_policy(policy_path)
      return 1 if policy.nil?

      return report_invalid_env("cordon inspect", invalid_env) unless invalid_env.empty?

      presets = apply_presets(presets_base, "cordon inspect", preset_names, ruby_path, python_path, venv_path)
      return 1 if presets.nil?

      with_crystal_preset("cordon inspect", crystal_cache, shards_cache) do |crystal|
        all_presets = crystal ? presets.merge(crystal) : presets
        warn_env_overrides("cordon inspect", all_presets, env_flags)
        effective = apply_env_flags(policy.merge(all_presets), env_flags)

        # Dummy command for display; inspect shows structure, not a real execution.
        placeholder = ["<command>", "<args...>"]

        case platform
        when "linux"
          runner = Bwrap.new
          STDERR.puts "Note: bwrap is not available on this host — output is for reference only." unless runner.available?
          puts "# bwrap invocation:"
          puts runner.build_argv(placeholder, effective).join(" \\\n  ")
        when "macos"
          runner = SandboxExec.new
          STDERR.puts "Note: sandbox-exec is not available on this host — output is for reference only." unless runner.available?
          puts "; SBPL profile (sandbox-exec -f <profile> -- #{placeholder.join(" ")}):"
          puts runner.generate_profile(effective)
        when "windows"
          runner = Mxc.new
          STDERR.puts "Note: wxc-exec.exe is not available on this host — output is for reference only." unless runner.available?
          begin
            config = runner.build_config(placeholder, effective)
          rescue ex : PolicyError
            STDERR.puts "cordon inspect: #{ex.message}"
            return 1
          end
          puts "// MXC config (wxc-exec.exe --config-base64 <this JSON, base64-encoded>):"
          puts config
        else
          STDERR.puts "cordon inspect: unknown platform #{platform.inspect}. Use 'linux', 'macos' or 'windows'."
          return 1
        end

        0
      end
    end

    # ── cordon check ─────────────────────────────────────────────────────────
    # Probes the current environment and reports which runners are available.
    #
    #   cordon check

    private def self.cmd_check(argv : Array(String)) : Int32
      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: cordon check"
        opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
      end

      puts VERSION_BANNER
      puts "Platform: #{detect_platform}"
      puts

      runners = [
        {Bwrap.new, "bwrap", "Linux (bubblewrap user namespaces)"},
        {SandboxExec.new, "sandbox-exec", "macOS (Seatbelt / SBPL)"},
        {Mxc.new, "wxc-exec", "Windows 11 (MXC process security environment)"},
      ]

      ok = false
      runners.each do |(runner, name, description)|
        if runner.available?
          puts "  ✓ #{name.ljust(16)} #{description}"
          ok = true
        else
          puts "  ✗ #{name.ljust(16)} #{description} — not found"
        end
      end

      puts
      if ok
        puts "At least one runner is available. 'cordon run' will work on this host."
        puts "This only checks that the binary is present — run 'cordon confirm' " \
             "to verify it actually enforces isolation."
        0
      else
        STDERR.puts "No runners available. Install bwrap (Linux), use macOS with sandbox-exec, " \
                    "or install MXC on Windows 11 (scripts/check-windows.ps1 -Install)."
        1
      end
    end

    # ── cordon confirm ───────────────────────────────────────────────────────
    # Probes the current environment to confirm the sandbox actually
    # enforces isolation, not just that the binary is present (see `check`).
    #
    #   cordon confirm
    #   cordon confirm --json

    private def self.cmd_confirm(argv : Array(String)) : Int32
      json = false

      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: cordon confirm [options]"
        opts.on("--json", "Print the report as JSON instead of text") { json = true }
        opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
        opts.invalid_option do |flag|
          STDERR.puts "cordon confirm: unknown option #{flag.inspect}"
          exit 1
        end
      end

      begin
        report = Cordon.confirm
      rescue ex : RunnerUnavailableError
        STDERR.puts "cordon: #{ex.message}"
        return 1
      end

      if json
        puts confirm_report_to_json(report)
      else
        puts report
      end

      report.ok? ? 0 : 1
    end

    private def self.confirm_report_to_json(report : ConfirmReport) : String
      String.build do |str|
        JSON.build(str) do |json|
          json.object do
            json.field "runner", report.runner_name
            json.field "ok", report.ok?
            json.field "hint", report.hint
            json.field "probes" do
              json.array do
                report.probes.each do |probe|
                  json.object do
                    json.field "name", probe.name
                    json.field "description", probe.description
                    json.field "status", probe.skipped? ? "skip" : (probe.passed? ? "pass" : "fail")
                    json.field "skip_reason", probe.skip_reason
                    json.field "exit_code", probe.exit_code
                    json.field "stdout", probe.stdout
                    json.field "stderr", probe.stderr
                  end
                end
              end
            end
          end
        end
      end
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    # One --env or --unset-env flag: a variable name, and the value to set,
    # or nil to remove the variable.
    alias EnvFlag = {String, String?}

    # Applies --env and --unset-env flags to *policy* in command-line order
    # and returns it, so that a later flag overrides an earlier one and both
    # override the policy file and presets. --env also takes the name out
    # of unset_env, and --unset-env takes it out of env.
    #
    #   policy = Cordon::Policy.build { |p| p.unset_env << "TZ" }
    #   Cordon::CLI.apply_env_flags(policy, [{"TZ", "UTC"}]).env # => {"TZ" => "UTC"}
    def self.apply_env_flags(policy : Policy, flags : Array(EnvFlag)) : Policy
      flags.each do |key, value|
        if value
          policy.env[key] = value
          policy.unset_env.delete(key)
        else
          policy.env.delete(key)
          policy.unset_env << key unless policy.unset_env.includes?(key)
        end
      end
      policy
    end

    # Adds --env and --unset-env to *opts*, collecting valid flags in
    # *flags* and malformed arguments in *invalid*.
    private def self.add_env_options(opts : OptionParser, flags : Array(EnvFlag), invalid : Array(String)) : Nil
      opts.on("--env KEY=VALUE", "Set a variable inside the sandbox, overriding the policy (repeatable)") do |arg|
        key, separator, value = arg.partition('=')
        if key.empty? || separator.empty?
          invalid << "--env #{arg}"
        else
          flags << {key, value}
        end
      end

      opts.on("--unset-env KEY", "Remove a variable inside the sandbox, passthrough ones included (repeatable)") do |key|
        if key.empty? || key.includes?('=')
          invalid << "--unset-env #{key}"
        else
          flags << {key, nil}
        end
      end
    end

    # Returns the names among *flags* that override or remove a variable
    # *presets* set. Such a flag moves the variable but not the preset's
    # grants, which stay, while the new value gets none.
    #
    #   presets = Cordon::Policy.build { |p| p.env["TMPDIR"] = "/tmp/x" }
    #   Cordon::CLI.env_overrides(presets, [{"TMPDIR", "/tmp/y"}, {"TZ", nil}]) # => ["TMPDIR"]
    def self.env_overrides(presets : Policy, flags : Array(EnvFlag)) : Array(String)
      flags.map(&.first).uniq!.select { |key| presets.env.has_key?(key) }
    end

    private def self.warn_env_overrides(cmd : String, presets : Policy, flags : Array(EnvFlag)) : Nil
      env_overrides(presets, flags).each do |key|
        STDERR.puts "#{cmd}: warning: #{key} was set by a preset, which granted access for its value. " \
                    "Overriding it keeps that grant and grants nothing for the new value."
      end
    end

    # Yields the Crystal preset for *cache* and *shards_cache* inside a
    # fresh temp directory deleted afterwards, or nil when neither is
    # given, and returns the block's value. Each is a directory, or "shared"
    # for the one the tool uses outside the sandbox; a nil *shards_cache*
    # uses the preset's default. Returns 1 without yielding if the preset
    # can't be built, having reported why on STDERR.
    private def self.with_crystal_preset(cmd : String, cache : String?, shards_cache : String?, & : Policy? -> Int32) : Int32
      unless cache
        return yield nil unless shards_cache
        STDERR.puts "#{cmd}: --shards-cache needs --crystal-cache."
        return 1
      end

      cache_dir = resolve_cache_dir(cmd, "--crystal-cache", cache) { Preset::Crystal.shared_cache_dir }
      return 1 unless cache_dir
      if shards_cache
        shards_cache_dir = resolve_cache_dir(cmd, "--shards-cache", shards_cache) { Preset::Crystal.shared_shards_cache_dir }
        return 1 unless shards_cache_dir
      end

      yielded = false
      begin
        Preset::Crystal.with_temp_dir(cache_dir: cache_dir, shards_cache_dir: shards_cache_dir) do |preset|
          yielded = true
          yield preset
        end
      rescue ex : PolicyError | UnsupportedPlatformError | File::Error
        raise ex if yielded
        STDERR.puts "#{cmd}: --crystal-cache: #{ex.message}"
        1
      end
    end

    # Returns *value*, or the block's directory when *value* is "shared".
    # Returns nil if the block raises PolicyError, having reported it.
    private def self.resolve_cache_dir(cmd : String, flag : String, value : String, & : -> String) : String?
      return value unless value == "shared"
      yield
    rescue ex : PolicyError
      STDERR.puts "#{cmd}: #{flag}: #{ex.message}"
    end

    # The policy presets are merged onto before the result is merged onto
    # the policy file. It sets nothing, so merging it changes nothing.
    private def self.presets_base : Policy
      base = Policy.new
      base.new_session = false
      base
    end

    # Reports malformed --env and --unset-env arguments; returns 1.
    private def self.report_invalid_env(cmd : String, invalid : Array(String)) : Int32
      invalid.each do |flag|
        STDERR.puts "#{cmd}: invalid #{flag.inspect}; use --env KEY=VALUE or --unset-env KEY."
      end
      1
    end

    # All available preset names, used for --add validation and error messages.
    KNOWN_PRESETS = %w[brew system]

    # Maps a preset name to the appropriate Policy for the current platform.
    # Returns nil for unknown preset names; returns nil (with a warning) for
    # presets not supported on the current platform.
    private def self.resolve_preset(name : String) : Policy?
      case name
      when "brew"   then preset_brew
      when "system" then preset_system
      end
    end

    # Merges every preset selected on the command line into *policy* and
    # returns the result. Returns nil if any selection was invalid, having
    # already reported the reason on STDERR; callers should exit non-zero.
    # *cmd* is the subcommand name, used only to prefix error messages.
    private def self.apply_presets(policy : Policy, cmd : String,
                                   preset_names : Array(String),
                                   ruby_path : String?,
                                   python_path : String?,
                                   venv_path : String?) : Policy?
      merged = apply_named_presets(policy, cmd, preset_names)
      return if merged.nil?

      apply_toolchain_presets(merged, cmd, ruby_path, python_path, venv_path)
    end

    # Merges the presets named by --add. Returns nil on an unknown name or
    # one unsupported on the current platform.
    private def self.apply_named_presets(policy : Policy, cmd : String,
                                         names : Array(String)) : Policy?
      names.each do |name|
        unless KNOWN_PRESETS.includes?(name)
          STDERR.puts "#{cmd}: unknown preset #{name.inspect}. Known presets: #{KNOWN_PRESETS.join(", ")}."
          return
        end

        preset = resolve_preset(name)
        if preset.nil?
          STDERR.puts "#{cmd}: preset #{name.inspect} is not supported on this platform."
          return
        end

        policy = policy.merge(preset)
      end
      policy
    end

    # Merges the presets derived from --ruby, --python and --python-venv.
    # Returns nil if a given path is missing or is not a valid virtualenv.
    private def self.apply_toolchain_presets(policy : Policy, cmd : String,
                                             ruby_path : String?,
                                             python_path : String?,
                                             venv_path : String?) : Policy?
      if path = ruby_path
        return unless check_path(cmd, "--ruby", path, &->File.exists?(String))
        policy = policy.merge(Preset::Ruby.for_executable(path))
      end

      if path = python_path
        return unless check_path(cmd, "--python", path, &->File.exists?(String))
        policy = policy.merge(Preset::Python.for_executable(path))
      end

      if path = venv_path
        return unless check_path(cmd, "--python-venv", path, &->Dir.exists?(String))
        begin
          policy = policy.merge(Preset::Python.for_venv(path))
        rescue ex : File::Error | KeyError
          STDERR.puts "#{cmd}: --python-venv #{path.inspect} is not a valid virtualenv: #{ex.message}"
          return
        end
      end

      policy
    end

    # Reports a missing path for *flag* on STDERR and returns false;
    # returns true when the given existence predicate accepts *path*.
    private def self.check_path(cmd : String, flag : String, path : String, &exists : String -> Bool) : Bool
      return true if exists.call(path)

      STDERR.puts "#{cmd}: #{flag} path not found: #{path.inspect}"
      false
    end

    private def self.preset_brew : Policy?
      Preset::Brew.for_current_platform
    rescue UnsupportedPlatformError
      nil
    end

    private def self.preset_system : Policy?
      Preset::System.for_current_platform
    rescue UnsupportedPlatformError
      nil
    end

    private def self.load_policy(path : String?) : Policy?
      if path
        unless File.exists?(path)
          STDERR.puts "cordon: policy file not found: #{path.inspect}"
          return
        end
        begin
          Policy.from_json(File.read(path))
        rescue ex : JSON::ParseException
          STDERR.puts "cordon: invalid policy JSON in #{path.inspect}: #{ex.message}"
          nil
        end
      else
        # No policy file: use a safe default (deny-all, no network).
        STDERR.puts "cordon: no --policy file given; using empty (deny-all) policy."
        Policy.new
      end
    end

    private def self.detect_platform : String
      {% if flag?(:linux) %}
        "linux"
      {% elsif flag?(:darwin) %}
        "macos"
      {% elsif flag?(:win32) %}
        "windows"
      {% else %}
        "unknown"
      {% end %}
    end

    private def self.help(status : Int32) : Int32
      puts <<-HELP
        #{VERSION_BANNER}

        Subcommands:
          run      Execute a command inside a cordon
          inspect  Print the native invocation without executing
          check    Report which cordon runners are available (presence only)
          confirm  Probe the runner to confirm it actually enforces isolation
          help     Show this help
          version  Print version

        Examples:
          cordon run --policy policy.json -- python3 script.py
          cordon run --policy policy.json --allow-network -- curl https://example.com
          cordon run --policy policy.json --add brew -- brew list
          cordon run --policy policy.json --env PATH="/opt/tools/bin:$PATH" -- make
          cordon run --policy policy.json --unset-env TZ -- date
          cordon run --ruby $(which ruby) -- ruby script.rb
          cordon run --ruby $(rbenv which ruby) -- ruby script.rb
          cordon run --python $(which python3) -- python3 script.py
          cordon run --python-venv .venv -- python3 script.py
          cordon run --add brew --add system --crystal-cache ~/.cache/cordon/crystal -- crystal spec
          cordon run --add brew --add system --crystal-cache shared -- crystal spec
          cordon run --add brew --add system --crystal-cache shared --shards-cache ~/.cache/cordon/shards --allow-network -- shards install
          cordon inspect --policy policy.json
          cordon inspect --policy policy.json --platform macos
          cordon inspect --ruby $(which ruby) --platform macos
          cordon inspect --python-venv .venv --platform macos
          cordon inspect --policy policy.json --platform windows
          cordon check
          cordon confirm
          cordon confirm --json

        Policy file (JSON):
          {
            "read_only_paths":  ["/usr/share/myapp"],
            "read_write_paths": ["/tmp/workspace"],
            "tmpfs_paths":      ["/tmp"],
            "allow_network":    false,
            "working_dir":      "/tmp/workspace",
            "env":              { "APP_ENV": "cordon" }
          }

        All policy keys are optional; omitted keys use safe defaults.
        HELP
      status
    end
  end
end
