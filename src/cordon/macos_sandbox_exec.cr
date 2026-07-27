module Cordon
  # macOS sandbox runner using sandbox-exec and SBPL profiles.
  #
  # sandbox-exec wraps a process in Apple's Seatbelt framework (a MACF kernel
  # module). It evaluates a declarative SBPL (Sandbox Profile Language) policy
  # against every syscall the process makes; violations return EPERM.
  #
  # SBPL is a Scheme-like DSL. This runner generates a deny-default profile
  # and adds explicit allow rules derived from the policy.
  #
  # Deprecation note: sandbox-exec has been marked deprecated in macOS headers
  # since 10.8 but remains functional through current releases. No public
  # replacement exists for the ad-hoc CLI use case (App Sandbox requires code
  # signing and an app bundle). Used in production by Chromium and Firefox.
  #
  # The BASELINE constant contains the minimum permissions any process needs
  # to start under deny-default. Omitting any of these typically causes an
  # immediate crash or silent hang (dyld, Mach IPC, and sysctl are all gated).
  class SandboxExec < Runner
    BINARY = "sandbox-exec"

    BASELINE = <<-SBPL
      ; --- process lifecycle ---
      (allow process-fork)
      (allow process-exec)
      (allow process-exec-interpreter)

      ; --- mach IPC: required by dyld and most system frameworks ---
      (allow mach-lookup)
      (allow mach-register)

      ; --- sysctl: read by libc on startup ---
      (allow sysctl-read)

      ; --- dyld, system frameworks, and basic device nodes ---
      ; /private/var/db/dyld             = Intel dyld shared cache
      ; /System/Volumes/Preboot/Cryptexes = Apple Silicon dyld shared cache (arm64)
      (allow file-read*
        (subpath "/usr/lib")
        (subpath "/usr/share")
        (subpath "/System/Library")
        (subpath "/System/Volumes/Preboot/Cryptexes")
        (subpath "/private/var/db/dyld")
        (literal "/dev/random")
        (literal "/dev/urandom"))

      ; --- common to write to `/dev/null` ---
      (allow file-read* file-write*
        (literal "/dev/null"))

      ; --- stat/readdir: needed broadly ---
      (allow file-read-metadata)

      ; --- root filesystem: required for path resolution ---
      ; ! Note that file-read-data (literal "/") grants read on the
      ;   root directory node only — not its contents. That's distinct
      ;   from (subpath "/") which would be a blanket allow on the
      ;   entire filesystem.
      (allow file-read-data (literal "/"))

      ; --- Darwin/CoreFoundation plumbing ---
      ; Hit by nearly any CF- or Foundation-linked process, not just one
      ; toolchain. Harmless if denied (caller falls back), but noisy.
      (allow ipc-posix-shm-read-data (literal "apple.shm.notification_center"))
      (allow file-read-data (literal "/Library/Preferences/Logging/com.apple.diagnosticd.filter.plist"))
      (allow file-read-data (literal "/dev/autofs_nowait"))

      ; --- syslog ---
      ; syslog() connects to a Unix-domain socket, which Seatbelt classes
      ; as network-outbound — but it's local logging, not network access.
      ; Allow unconditionally rather than coupling it to allow_network.
      (allow network-outbound (literal "/private/var/run/syslog"))

      ; --- DNS resolver config ---
      ; resolv(3) reads these directly for hostname resolution — not via
      ; the system resolver APIs. Any process that does hostname lookup
      ; (Ruby resolv.rb, Python socket, Go net, etc.) needs both.
      ;
      ; Both paths require two literals each: the symlink the process opens
      ; and the real target the kernel resolves to. A deny at symlink
      ; traversal fires before the target rule is ever evaluated.
      ;   /etc/resolv.conf -> ../var/run/resolv.conf -> /private/var/run/resolv.conf
      ;   /etc/hosts       ->                        -> /private/etc/hosts
      (allow file-read-data
        (literal "/etc/resolv.conf")
        (literal "/private/var/run/resolv.conf")
        (literal "/etc/hosts")
        (literal "/private/etc/hosts"))

      SBPL

    def available? : Bool
      !Process.find_executable(BINARY).nil?
    end

    def run(command : Array(String), policy : Policy) : Result
      raise RunnerUnavailableError.new(
        "#{BINARY} not found. It should be present at /usr/bin/sandbox-exec on macOS."
      ) unless available?

      # File.tempfile with a block returns File, not the block value, so
      # Crystal cannot infer Result as the return type. Manage the tempfile
      # explicitly with begin/ensure instead.
      profile_file = File.tempfile("sbx_", ".sb")
      begin
        profile_file.print(generate_profile(policy))
        profile_file.flush
        execute([BINARY, "-f", profile_file.path, "--"] + command)
      ensure
        profile_file.close
        File.delete(profile_file.path) rescue nil
      end
    end

    def exec(command : Array(String), policy : Policy) : NoReturn
      raise RunnerUnavailableError.new(
        "#{BINARY} not found. It should be present at /usr/bin/sandbox-exec on macOS."
      ) unless available?

      # Deliberately not cleaned up with begin/ensure: replace_process
      # never returns on success, so an ensure block would never run.
      # sandbox-exec itself reads the file after exec(2) replaces this
      # process image, so it must still exist at that point.
      # The OS reclaims /tmp on reboot; this leaks one file per relaunch
      # otherwise, same as any tempfile from a process that's killed hard.
      profile_file = File.tempfile("sbx_", ".sb")
      profile_file.print(generate_profile(policy))
      profile_file.flush
      profile_file.close

      replace_process([BINARY, "-f", profile_file.path, "--"] + command)
    end

    # Returns the SBPL profile string for *policy*.
    # Useful for inspection, logging, or writing to disk without executing.
    #
    # All paths are resolved to their real, symlink-free form before being
    # written to the profile (see #resolve_path) — SBPL matches against the
    # path the kernel actually resolves to, not the string the caller wrote.
    # "./" or "~/.rubies" pointing through a symlink would silently match
    # nothing otherwise.
    def generate_profile(policy : Policy) : String
      String.build do |str|
        str << "(version 1)\n"
        str << "(deny default)\n\n"
        str << BASELINE
        str << "\n"

        # CoreFoundation reads this per-user file for legacy text encoding.
        # Harmless if denied, but it's $HOME-dependent so it can't live in
        # the static BASELINE constant.
        if home = ENV["HOME"]?
          str << "(allow file-read-data (literal #{File.join(home, ".CFUserTextEncoding").inspect}))\n\n"
        end

        # ── Read-only paths ───────────────────────────────────────────────
        unless policy.read_only_paths.empty?
          str << "(allow file-read*\n"
          policy.read_only_paths.each do |path|
            str << "  (subpath #{resolve_path(path).inspect})\n"
          end
          str << ")\n\n"
        end

        # ── Read-write paths ──────────────────────────────────────────────
        unless policy.read_write_paths.empty?
          str << "(allow file-read* file-write*\n"
          policy.read_write_paths.each do |path|
            str << "  (subpath #{resolve_path(path).inspect})\n"
          end
          str << ")\n\n"
        end

        # ── tmpfs paths ───────────────────────────────────────────────────
        # macOS has no tmpfs. We grant RW access to the existing path.
        # For true scratch isolation, pass a pre-created Dir.tempdir here.
        unless policy.tmpfs_paths.empty?
          str << "; tmpfs: no tmpfs on macOS — granting rw to existing paths\n"
          str << "(allow file-read* file-write*\n"
          policy.tmpfs_paths.each do |path|
            str << "  (subpath #{resolve_path(path).inspect})\n"
          end
          str << ")\n\n"
        end

        # ── Working directory ─────────────────────────────────────────────
        # Ensure it's accessible even if not covered by the path lists above.
        if wd = policy.working_dir
          abs_wd = resolve_path(wd)
          all_paths = (policy.read_write_paths +
                       policy.read_only_paths +
                       policy.tmpfs_paths).map { |path| resolve_path(path) }
          unless all_paths.any? { |path| abs_wd.starts_with?(path) }
            str << "; working_dir not covered by path lists — granting rw\n"
            str << "(allow file-read* file-write* (subpath #{abs_wd.inspect}))\n\n"
          end
        end

        # ── Network ───────────────────────────────────────────────────────
        if policy.allow_network?
          str << "(allow network-outbound)\n"
          str << "(allow network-inbound)\n"
          str << "(allow network-bind)\n"
        end
      end
    end

    # Resolves *path* to its real, symlink-free absolute form.
    #
    # SBPL's `subpath`/`literal` rules are matched against the path the
    # kernel resolves to after following symlinks — not the string the
    # caller wrote. `/tmp` is itself a symlink to `/private/tmp` on macOS,
    # so even the common `tmpfs("/tmp")` case depends on this.
    #
    # Falls back to `File.expand_path` when the path doesn't exist yet —
    # `realpath` raises in that case, but `read_write_paths` may legitimately
    # name a path the sandboxed process will create.
    private def resolve_path(path : String) : String
      File.realpath(path)
    rescue File::Error
      File.expand_path(path)
    end
  end
end
