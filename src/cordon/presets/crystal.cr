require "file_utils"

module Cordon
  module Preset
    # Policies that let the `crystal` compiler build, run and spec programs
    # inside the sandbox.
    #
    # The preset grants the compiler a cache directory and a temp directory
    # and points `CRYSTAL_CACHE_DIR` and `TMPDIR` at them. On macOS it also
    # grants the developer tools read-only and sets `PATH` and `SDKROOT` so
    # the compiler finds `cc`, `ld` and the SDK without `xcrun`.
    #
    # It grants neither the compiler itself nor `/bin/sh`, which the compiler
    # uses to run the linker, and no network access. Merge those yourself:
    #
    #   policy = Cordon::Policy.build { |policy| policy.read_write project_dir }
    #     .merge(Cordon::Preset::Brew.for_current_platform)
    #     .merge(Cordon::Preset::System.for_current_platform)
    #
    #   # A fresh temp directory, deleted when the block returns
    #   Cordon::Preset::Crystal.with_temp_dir(cache_dir: cache_dir) do |crystal|
    #     Cordon.run(["crystal", "spec"], policy.merge(crystal))
    #   end
    #
    #   # A temp directory you create and delete yourself
    #   crystal = Cordon::Preset::Crystal.build(cache_dir: cache_dir, temp_dir: temp_dir)
    #
    # Merge the preset last, and choose the directories only through its
    # arguments. Setting `CRYSTAL_CACHE_DIR` or `TMPDIR` in another policy's
    # `env` moves the variable but not the grant: the preset's directory
    # stays writable, and the new one is not granted.
    #
    # ## The cache directory
    #
    # The compiler reuses a cached object file whenever the new bitcode is
    # identical, so a sandboxed command that can write to a cache can plant
    # code that a later build links. Give each sandboxed use its own
    # directory. To share the cache your own builds use, pass
    # `shared_cache_dir` explicitly; that lets the sandbox write code your
    # next unsandboxed build may link.
    #
    # Raises UnsupportedPlatformError on Windows.
    module Crystal
      TEMP_DIR_PREFIX = "cordon-crystal"

      # Returns a policy granting *cache_dir* and *temp_dir* read-write,
      # creating either if missing. *path_env* is the `PATH` the macOS
      # toolchain's directory is prepended to; pass your own if your policy
      # sets `PATH`, since the preset's value replaces it on merge. It is
      # unused on Linux.
      def self.build(*, cache_dir : String, temp_dir : String, path_env : String? = ENV["PATH"]?) : Policy
        {% if flag?(:win32) %}
          raise UnsupportedPlatformError.new("Preset::Crystal does not support Windows yet")
        {% else %}
          cache_dir = File.expand_path(cache_dir)
          temp_dir = File.expand_path(temp_dir)
          Dir.mkdir_p(cache_dir)
          Dir.mkdir_p(temp_dir)
          preset = Policy.build do |policy|
            policy.read_write cache_dir, temp_dir
            policy.env["CRYSTAL_CACHE_DIR"] = cache_dir
            policy.env["TMPDIR"] = temp_dir
          end
          {% if flag?(:darwin) %}
            preset = preset.merge(macos_toolchain(path_env))
          {% end %}
          preset
        {% end %}
      end

      # Creates a private temp directory, yields the policy from `build`
      # for it, and deletes the directory when the block returns or raises.
      # Returns the block's value.
      def self.with_temp_dir(*, cache_dir : String, path_env : String? = ENV["PATH"]?, & : Policy -> T) : T forall T
        temp_dir = create_temp_dir
        begin
          yield build(cache_dir: cache_dir, temp_dir: temp_dir, path_env: path_env)
        ensure
          FileUtils.rm_rf(temp_dir)
        end
      end

      # Returns the cache directory the compiler uses outside the sandbox,
      # creating it if missing. Passing it to `build` or `with_temp_dir`
      # lets the sandbox write code your next unsandboxed build may link.
      #
      # Raises PolicyError if no candidate directory can be created.
      def self.shared_cache_dir : String
        # Try the compiler's own candidates, in its order, from this
        # process's environment; the first that can be created wins.
        candidates = cache_dir_candidates.compact.map! { |dir| File.expand_path(dir) }
        candidates.uniq!
        candidates.each do |candidate|
          Dir.mkdir_p(candidate)
          return candidate
        rescue File::Error
        end
        raise PolicyError.new("Preset::Crystal found no creatable cache directory among: #{candidates.join(", ")}")
      end

      private def self.cache_dir_candidates : Array(String?)
        {% if flag?(:win32) %}
          [
            ENV["CRYSTAL_CACHE_DIR"]?,
            ENV["LOCALAPPDATA"]?.try { |dir| "#{dir}/crystal/cache" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.cache/crystal" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.crystal" },
            ".crystal",
          ] of String?
        {% else %}
          [
            ENV["CRYSTAL_CACHE_DIR"]?,
            ENV["XDG_CACHE_HOME"]?.try { |home| "#{home}/crystal" },
            ENV["HOME"]?.try { |home| "#{home}/.cache/crystal" },
            ENV["HOME"]?.try { |home| "#{home}/.crystal" },
            ".crystal",
          ] of String?
        {% end %}
      end

      private def self.create_temp_dir : String
        dir = File.tempname(TEMP_DIR_PREFIX, nil)
        Dir.mkdir(dir, 0o700)
        dir
      end

      private record MacosTools, developer_dir : String, cc : String, sdk : String

      @@macos_tools : MacosTools?

      private def self.macos_toolchain(path_env : String?) : Policy
        # Ask xcode-select and xcrun, outside the sandbox, where the active
        # developer tools live, once per process. Grant them read-only and
        # point PATH and SDKROOT at them, so nothing inside needs xcrun.
        tools = @@macos_tools ||= MacosTools.new(
          tool_output("xcode-select", "-p"),
          tool_output("xcrun", "--find", "cc"),
          tool_output("xcrun", "--show-sdk-path"),
        )
        bin = File.dirname(tools.cc)
        Policy.build do |policy|
          policy.read_only tools.developer_dir
          policy.read_only File.dirname(bin) unless tools.cc.starts_with?("#{tools.developer_dir}/")
          policy.read_only tools.sdk unless tools.sdk.starts_with?("#{tools.developer_dir}/")
          policy.env["PATH"] = path_env ? "#{bin}:#{path_env}" : bin
          policy.env["SDKROOT"] = tools.sdk
        end
      end

      private def self.tool_output(command : String, *args : String) : String
        output = IO::Memory.new
        status = Process.run(command, args.to_a, output: output, error: Process::Redirect::Close)
        text = output.to_s.strip
        if !status.success? || text.empty?
          raise PolicyError.new(
            "Preset::Crystal could not locate the developer tools: `#{command} #{args.join(" ")}` failed. " \
            "Install them with `xcode-select --install`."
          )
        end
        text
      rescue ex : File::Error
        raise PolicyError.new("Preset::Crystal could not run `#{command}`: #{ex.message}")
      end
    end
  end
end
