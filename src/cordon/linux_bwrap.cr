module Cordon
  # Linux sandbox runner using Bubblewrap (bwrap).
  #
  # bwrap uses unprivileged Linux user namespaces — no root required.
  # Rather than evaluating path rules at access time (like SBPL on macOS),
  # it constructs a fresh mount namespace: an allowlist view assembled from
  # explicit bind mounts. Anything not bound simply does not exist inside.
  #
  # Requires bwrap >= 0.3.0. Available on all major distributions:
  #   apt install bubblewrap
  #   dnf install bubblewrap
  #   pacman -S bubblewrap
  #
  # Note: some hardened kernels disable unprivileged user namespaces
  # (kernel.unprivileged_userns_clone=0). Call available? before use.
  class Bwrap < Runner
    BINARY = "bwrap"

    # Passed through from the parent environment after --clearenv.
    # Everything else is stripped; add to policy.env for additional vars.
    DEFAULT_ENV_PASSTHROUGH = %w[PATH TERM LANG LC_ALL LANGUAGE TZ]

    # Bound read-only with --ro-bind-try (silently skipped if absent).
    # Covers dynamic linker paths across major Linux distributions.
    SYSTEM_RO_PATHS = %w[
      /usr/lib
      /usr/lib64
      /lib
      /lib64
      /usr/bin
      /usr/sbin
      /bin
      /sbin
      /usr/share/locale
      /usr/share/zoneinfo
    ]

    def available? : Bool
      !Process.find_executable(BINARY).nil?
    end

    def run(command : Array(String), policy : Policy) : Result
      raise RunnerUnavailableError.new(
        "#{BINARY} not found in PATH. Install bubblewrap and try again."
      ) unless available?

      execute(build_argv(command, policy))
    end

    def exec(command : Array(String), policy : Policy) : NoReturn
      raise RunnerUnavailableError.new(
        "#{BINARY} not found in PATH. Install bubblewrap and try again."
      ) unless available?

      replace_process(build_argv(command, policy))
    end

    # Returns the full argv that would be passed to the OS.
    # Useful for inspection, dry-run output, or logging.
    def build_argv(command : Array(String), policy : Policy) : Array(String)
      argv = [BINARY]

      # ── Environment ──────────────────────────────────────────────────
      # Start clean; pass through safe defaults, then policy overrides.
      argv << "--clearenv"

      DEFAULT_ENV_PASSTHROUGH.each do |key|
        if value = ENV[key]?
          argv.concat(["--setenv", key, value])
        end
      end

      policy.env.each do |key, value|
        argv.concat(["--setenv", key, value])
      end

      policy.unset_env.each do |key|
        argv.concat(["--unsetenv", key])
      end

      # ── Core mounts (needed by nearly all processes) ──────────────────
      argv.concat(["--proc", "/proc"])
      argv.concat(["--dev", "/dev"])

      # ── System library paths ──────────────────────────────────────────
      # --ro-bind-try: skip silently if path absent on this distro.
      SYSTEM_RO_PATHS.each do |path|
        argv.concat(["--ro-bind-try", path, path])
      end

      # ── Policy: read-only paths ───────────────────────────────────────
      policy.read_only_paths.each do |path|
        argv.concat(["--ro-bind", path, path])
      end

      # ── Policy: read-write paths ──────────────────────────────────────
      policy.read_write_paths.each do |path|
        argv.concat(["--bind", path, path])
      end

      # ── Policy: tmpfs scratch mounts ──────────────────────────────────
      # In-memory, not persisted, not visible from the host.
      policy.tmpfs_paths.each do |path|
        argv.concat(["--tmpfs", path])
      end

      # ── Network namespace ─────────────────────────────────────────────
      # --unshare-net creates a fresh network namespace with no NICs.
      # Only loopback exists inside; no host network is reachable.
      if policy.allow_network?
        argv.concat(["--ro-bind-try", "/etc/resolv.conf", "/etc/resolv.conf"])
        argv.concat(["--ro-bind-try", "/etc/ssl", "/etc/ssl"])
        argv.concat(["--ro-bind-try", "/etc/ca-certificates", "/etc/ca-certificates"])
      else
        argv << "--unshare-net"
      end

      # ── Process isolation ─────────────────────────────────────────────
      # New PID namespace: sandboxed process sees itself as PID 1;
      # host process tree is not visible.
      argv << "--unshare-pid"

      # New session: detach from controlling terminal (prevents TTY escapes).
      argv << "--new-session" if policy.new_session?

      # ── Working directory ─────────────────────────────────────────────
      if wd = policy.working_dir
        argv.concat(["--chdir", wd])
      end

      argv << "--"
      argv.concat(command)

      argv
    end
  end
end
