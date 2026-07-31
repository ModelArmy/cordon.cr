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
  #
  # process-exec / process-exec-interpreter are deliberately NOT part of
  # BASELINE. `(allow process-exec)` with no path filter permits exec'ing ANY
  # binary on the filesystem, regardless of file-read* restrictions elsewhere
  # in the profile — Seatbelt does not cross-reference the two independent
  # permissions, and (deny default) does not implicitly couple "readable"
  # with "executable". A read-only or read-write policy that only grants
  # access to a workspace directory would still allow exec'ing e.g.
  # /usr/bin/ruby, /opt/homebrew/bin/*, or any other binary on the system —
  # entirely bypassing the intended containment. process-exec-interpreter
  # (governs the interpreter named on a script's #! line) is the same class
  # of bypass reached via a script instead of a direct exec, so it gets the
  # same treatment. Both are scoped per-profile in #generate_profile instead,
  # to exactly the paths already granted file-read* (read-only/read-write/
  # tmpfs) — and nothing else.
  #
  # In particular, the target command's own binary is NOT granted an
  # implicit exception. The policy defines the perimeter; a command that
  # lives outside it must be rejected, not admitted on the grounds that it
  # was the command asked for. Naming a binary is not authority to run it —
  # under the agent threat model the command string is precisely what the
  # untrusted party controls, so honouring it would let the sandboxed side
  # choose its own escape. Running a command therefore requires that the
  # policy already cover it (via read_only/read_write/tmpfs, Preset::System,
  # or a toolchain preset). Even system binaries like /bin/sh are NOT
  # exec-able by default. See DEVELOPMENT.md → "Why process-exec is not in
  # BASELINE".
  class SandboxExec < Runner
    BINARY = "sandbox-exec"

    BASELINE = <<-SBPL
      ; --- process lifecycle ---
      (allow process-fork)

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
    # Depends only on *policy* — the profile is the same whatever command is
    # eventually run under it, since no command receives an implicit grant
    # (see BASELINE's comment). This makes the profile fully inspectable
    # ahead of time: what `cordon inspect` prints is what will be enforced.
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

        # ── process-exec: scoped, never blanket ─────────────────────────────
        # See BASELINE's comment for why this isn't unconditional. Exec is
        # allowed under exactly the paths already granted file-read* above
        # (read-only, read-write, tmpfs): a process that can read a binary's
        # bytes may exec it, and nothing outside those paths may be exec'd
        # at all — including the command this profile was built to run. If
        # the policy doesn't cover it, sandbox-exec fails its own execvp
        # with EPERM ("Operation not permitted"), which is the correct
        # answer: that binary is outside the cordon.
        #
        # No system binary directories (/bin, /usr/bin, etc.) are granted
        # here. That's a deliberate policy choice, not an oversight: macOS
        # ships its own python3/perl/etc. at those paths, so a blanket grant
        # would silently let a sandboxed process reach system interpreters
        # even when the caller's policy grants nothing at all — reproducing
        # a narrower version of the same class of bug this scoping exists to
        # close. If your command needs to shell out (e.g. via
        # system()/popen(), or a script with a #!/bin/sh line), merge in
        # Preset::System, which grants exactly this read-only (and thus
        # exec-eligible) — see preset docs for what it covers.
        exec_paths = (policy.read_only_paths +
                      policy.read_write_paths +
                      policy.tmpfs_paths).map { |path| resolve_path(path) }.uniq!

        unless exec_paths.empty?
          str << "(allow process-exec process-exec-interpreter\n"
          exec_paths.each do |path|
            str << "  (subpath #{path.inspect})\n"
          end
          str << ")\n\n"
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
