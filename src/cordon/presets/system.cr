module Cordon
  module Preset
    # Grants read-only — and therefore exec-eligible — access to standard
    # system binary directories (/bin, /usr/bin).
    #
    # Neither SandboxExec (macOS) nor Bwrap (Linux) grant exec access to
    # these directories by default. On macOS, SBPL's process-exec is scoped
    # per-profile to whatever's already granted file-read* (see
    # SandboxExec::BASELINE's comment); on Linux, bwrap's mount namespace
    # has no permission distinct from "mounted" at all, so binary
    # directories are simply not bind-mounted unless asked for (see
    # Bwrap::SYSTEM_RO_PATHS' comment). Both are deliberate: an empty
    # policy should not silently let a sandboxed process reach the
    # system's own interpreters (ruby, python3, perl, ...) that happen to
    # live in these directories.
    #
    # Merge this preset in when your command needs to shell out — e.g. via
    # system()/popen(), or a script with a #!/bin/sh line — or otherwise
    # needs to exec another program from the system's standard locations:
    #
    #   policy = my_policy.merge(Cordon::Preset::System::MACOS)   # or ::LINUX
    #
    # Scope: only /bin and /usr/bin. /usr/sbin and /sbin (system
    # administration tools — ip, useradd, and similar) are deliberately
    # excluded; a sandboxed, untrusted process has no ordinary reason to
    # exec anything there, and including them would widen this preset
    # beyond its stated purpose (basic shell/interpreter availability) for
    # no common benefit. If you specifically need something under
    # /usr/sbin or /sbin, add it to your own policy with `read_only`.
    #
    # Platform note (Linux): unlike Bwrap::SYSTEM_RO_PATHS, which uses
    # --ro-bind-try (tolerates a path being absent on a given distro),
    # Policy#read_only always maps to a strict --ro-bind, which fails if
    # the path doesn't exist. /bin and /usr/bin are present — either as
    # real directories or as usrmerge symlinks between each other — on
    # essentially every mainstream distro capable of running bwrap. An
    # unusual or minimal image lacking one of them would fail at bwrap
    # invocation time with a clear error, not silently.
    module System
      MACOS = Policy.build do |policy|
        policy.read_only "/bin", "/usr/bin"
      end

      LINUX = Policy.build do |policy|
        policy.read_only "/bin", "/usr/bin"
      end
    end
  end
end
