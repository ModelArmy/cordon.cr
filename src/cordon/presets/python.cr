module Cordon
  module Preset
    # Pre-defined policies for common Python installations.
    #
    # Choose the constant that matches the Python installation layout, or use
    # `for_executable` / `for_venv` to derive a policy at runtime — useful
    # for manager-installed interpreters and virtual environments, where the
    # paths involved are not statically knowable.
    #
    # ## Static presets
    #
    # Each constant covers the Python runtime and stdlib for a known, fixed
    # installation layout. Merge the appropriate constant into your policy:
    #
    #   policy = my_policy.merge(Cordon::Preset::Python::MACOS_ARM_BREW)
    #
    # ## for_executable
    #
    # For interpreters installed by a version manager (pyenv, `uv python
    # install`), where the install root varies at runtime:
    #
    #   policy = my_policy.merge(Cordon::Preset::Python.for_executable("/path/to/python3"))
    #
    # The path must be the real binary, not a shim. For shim-based managers:
    #
    #   # pyenv
    #   python_path = `pyenv which python`.chomp
    #
    # `uv`-managed interpreters are not shimmed (uv installs real binaries
    # under its data directory), so `which python` resolves directly when a
    # uv-managed interpreter is first on PATH.
    #
    # ## for_venv
    #
    # A virtual environment is a thin directory that points back at a base
    # interpreter rather than containing a full one — `uv venv` and
    # `python -m venv` both create one in this shape, conventionally at
    # `.venv` next to the project's `pyproject.toml`. `for_venv` reads the
    # venv's `pyvenv.cfg` (specifically its `executable` / `base-executable`
    # key) to find the base interpreter, and grants access to both the
    # venv's own site-packages and the base interpreter's tree:
    #
    #   policy = my_policy.merge(Cordon::Preset::Python.for_venv("/path/to/project/.venv"))
    #
    # This is read-only — it covers running a script against an already
    # resolved environment, not `pip install` / `uv add` (which need write
    # access to the venv and, typically, network access).
    #
    # ## Excluded layouts
    #
    # macOS system Python (/usr/bin/python3) is excluded — Apple ships it
    # without a stable, documented lib path guarantee across OS versions,
    # and Apple discourages relying on it for development.
    #
    # The ~/.linuxbrew fallback for Linuxbrew is excluded — it is a
    # runtime-dependent path that cannot be known at preset-definition time.
    #
    # uv's own cache and tool-install directories are out of scope — they
    # are needed by `uv` itself during install/sync, not by the interpreter
    # at runtime, the same way `gem install` is out of scope for the Ruby
    # presets.
    module Python
      # Apple Silicon macOS, Homebrew Python.
      # Homebrew root: /opt/homebrew.
      MACOS_ARM_BREW = Policy.build do |policy|
        policy.read_only "/opt/homebrew/lib/python3.13",
          "/opt/homebrew/lib/python3.12",
          "/opt/homebrew/lib/python3.11",
          "/opt/homebrew/opt/python3",
          "/opt/homebrew/Cellar/python3"
      end

      # Intel macOS, Homebrew Python.
      # Homebrew root: /usr/local.
      MACOS_INTEL_BREW = Policy.build do |policy|
        policy.read_only "/usr/local/lib/python3.13",
          "/usr/local/lib/python3.12",
          "/usr/local/lib/python3.11",
          "/usr/local/opt/python3",
          "/usr/local/Cellar/python3"
      end

      # Linux, system Python (apt/dnf/zypper).
      # Common lib roots: /usr/lib/python3.x, /usr/local/lib/python3.x.
      LINUX_SYSTEM = Policy.build do |policy|
        policy.read_only "/usr/lib/python3.13",
          "/usr/lib/python3.12",
          "/usr/lib/python3.11",
          "/usr/lib/python3",
          "/usr/local/lib/python3.13",
          "/usr/local/lib/python3.12",
          "/usr/local/lib/python3.11",
          "/usr/share/python3"
      end

      # Linux, Homebrew (Linuxbrew) Python.
      # Linuxbrew root: /home/linuxbrew/.linuxbrew.
      # ~/.linuxbrew fallback is excluded — not statically knowable.
      LINUX_BREW = Policy.build do |policy|
        policy.read_only "/home/linuxbrew/.linuxbrew/lib/python3.13",
          "/home/linuxbrew/.linuxbrew/lib/python3.12",
          "/home/linuxbrew/.linuxbrew/lib/python3.11",
          "/home/linuxbrew/.linuxbrew/opt/python3",
          "/home/linuxbrew/.linuxbrew/Cellar/python3"
      end

      # Derives a policy from the path to a Python binary.
      #
      # Resolves symlinks via `File.realpath`, then walks up two levels to
      # find the install root (e.g. `/path/to/root/bin/python3` → `/path/to/root`).
      # Grants read-only access to the root tree.
      #
      # Works for any self-contained Python install tree regardless of
      # manager: pyenv (~/.pyenv/versions), `uv python install`
      # (~/.local/share/uv/python).
      #
      # The path must be the real binary, not a shim. Shim-based managers
      # (pyenv) intercept execution via wrapper scripts — pass the output
      # of `pyenv which python` instead.
      def self.for_executable(path : String) : Policy
        real = File.realpath(path)
        root = File.dirname(File.dirname(real))
        Policy.build(&.read_only(root))
      end

      # Derives a policy from the path to a virtual environment directory
      # (e.g. a project's `.venv`).
      #
      # Reads `pyvenv.cfg` inside the venv to find the base interpreter
      # binary (the `executable` key, or `base-executable` — used by some
      # venv-creating tools instead), resolves that interpreter via
      # `for_executable`, and additionally grants read-only access to the
      # venv directory itself (its own `lib/python3.x/site-packages`).
      #
      # Read-only: covers running a script against an already-resolved
      # environment, not installing packages into it.
      #
      # Raises `File::Error` if the path is not a venv (no `pyvenv.cfg`), or
      # `KeyError` if `pyvenv.cfg` has neither an `executable` nor a
      # `base-executable` entry.
      def self.for_venv(path : String) : Policy
        venv_root = File.realpath(path)
        cfg_path = File.join(venv_root, "pyvenv.cfg")
        base_python = parse_pyvenv_executable(File.read(cfg_path))

        base_policy = for_executable(base_python)
        base_policy.merge(Policy.build(&.read_only(venv_root)))
      end

      # Parses the base interpreter binary path out of a pyvenv.cfg file's
      # contents. Prefers `executable`; falls back to `base-executable`
      # (used by virtualenv and some other venv-creating tools).
      #
      # Deliberately does not use the `home` key — it names a directory, not
      # a binary, so the binary filename would have to be guessed
      # (python3 vs python3.11 vs python.exe), and `home` is also known to
      # sometimes record an unresolved symlink rather than the real
      # interpreter directory.
      private def self.parse_pyvenv_executable(contents : String) : String
        fields = {} of String => String
        contents.each_line do |line|
          key, sep, value = line.partition('=')
          next if sep.empty?
          fields[key.strip] = value.strip
        end
        fields["executable"]? || fields["base-executable"]? ||
          raise KeyError.new("pyvenv.cfg has neither 'executable' nor 'base-executable'")
      end
    end
  end
end
