module Cordon
  class Error < Exception; end

  # Raised when no sandbox runner is available on the current platform.
  class RunnerUnavailableError < Error; end

  # Raised when a policy is invalid or cannot be applied.
  class PolicyError < Error; end
end
