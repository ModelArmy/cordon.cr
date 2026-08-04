require "./cordon"

require "option_parser"

# sandbox_cli.cr — command-line interface for the cordon shard.
#
# Build:   shards build
# Binary:  ./bin/cordon
#
# Usage:
#   cordon run     --policy policy.json -- command [args...]
#   cordon inspect --policy policy.json [--platform linux|macos]
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

      # Apply presets.
      preset_names.each do |name|
        unless KNOWN_PRESETS.includes?(name)
          STDERR.puts "cordon run: unknown preset #{name.inspect}. Known presets: #{KNOWN_PRESETS.join(", ")}."
          return 1
        end
        preset = resolve_preset(name)
        if preset.nil?
          STDERR.puts "cordon run: preset #{name.inspect} is not supported on this platform."
          return 1
        end
        policy = policy.merge(preset)
      end

      # Apply Ruby executable preset.
      if path = ruby_path
        unless File.exists?(path)
          STDERR.puts "cordon run: --ruby path not found: #{path.inspect}"
          return 1
        end
        policy = policy.merge(Preset::Ruby.for_executable(path))
      end

      # Apply Python executable preset.
      if path = python_path
        unless File.exists?(path)
          STDERR.puts "cordon run: --python path not found: #{path.inspect}"
          return 1
        end
        policy = policy.merge(Preset::Python.for_executable(path))
      end

      # Apply Python venv preset.
      if path = venv_path
        unless Dir.exists?(path)
          STDERR.puts "cordon run: --python-venv path not found: #{path.inspect}"
          return 1
        end
        begin
          policy = policy.merge(Preset::Python.for_venv(path))
        rescue ex : File::Error | KeyError
          STDERR.puts "cordon run: --python-venv #{path.inspect} is not a valid virtualenv: #{ex.message}"
          return 1
        end
      end

      # Apply CLI overrides on top of the policy file.
      if override = allow_network_override
        policy.allow_network = override
      end

      begin
        runner = Cordon.runner
        result = runner.run(command, policy)
        STDOUT.puts
        STDOUT.print result.stdout
        STDERR.print result.stderr
        result.exit_code
      rescue ex : RunnerUnavailableError
        STDERR.puts "cordon: #{ex.message}"
        1
      end
    end

    # ── cordon inspect ───────────────────────────────────────────────────────
    # Prints the native invocation (bwrap argv or SBPL profile) that would be
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

      OptionParser.parse(argv) do |opts|
        opts.banner = "Usage: cordon inspect [options]"

        opts.on("-p FILE", "--policy FILE", "Path to JSON policy file") do |file|
          policy_path = file
        end

        opts.on("--platform PLATFORM", "Platform to inspect for: linux, macos") do |name|
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

      # Apply presets.
      preset_names.each do |name|
        unless KNOWN_PRESETS.includes?(name)
          STDERR.puts "cordon inspect: unknown preset #{name.inspect}. Known presets: #{KNOWN_PRESETS.join(", ")}."
          return 1
        end
        preset = resolve_preset(name)
        if preset.nil?
          STDERR.puts "cordon inspect: preset #{name.inspect} is not supported on this platform."
          return 1
        end
        policy = policy.merge(preset)
      end

      # Apply Ruby executable preset.
      if path = ruby_path
        unless File.exists?(path)
          STDERR.puts "cordon inspect: --ruby path not found: #{path.inspect}"
          return 1
        end
        policy = policy.merge(Preset::Ruby.for_executable(path))
      end

      # Apply Python executable preset.
      if path = python_path
        unless File.exists?(path)
          STDERR.puts "cordon inspect: --python path not found: #{path.inspect}"
          return 1
        end
        policy = policy.merge(Preset::Python.for_executable(path))
      end

      # Apply Python venv preset.
      if path = venv_path
        unless Dir.exists?(path)
          STDERR.puts "cordon inspect: --python-venv path not found: #{path.inspect}"
          return 1
        end
        begin
          policy = policy.merge(Preset::Python.for_venv(path))
        rescue ex : File::Error | KeyError
          STDERR.puts "cordon inspect: --python-venv #{path.inspect} is not a valid virtualenv: #{ex.message}"
          return 1
        end
      end

      # Dummy command for display; inspect shows structure, not a real execution.
      placeholder = ["<command>", "<args...>"]

      case platform
      when "linux"
        runner = Bwrap.new
        STDERR.puts "Note: bwrap is not available on this host — output is for reference only." unless runner.available?
        puts "# bwrap invocation:"
        puts runner.build_argv(placeholder, policy).join(" \\\n  ")
      when "macos"
        runner = SandboxExec.new
        STDERR.puts "Note: sandbox-exec is not available on this host — output is for reference only." unless runner.available?
        puts "# SBPL profile (sandbox-exec -f <profile> -- #{placeholder.join(" ")}):"
        puts runner.generate_profile(policy)
      else
        STDERR.puts "cordon inspect: unknown platform #{platform.inspect}. Use 'linux' or 'macos'."
        return 1
      end

      0
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
        0
      else
        STDERR.puts "No runners available. Install bwrap (Linux) or use macOS with sandbox-exec."
        1
      end
    end

    # ── Helpers ───────────────────────────────────────────────────────────────

    # All available preset names, used for --add validation and error messages.
    KNOWN_PRESETS = %w[brew system]

    # Maps a preset name to the appropriate Policy for the current platform.
    # Returns nil for unknown preset names; returns nil (with a warning) for
    # presets not supported on the current platform.
    private def self.resolve_preset(name : String) : Policy?
      case name
      when "brew"   then preset_brew
      when "system" then preset_system
      else               nil
      end
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
          return nil
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
          check    Report which cordon runners are available
          help     Show this help
          version  Print version

        Examples:
          cordon run --policy policy.json -- python3 script.py
          cordon run --policy policy.json --allow-network -- curl https://example.com
          cordon run --policy policy.json --add brew -- brew list
          cordon run --ruby $(which ruby) -- ruby script.rb
          cordon run --ruby $(rbenv which ruby) -- ruby script.rb
          cordon run --python $(which python3) -- python3 script.py
          cordon run --python-venv .venv -- python3 script.py
          cordon inspect --policy policy.json
          cordon inspect --policy policy.json --platform macos
          cordon inspect --ruby $(which ruby) --platform macos
          cordon inspect --python-venv .venv --platform macos
          cordon check

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

{% unless flag?(:test) %}
  exit Cordon::CLI.run(ARGV)
{% end %}
