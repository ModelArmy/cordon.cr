module Cordon
  class Error < Exception; end

  # Raised when no sandbox runner is available on the current platform.
  class RunnerUnavailableError < Error; end

  # Raised when a policy is invalid or cannot be applied.
  class PolicyError < Error; end

  # Raised by a Preset's `for_current_platform` when no static preset
  # exists for the platform (or, for presets with a `with_brew` axis, for
  # the requested platform/brew combination).
  class UnsupportedPlatformError < Error; end
end
