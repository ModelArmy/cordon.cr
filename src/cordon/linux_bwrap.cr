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
    # Covers dynamic linker and shared-library paths across major Linux
    # distributions — needed for any dynamically-linked binary to start at
    # all, since the kernel loads the ELF interpreter (ld-linux.so) as part
    # of the same execve(2) that launches the target command.
    #
    # Binary directories (/usr/bin, /bin, /usr/sbin, /sbin) are
    # DELIBERATELY NOT included here. bwrap's mount namespace has no
    # concept of "exec permission" separate from "visible" — unlike SBPL
    # on macOS, which can grant file-read* without process-exec, a bind
    # mount makes a path both readable AND exec-able simultaneously. A
    # policy with no explicit grants would still be able to exec
    # /usr/bin/ruby, /usr/bin/python3, or anything else living in these
    # directories, if they were unconditionally mounted — the exact same
    # class of bypass fixed on the macOS side (see SandboxExec::BASELINE's
    # comment). If your command needs to shell out (e.g. via
    # system()/popen(), or a script with a #!/bin/sh line), merge in
    # Preset::System, which mounts these directories explicitly.
    SYSTEM_RO_PATHS = %w[
      /usr/lib
      /usr/lib64
      /lib
      /lib64
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

      # ── Target command's own binary ───────────────────────────────────
      # See SYSTEM_RO_PATHS' comment: bwrap has no exec permission distinct
      # from "mounted", so unlike the always-on system library paths above,
      # binary directories are not mounted by default. If the target
      # command isn't already covered by a mount already added above
      # (system or policy), bind-mount it explicitly — otherwise the
      # common case (run one binary, otherwise-empty policy) would need
      # the caller to separately grant read access to wherever their own
      # command happens to live.
      #
      # Both the literal path and its resolved real path (if it's a
      # symlink) are bound: the literal path is what bwrap execve's after
      # entering the namespace, so it must exist there; if it's a symlink,
      # the kernel also needs the resolved target reachable to follow it.
      # Mirrors the two-path symlink handling SandboxExec needs for SBPL.
      if literal = locate_command(command)
        already_mounted = SYSTEM_RO_PATHS + policy.read_only_paths +
                          policy.read_write_paths + policy.tmpfs_paths
        real = begin
          File.realpath(literal)
        rescue File::Error
          nil
        end

        {literal, real}.each do |path|
          next unless path
          next if already_mounted.any? { |granted| covers?(granted, path) }
          argv.concat(["--ro-bind", path, path])
          already_mounted << path
        end
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
