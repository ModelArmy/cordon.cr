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
#   puts runner.generate_profile(policy, ["ls", "-la"])
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

  # Env var used to detect and count self-relaunch hops. Not a security
  # boundary — see #relaunch.
  RELAUNCH_DEPTH_ENV = "CORDON_RELAUNCH_DEPTH"

  # Maximum relaunch hops before #relaunch refuses and returns, guarding
  # against runaway re-entrancy (e.g. two libraries in the same process
  # both calling #relaunch).
  MAX_RELAUNCH_DEPTH = 1

  # Re-executes the current process inside a sandbox governed by *policy*,
  # using Process.executable_path and ARGV to reconstruct the invocation.
  # Does not return on success — the calling process image is replaced.
  #
  # Call this once, early, before any untrusted code runs:
  #
  #   Cordon.relaunch(my_policy)
  #   # only reached once already inside the sandbox
  #   run_untrusted_code
  #
  # Re-entrancy guard, not a security boundary. *depth_env* tracks how many
  # times the process has relaunched itself, via an env var passed through
  # to the sandboxed child. Its only job is to stop a relaunched process
  # from relaunching itself again — it is not a defense against a hostile
  # process tampering with its own environment. Anything already able to
  # set env vars for this process before Cordon runs can set *depth_env*
  # to skip relaunch entirely; that's equivalent to simply invoking the
  # unsandboxed binary directly, and is outside what #relaunch can prevent.
  # All real protection comes from the sandbox applied on the first hop,
  # before untrusted code has ever run.
  def self.relaunch(
    policy : Policy,
    depth_env : String = RELAUNCH_DEPTH_ENV,
    max_depth : Int32 = MAX_RELAUNCH_DEPTH,
    runner : Runner = self.runner,
  ) : Nil
    depth = ENV[depth_env]?.try(&.to_i?) || 0
    return if depth >= max_depth

    exe = Process.executable_path ||
          raise Error.new("cannot determine path to own executable; relaunch requires it")

    exe_policy = Policy.build(&.read_only(File.dirname(exe)))
    launch_policy = policy.merge(exe_policy)
    launch_policy.env[depth_env] = (depth + 1).to_s

    runner.exec([exe] + ARGV, launch_policy)
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
