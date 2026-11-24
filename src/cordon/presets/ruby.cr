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
    # All presets grant read-only access to the user gem directory
    # RubyGems uses: `~/.gem` when it exists, otherwise `~/.local/share/gem`.
    # Each is granted only if it exists.
    #
    # The sandbox does not inherit `GEM_HOME` or `GEM_PATH`, so gems a
    # version manager keeps elsewhere are not found. chruby, for one, sets
    # `GEM_HOME` to `~/.gem/ruby/<full version>`, which is not RubyGems'
    # own default of `~/.gem/ruby/<API version>`. Pass them to
    # `for_executable`, which grants each existing directory and sets the
    # variables:
    #
    #   policy = my_policy.merge(Cordon::Preset::Ruby.for_executable(
    #     ruby_path, gem_home: ENV["GEM_HOME"]?, gem_path: ENV["GEM_PATH"]?))
    #
    # chruby's other variables (`RUBY_ROOT`, `RUBY_ENGINE`, `RUBY_VERSION`,
    # `GEM_ROOT`) are bookkeeping that Ruby does not read, and `RUBYOPT` and
    # `RUBYLIB` inject code into the interpreter, so none is passed. If
    # `BUNDLE_PATH` is overridden, merge an additional policy covering it.
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
        user_gem_dirs.each { |dir| policy.read_only dir }
      end

      # Intel macOS, Homebrew Ruby.
      # Homebrew root: /usr/local. Gems: ~/.gem/ruby/<version>.
      MACOS_INTEL_BREW = Policy.build do |policy|
        policy.read_only "/usr/local/lib/ruby",
          "/usr/local/opt/ruby",
          "/usr/local/Cellar/ruby"
        user_gem_dirs.each { |dir| policy.read_only dir }
      end

      # Linux, system Ruby (apt/dnf/zypper).
      # Common lib roots: /usr/lib/ruby, /usr/local/lib/ruby.
      # Gems: ~/.gem/ruby/<version> or /var/lib/gems.
      LINUX_SYSTEM = Policy.build do |policy|
        policy.read_only "/usr/lib/ruby",
          "/usr/local/lib/ruby",
          "/usr/share/ruby",
          "/var/lib/gems"
        user_gem_dirs.each { |dir| policy.read_only dir }
      end

      # Linux, Homebrew (Linuxbrew) Ruby.
      # Linuxbrew root: /home/linuxbrew/.linuxbrew.
      # ~/.linuxbrew fallback is excluded — not statically knowable.
      LINUX_BREW = Policy.build do |policy|
        policy.read_only "/home/linuxbrew/.linuxbrew/lib/ruby",
          "/home/linuxbrew/.linuxbrew/opt/ruby",
          "/home/linuxbrew/.linuxbrew/Cellar/ruby"
        user_gem_dirs.each { |dir| policy.read_only dir }
      end

      # Derives a policy from the path to a Ruby binary.
      #
      # Resolves symlinks via `File.realpath`, then walks up two levels to
      # find the install root (e.g. `/path/to/root/bin/ruby` → `/path/to/root`).
      # Grants read-only access to the root tree and the user gem directories
      # (see `user_gem_dirs`).
      #
      # *gem_home* and *gem_path* carry the caller's `GEM_HOME` and
      # `GEM_PATH` into the sandbox, which does not inherit them. Each
      # directory that exists is granted read-only, and the variable is set
      # to the given value with paths made absolute, whether or not every
      # directory exists yet. `GEM_PATH` is split on the platform's path
      # delimiter. A nil or empty value does nothing.
      #
      #   Cordon::Preset::Ruby.for_executable("/opt/rubies/ruby-3.3.6/bin/ruby",
      #     gem_home: "/home/me/.gem/ruby/3.3.6").env["GEM_HOME"] # => "/home/me/.gem/ruby/3.3.6"
      #
      # Merge this preset last: another policy's `env` that sets `GEM_HOME`
      # or `GEM_PATH` moves the variable but not the grant.
      #
      # Works for any self-contained Ruby install tree regardless of manager:
      # ruby-install (~/.rubies), rbenv (~/.rbenv/versions), chruby, asdf.
      #
      # The path must be the real binary, not a shim. Shim-based managers
      # (rbenv, asdf) intercept execution via wrapper scripts — pass the
      # output of `rbenv which ruby` or `asdf which ruby` instead.
      def self.for_executable(path : String, *, gem_home : String? = nil, gem_path : String? = nil) : Policy
        real = File.realpath(path)
        root = File.dirname(File.dirname(real))
        Policy.build do |policy|
          policy.read_only root
          user_gem_dirs.each { |dir| policy.read_only dir }
          if dir = gem_home.try(&.presence)
            dir = File.expand_path(dir)
            policy.read_only dir if Dir.exists?(dir)
            policy.env["GEM_HOME"] = dir
          end
          dirs = gem_path_entries(gem_path)
          unless dirs.empty?
            dirs.each { |entry| policy.read_only entry if Dir.exists?(entry) }
            policy.env["GEM_PATH"] = dirs.join(Process::PATH_DELIMITER)
          end
        end
      end

      # Returns the directories under *home* that RubyGems may use for
      # user-installed gems and that exist: `~/.gem`, and
      # `~/.local/share/gem`, which it uses instead when `~/.gem` is absent.
      # Returns none when *home* is nil.
      #
      #   Cordon::Preset::Ruby.user_gem_dirs("/home/me") # => ["/home/me/.gem"]
      def self.user_gem_dirs(home : String? = ENV["HOME"]?) : Array(String)
        return [] of String unless home
        [File.join(home, ".gem"), File.join(home, ".local", "share", "gem")].select { |dir| Dir.exists?(dir) }
      end

      # Splits *gem_path* on the path delimiter into absolute, distinct
      # entries; none when it is nil or empty.
      private def self.gem_path_entries(gem_path : String?) : Array(String)
        return [] of String unless gem_path
        entries = gem_path.split(Process::PATH_DELIMITER, remove_empty: true).map { |entry| File.expand_path(entry) }
        entries.uniq!
        entries
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
