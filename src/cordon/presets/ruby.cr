module Cordon
  module Preset
    # Pre-defined policies for common Ruby installations.
    #
    # Choose the constant that matches the Ruby installation layout, or use
    # `for_executable` to derive a policy from a known binary path (useful
    # for manager-installed rubies where the root varies at runtime).
    #
    # ## Static presets
    #
    # Each constant covers the Ruby runtime, stdlib, and the default per-user
    # gem directory. Merge the appropriate constant into your policy:
    #
    #   policy = my_policy.merge(Cordon::Preset::Ruby::MACOS_ARM_BREW)
    #
    # ## Builder
    #
    # For rubies installed by a version manager (ruby-install, rbenv, chruby,
    # asdf), where the install root varies at runtime, use `for_executable`:
    #
    #   policy = my_policy.merge(Cordon::Preset::Ruby.for_executable("/path/to/ruby"))
    #
    # The path must be the real binary, not a shim. For shim-based managers:
    #
    #   # rbenv
    #   ruby_path = `rbenv which ruby`.chomp
    #   # asdf
    #   ruby_path = `asdf which ruby`.chomp
    #
    # ## Gem paths
    #
    # All presets grant read-only access to the default GEM_HOME for the
    # layout. If GEM_HOME or BUNDLE_PATH is overridden in the environment,
    # merge an additional policy covering those paths.
    #
    # ## Excluded layouts
    #
    # macOS system Ruby (/usr/bin/ruby) is excluded — its lib paths depend on
    # whichever Xcode/CLT toolchain is active and are not statically knowable.
    # It is also deprecated for developer use by Apple.
    #
    # The ~/.linuxbrew fallback for Linuxbrew is excluded — it is a
    # runtime-dependent path that cannot be known at preset-definition time.
    module Ruby
      # Apple Silicon macOS, Homebrew Ruby.
      # Homebrew root: /opt/homebrew. Gems: ~/.gem/ruby/<version>.
      MACOS_ARM_BREW = Policy.build do |policy|
        policy.read_only "/opt/homebrew/lib/ruby",
          "/opt/homebrew/opt/ruby",
          "/opt/homebrew/Cellar/ruby"
        if home = ENV["HOME"]?
          policy.read_only File.join(home, ".gem")
        end
      end

      # Intel macOS, Homebrew Ruby.
      # Homebrew root: /usr/local. Gems: ~/.gem/ruby/<version>.
      MACOS_INTEL_BREW = Policy.build do |policy|
        policy.read_only "/usr/local/lib/ruby",
          "/usr/local/opt/ruby",
          "/usr/local/Cellar/ruby"
        if home = ENV["HOME"]?
          policy.read_only File.join(home, ".gem")
        end
      end

      # Linux, system Ruby (apt/dnf/zypper).
      # Common lib roots: /usr/lib/ruby, /usr/local/lib/ruby.
      # Gems: ~/.gem/ruby/<version> or /var/lib/gems.
      LINUX_SYSTEM = Policy.build do |policy|
        policy.read_only "/usr/lib/ruby",
          "/usr/local/lib/ruby",
          "/usr/share/ruby",
          "/var/lib/gems"
        if home = ENV["HOME"]?
          policy.read_only File.join(home, ".gem")
        end
      end

      # Linux, Homebrew (Linuxbrew) Ruby.
      # Linuxbrew root: /home/linuxbrew/.linuxbrew.
      # ~/.linuxbrew fallback is excluded — not statically knowable.
      LINUX_BREW = Policy.build do |policy|
        policy.read_only "/home/linuxbrew/.linuxbrew/lib/ruby",
          "/home/linuxbrew/.linuxbrew/opt/ruby",
          "/home/linuxbrew/.linuxbrew/Cellar/ruby"
        if home = ENV["HOME"]?
          policy.read_only File.join(home, ".gem")
        end
      end

      # Derives a policy from the path to a Ruby binary.
      #
      # Resolves symlinks via `File.realpath`, then walks up two levels to
      # find the install root (e.g. `/path/to/root/bin/ruby` → `/path/to/root`).
      # Grants read-only access to the root tree and the default gem directory.
      #
      # Works for any self-contained Ruby install tree regardless of manager:
      # ruby-install (~/.rubies), rbenv (~/.rbenv/versions), chruby, asdf.
      #
      # The path must be the real binary, not a shim. Shim-based managers
      # (rbenv, asdf) intercept execution via wrapper scripts — pass the
      # output of `rbenv which ruby` or `asdf which ruby` instead.
      def self.for_executable(path : String) : Policy
        real = File.realpath(path)
        root = File.dirname(File.dirname(real))
        Policy.build do |policy|
          policy.read_only root
          if home = ENV["HOME"]?
            policy.read_only File.join(home, ".gem")
          end
        end
      end

      # Returns the static preset for the platform this code is compiled
      # for and the requested installation type. `with_brew` has no
      # default — pass `with_brew: true` for a Homebrew/Linuxbrew Ruby, or
      # `with_brew: false` for a Linux system-package Ruby.
      #
      # Raises UnsupportedPlatformError if:
      #   - Cordon has no Ruby preset for this platform at all, or
      #   - `with_brew: false` is requested on macOS — there is no static
      #     macOS system-Ruby preset (see this module's "Excluded layouts"
      #     doc above for why). Use `with_brew: true`, or `for_executable`
      #     for a non-Homebrew macOS install.
      def self.for_current_platform(*, with_brew : Bool) : Policy
        {% if flag?(:darwin) && flag?(:aarch64) %}
          raise_no_macos_system_preset unless with_brew
          MACOS_ARM_BREW
        {% elsif flag?(:darwin) %}
          raise_no_macos_system_preset unless with_brew
          MACOS_INTEL_BREW
        {% elsif flag?(:linux) %}
          with_brew ? LINUX_BREW : LINUX_SYSTEM
        {% else %}
          raise UnsupportedPlatformError.new("Preset::Ruby has no static preset for this platform")
        {% end %}
      end

      private def self.raise_no_macos_system_preset : NoReturn
        raise UnsupportedPlatformError.new(
          "Preset::Ruby has no static macOS system-Ruby preset — its lib " \
          "paths depend on whichever Xcode/CLT toolchain is active and " \
          "aren't statically knowable, and it's deprecated for developer " \
          "use by Apple. Use with_brew: true, or " \
          "Preset::Ruby.for_executable(path) for a non-Homebrew install."
        )
      end
    end
  end
end
