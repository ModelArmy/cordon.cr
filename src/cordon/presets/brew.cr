module Cordon
  module Preset
    # Pre-defined policies for Homebrew-installed commands.
    #
    # Homebrew uses different root directories depending on platform and
    # architecture. Merge the appropriate constant into your policy before
    # running a brew-installed command:
    #
    #   policy = my_policy.merge(Cordon::Preset::Brew::MACOS_ARM)
    #
    # All paths are granted read-only access. If a brew-installed tool needs
    # to write under its prefix (uncommon), add the path to your own policy's
    # read_write_paths.
    module Brew
      # Apple Silicon macOS: Homebrew root is /opt/homebrew.
      MACOS_ARM = Policy.build do |policy|
        policy.read_only "/opt/homebrew"
      end

      # Intel macOS: Homebrew root is /usr/local.
      # Note: /usr/local/lib and /usr/local/share may already be covered by
      # system paths on some macOS versions, but the full prefix is granted
      # here for completeness.
      MACOS_INTEL = Policy.build do |policy|
        policy.read_only "/usr/local"
      end

      # Linux: Homebrew root is /home/linuxbrew/.linuxbrew.
      # Also grants read access to the user running the brew installation,
      # since Linuxbrew may symlink into ~/.linuxbrew as a fallback.
      LINUX = Policy.build do |policy|
        policy.read_only "/home/linuxbrew/.linuxbrew"
      end

      # Returns the static preset for the platform this code is compiled
      # for. A compile-time convenience over selecting MACOS_ARM /
      # MACOS_INTEL / LINUX by hand — reduces to a single constant
      # reference at compile time, no runtime branching.
      #
      # Raises UnsupportedPlatformError if Cordon has no Brew preset for
      # this platform.
      def self.for_current_platform : Policy
        {% if flag?(:darwin) && flag?(:aarch64) %}
          MACOS_ARM
        {% elsif flag?(:darwin) %}
          MACOS_INTEL
        {% elsif flag?(:linux) %}
          LINUX
        {% else %}
          raise UnsupportedPlatformError.new("Preset::Brew has no static preset for this platform")
        {% end %}
      end
    end
  end
end
