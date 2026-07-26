require "./cordon/error"
require "./cordon/result"
require "./cordon/policy"
require "./cordon/runner"
require "./cordon/linux_bwrap"
require "./cordon/macos_sandbox_exec"
require "./cordon/presets/*"

# Sandbox provides a platform-agnostic API for running shell commands
# inside a configurable sandbox.
#
# Platform mapping:
#   Linux   → bwrap (Bubblewrap), using unprivileged user namespaces
#   macOS   → sandbox-exec, using the Seatbelt MACF kernel module (SBPL profiles)
#   Windows → not yet implemented (see ARCHITECTURE.md)
#
# Quick start:
#
#   policy = Cordon::Policy.build do |p|
#     p.read_only "/usr/share/myapp"
#     p.read_write "/tmp/workspace"
#     p.tmpfs "/tmp"
#     p.allow_network = false
#     p.working_dir = "/tmp/workspace"
#   end
#
#   result = Sandbox.run(["python3", "script.py"], policy)
#
#   if result.success?
#     puts result.stdout
#   else
#     STDERR.puts result.stderr
#     exit result.exit_code
#   end
#
# Inspecting the generated invocation without executing:
#
#   runner = Cordon::Bwrap.new
#   puts runner.build_argv(["ls", "-la"], policy).inspect
#
#   runner = Cordon::SandboxExec.new
#   puts runner.generate_profile(policy)
#
module Cordon
  # Read this at compile time from shard.yml one day
  VERSION    = {{ `shards version #{__DIR__}`.chomp.stringify }}
  PRERELEASE = VERSION.match(/^\d+\.\d+\.\d+$/).nil?

  # Returns the best available runner for the current platform.
  # Raises RunnerUnavailableError if nothing is usable.
  def self.runner : Runner
    platform_runners.find(&.available?) ||
      raise RunnerUnavailableError.new(
        "No sandbox runner available. " \
        "On Linux, install bwrap (bubblewrap). " \
        "On macOS, sandbox-exec should be present at /usr/bin/sandbox-exec."
      )
  end

  # Runs *command* inside a sandbox governed by *policy*.
  # Uses the platform-appropriate runner (see platform_runners).
  def self.run(command : Array(String), policy : Policy) : Result
    runner.run(command, policy)
  end

  # Returns all known runners for this platform, in preference order.
  # Runners may not be available; each responds to #available?.
  def self.platform_runners : Array(Runner)
    {% if flag?(:linux) %}
      [Bwrap.new] of Runner
    {% elsif flag?(:darwin) %}
      [SandboxExec.new] of Runner
    {% else %}
      [] of Runner
    {% end %}
  end
end
