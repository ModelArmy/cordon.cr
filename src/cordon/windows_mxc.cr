require "base64"
require "json"
require "random/secure"

module Cordon
  {% if flag?(:win32) %}
    # :nodoc:
    @[Link("kernel32")]
    lib LibKernel32
      fun GetLongPathNameW(short_path : UInt16*, long_path : UInt16*, buffer_size : UInt32) : UInt32
    end
  {% end %}

  # Windows sandbox runner using Microsoft's MXC tool, wxc-exec.exe.
  #
  # wxc-exec launches the command inside a process security environment
  # (PSEC): Windows attaches the filesystem, network and UI policy to the
  # process itself, so host ACLs are never modified. MXC reports this tier as
  # "base-container". On hosts without PSEC, MXC would fall back to an
  # AppContainer plus temporary ACL grants; Cordon forbids that fallback, so
  # such hosts report unavailable instead.
  #
  # Requires Windows 11 with PSEC (25H2 build 26200, fully updated, or later)
  # and wxc-exec.exe, which `scripts/check-windows.ps1 -Install` installs.
  # See DEVELOPMENT.md, "Windows: the Mxc runner".
  #
  #   runner = Cordon::Mxc.new
  #   puts runner.build_config(["cmd.exe", "/c", "dir"], policy)
  class Mxc < Runner
    BINARY = "wxc-exec.exe"

    # MXC release Cordon is tested against. Names the versioned install
    # folders; keep in step with scripts/check-windows.ps1.
    MXC_VERSION = "0.8.0"

    # MXC config schema version emitted by #build_config.
    SCHEMA_VERSION = "0.6.0-alpha"

    # The only isolation tier Cordon accepts: PSEC, no ACL changes.
    REQUIRED_TIER = "base-container"

    # Environment variable naming wxc-exec.exe explicitly.
    WXC_EXEC_ENV = "CORDON_WXC_EXEC"

    # Architecture folder of the MXC package matching this build of Cordon.
    {% if flag?(:aarch64) %}
      ARCH = "arm64"
    {% else %}
      ARCH = "x64"
    {% end %}

    # Passed through from the parent environment; everything else is dropped,
    # as MXC uses a supplied environment verbatim. Add to policy.env for more.
    # PSModulePath lets PowerShell find its built-in cmdlets.
    DEFAULT_ENV_PASSTHROUGH = %w[PATH PATHEXT SystemRoot SystemDrive windir ComSpec TEMP TMP LOCALAPPDATA PSModulePath]

    # Variables Windows needs to start a process in a process security
    # environment; without them CreateProcessW fails with error 203
    # (ERROR_ENVVAR_NOT_FOUND). Mirrors MXC's REQUIRED_CHILD_ENV_VARS.
    REQUIRED_ENV = %w[SystemRoot LOCALAPPDATA]

    @tier : String? = nil

    @tier_probed = false

    # *wxc_exec* is an explicit path to wxc-exec.exe, tried before the
    # lookup order in #wxc_exec_candidates.
    def initialize(@wxc_exec : String? = nil)
    end

    def name : String
      "wxc-exec"
    end

    # Returns true when wxc-exec.exe is found and reports the PSEC tier.
    # Spawns `wxc-exec.exe --probe` on first call; the answer is cached.
    def available? : Bool
      tier == REQUIRED_TIER
    end

    # Returns the isolation tier `wxc-exec.exe --probe` reports, or nil when
    # wxc-exec.exe is missing or the probe fails. Cached after the first call.
    def tier : String?
      return @tier if @tier_probed
      @tier_probed = true
      @tier = probe_tier
    end

    # Returns the places wxc-exec.exe is looked for, first match winning:
    # the explicit path given to #initialize, CORDON_WXC_EXEC, the per-user
    # install folder, the all-users install folder, PATH, and a global npm
    # install of @microsoft/mxc-sdk.
    def wxc_exec_candidates : Array(String)
      candidates = [] of String
      @wxc_exec.try { |path| candidates << path }
      ENV[WXC_EXEC_ENV]?.try { |path| candidates << path unless path.empty? }
      ENV["LOCALAPPDATA"]?.try { |dir| candidates << install_path(dir) }
      ENV["ProgramFiles"]?.try { |dir| candidates << install_path(dir) }
      Process.find_executable(BINARY).try { |path| candidates << path }
      ENV["APPDATA"]?.try do |dir|
        candidates << Path.windows(dir, "npm", "node_modules", "@microsoft", "mxc-sdk", "bin", ARCH, BINARY).to_s
      end
      candidates.uniq
    end

    # Returns the first existing candidate from #wxc_exec_candidates, or nil.
    def wxc_exec_path : String?
      wxc_exec_candidates.find { |path| File.file?(path) }
    end

    def run(command : Array(String), policy : Policy, shell : Bool = false) : Result
      raise RunnerUnavailableError.new(unavailable_hint) unless available?
      check_required_env(policy)

      execute(build_argv(command, policy, shell))
    end

    # Windows cannot replace a running process image. Crystal's Process.exec
    # emulates it by starting the new process and exiting at once, so a
    # caller waiting on this process sees it finish early, without the
    # sandboxed command's output or exit code. Instead, this runs the
    # sandboxed command with this process's stdin, stdout and stderr, waits
    # for it, and exits with its exit code.
    def exec(command : Array(String), policy : Policy) : NoReturn
      raise RunnerUnavailableError.new(unavailable_hint) unless available?
      check_required_env(policy)

      argv = build_argv(command, policy)
      inherit = Process::Redirect::Inherit
      status = Process.run(argv[0], argv[1..], input: inherit, output: inherit, error: inherit)
      exit(status.normal_exit? ? status.exit_code : abnormal_exit_code(status))
    end

    # Returns the full argv that would be passed to the OS: wxc-exec.exe
    # followed by the #build_config JSON, base64-encoded.
    #
    # See Runner#run for *shell*'s contract.
    def build_argv(command : Array(String), policy : Policy, shell : Bool = false) : Array(String)
      config = build_config(command, policy, shell)
      [wxc_exec_path || BINARY, "--config-base64", Base64.strict_encode(config)]
    end

    # Returns the MXC config (JSON) that runs *command* under *policy*.
    # Useful for inspection, dry-run output, or logging.
    #
    # See Runner#run for *shell*'s contract; on Windows the script runs via
    # `cmd.exe /d /s /c`. Each call yields a fresh containerId, so concurrent
    # runs never share an identity. Raises PolicyError when *policy* sets
    # tmpfs_paths, which MXC cannot express, and ArgumentError when *shell*
    # is false and command[0] is a batch file (see #command_line).
    def build_config(command : Array(String), policy : Policy, shell : Bool = false) : String
      raise PolicyError.new(
        "tmpfs_paths is not supported on Windows: MXC has no in-memory mounts"
      ) unless policy.tmpfs_paths.empty?

      JSON.build("  ") do |json|
        json.object do
          json.field "version", SCHEMA_VERSION
          json.field "containerId", "cordon-#{Random::Secure.hex(8)}"
          json.field "containment", "processcontainer"
          json.field "process" do
            json.object do
              json.field "commandLine", command_line(command, shell)
              policy.working_dir.try { |dir| json.field "cwd", long_path(dir) }
              json.field "env", environment(policy)
            end
          end
          json.field "filesystem" do
            json.object do
              json.field "readonlyPaths", grant_paths(policy.read_only_paths)
              json.field "readwritePaths", grant_paths(policy.read_write_paths)
            end
          end
          json.field "network" do
            json.object do
              json.field "defaultPolicy", policy.allow_network? ? "allow" : "block"
              json.field "enforcementMode", "capabilities"
            end
          end
          # PowerShell fails to start without desktop access. Clipboard and
          # input injection stay at MXC's blocked defaults.
          json.field "ui" do
            json.object { json.field "disable", false }
          end
          json.field "fallback" do
            json.object { json.field "allowDaclMutation", false }
          end
        end
      end
    end

    # Joins *command* into one Windows command line, quoted so each element
    # reaches the target as a single argument.
    #
    # Refuses a batch file (.bat, .cmd) as command[0] unless *shell* is true:
    # Windows runs batch files through cmd.exe implicitly, and cmd.exe's
    # parsing defeats argument quoting, letting crafted arguments inject
    # commands ("BatBadBut"). Crystal's own Process refuses them for the same
    # reason. With *shell* true the caller writes the cmd.exe script and owns
    # its quoting.
    private def command_line(command : Array(String), shell : Bool) : String
      unless shell
        raise ArgumentError.new(
          "#{command[0]} is a batch file; its arguments cannot be quoted safely. " \
          "Run it with shell: true and quote the script yourself"
        ) if batch_file?(command[0])

        return Process.quote_windows(command)
      end

      raise ArgumentError.new(
        "shell: true expects a single command string in command[0]; " \
        "build the full script yourself, no positional-arg forwarding is supported"
      ) unless command.size == 1

      %(cmd.exe /d /s /c "#{command[0]}")
    end

    # Builds the KEY=VALUE list: DEFAULT_ENV_PASSTHROUGH from the parent,
    # then policy.env, then policy.unset_env removed. Names compare
    # case-insensitively, as Windows does.
    private def environment(policy : Policy) : Array(String)
      env = {} of String => String
      DEFAULT_ENV_PASSTHROUGH.each do |key|
        ENV[key]?.try { |value| env[key] = value }
      end
      policy.env.each do |key, value|
        delete_env_key(env, key)
        env[key] = value
      end
      policy.unset_env.each { |key| delete_env_key(env, key) }
      env.map { |key, value| "#{key}=#{value}" }
    end

    # Raises PolicyError when the environment #build_config would supply lacks
    # a REQUIRED_ENV variable, because policy.unset_env removed it or the
    # parent environment does not define it.
    private def check_required_env(policy : Policy) : Nil
      names = environment(policy).map(&.split('=', 2).first)
      missing = REQUIRED_ENV.reject do |required|
        names.any? { |name| name.compare(required, case_insensitive: true) == 0 }
      end
      return if missing.empty?

      raise PolicyError.new(
        "#{missing.join(", ")} must be set: Windows cannot start a sandboxed process without them"
      )
    end

    private def delete_env_key(env : Hash(String, String), key : String) : Nil
      env.reject! { |existing, _| existing.compare(key, case_insensitive: true) == 0 }
    end

    # Returns *paths* with each one's long form (see #long_path) added after
    # it when the two differ beyond letter case, so a grant matches however a
    # process spells the path. Both forms name the same directory: nothing
    # extra is granted.
    private def grant_paths(paths : Array(String)) : Array(String)
      paths.flat_map do |path|
        long = long_path(path)
        long.compare(path, case_insensitive: true) == 0 ? [path] : [path, long]
      end.uniq!
    end

    # Returns *path* with 8.3 short components expanded
    # (C:\Users\RUNNER~1\... becomes C:\Users\runneradmin\...), or unchanged
    # if it does not exist. Expanding a short component means listing its
    # parent directory, which the sandbox denies: a process whose working
    # directory is in short form fails as soon as .NET resolves it.
    # File.realpath does not expand short names, so this asks Windows via
    # GetLongPathNameW.
    #
    # On other hosts, reachable only through `cordon inspect --platform
    # windows`, *path* is returned verbatim.
    private def long_path(path : String) : String
      {% if flag?(:win32) %}
        short = path.to_utf16
        size = LibKernel32.GetLongPathNameW(short, Pointer(UInt16).null, 0)
        return path if size == 0

        buffer = Slice(UInt16).new(size)
        length = LibKernel32.GetLongPathNameW(short, buffer, size)
        return path if length == 0 || length >= size

        String.from_utf16(buffer[0, length])
      {% else %}
        path
      {% end %}
    end

    private def batch_file?(program : String) : Bool
      extension = File.extname(program.rstrip(". ")).downcase
      extension == ".bat" || extension == ".cmd"
    end

    private def install_path(base : String) : String
      Path.windows(base, "cordon", "mxc", MXC_VERSION, BINARY).to_s
    end

    # Runs `wxc-exec.exe --probe` and extracts the "tier" field from the JSON
    # it prints. Any leading non-JSON output is skipped.
    private def probe_tier : String?
      path = wxc_exec_path
      return unless path

      output = IO::Memory.new
      status = Process.run(path, ["--probe"], output: output, error: IO::Memory.new)
      return unless status.success?

      text = output.to_s
      start = text.index('{')
      return unless start

      JSON.parse(text[start..])["tier"]?.try(&.as_s?)
    rescue IO::Error | File::Error | JSON::ParseException
      nil
    end

    protected def unavailable_hint : String
      if wxc_exec_path.nil?
        "wxc-exec.exe not found. Install it with scripts/check-windows.ps1 -Install, " \
        "or set #{WXC_EXEC_ENV} to its path."
      else
        "wxc-exec.exe reports isolation tier #{tier.inspect}; Cordon requires " \
        "#{REQUIRED_TIER.inspect} (Windows 11 with the process security environment). " \
        "Install the latest Windows updates; Windows Server does not provide it yet."
      end
    end
  end
end
