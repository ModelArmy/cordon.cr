require "file_utils"

module Cordon
  module Preset
    # Policies that let the `crystal` compiler build, run and spec programs
    # inside the sandbox.
    #
    # The preset grants the compiler a cache directory and a temp directory,
    # and `shards` a cache directory, and points `CRYSTAL_CACHE_DIR`, `TMPDIR`
    # and `SHARDS_CACHE_PATH` at them. On macOS it also
    # grants the developer tools read-only and sets `PATH` and `SDKROOT` so
    # the compiler finds `cc`, `ld` and the SDK without `xcrun`; on Linux it
    # grants the linker paths in `LINUX_TOOLCHAIN_PATHS` that exist.
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
    # arguments. Setting `CRYSTAL_CACHE_DIR`, `TMPDIR` or `SHARDS_CACHE_PATH`
    # in another policy's `env` moves the variable but not the grant: the
    # preset's directory stays writable, and the new one is not granted.
    #
    # ## The cache directories
    #
    # The compiler reuses a cached object file whenever the new bitcode is
    # identical, so a sandboxed command that can write to a cache can plant
    # code that a later build links. Give each sandboxed use its own
    # directory. To share the cache your own builds use, pass
    # `shared_cache_dir` explicitly; that lets the sandbox write code your
    # next unsandboxed build may link.
    #
    # The shards cache holds a git mirror of each dependency, and `shards`
    # runs `git` inside those mirrors, so a sandboxed command that can write
    # to it can plant a git hook that runs, outside the sandbox, the next
    # time you install that dependency in any project. It defaults to a
    # `shards` directory inside the temp directory, which is safe but
    # clones every dependency again on each run. To share the cache your
    # own `shards` uses, pass `shared_shards_cache_dir` explicitly.
    #
    # Raises UnsupportedPlatformError on Windows.
    module Crystal
      TEMP_DIR_PREFIX = "cordon-crystal"

      # Returns a policy granting *cache_dir*, *temp_dir* and
      # *shards_cache_dir* read-write, creating each if missing.
      # *shards_cache_dir* defaults to a `shards` directory inside
      # *temp_dir*. *path_env* is the `PATH` the macOS toolchain's directory
      # is prepended to; pass your own if your policy sets `PATH`, since the
      # preset's value replaces it on merge. It is unused on Linux.
      def self.build(*, cache_dir : String, temp_dir : String, shards_cache_dir : String? = nil, path_env : String? = ENV["PATH"]?) : Policy
        {% if flag?(:win32) %}
          raise UnsupportedPlatformError.new("Preset::Crystal does not support Windows yet")
        {% else %}
          cache_dir = File.expand_path(cache_dir)
          temp_dir = File.expand_path(temp_dir)
          shards_cache_dir = File.expand_path(shards_cache_dir || File.join(temp_dir, "shards"))
          Dir.mkdir_p(cache_dir)
          Dir.mkdir_p(temp_dir)
          Dir.mkdir_p(shards_cache_dir)
          preset = Policy.build do |policy|
            policy.read_write cache_dir, temp_dir, shards_cache_dir
            policy.env["CRYSTAL_CACHE_DIR"] = cache_dir
            policy.env["TMPDIR"] = temp_dir
            policy.env["SHARDS_CACHE_PATH"] = shards_cache_dir
          end
          {% if flag?(:darwin) %}
            preset = preset.merge(macos_toolchain(path_env))
          {% elsif flag?(:linux) %}
            preset = preset.merge(linux_toolchain)
          {% end %}
          preset
        {% end %}
      end

      # Creates a private temp directory, yields the policy from `build`
      # for it, and deletes the directory when the block returns or raises,
      # along with the default shards cache inside it. Returns the block's
      # value.
      def self.with_temp_dir(*, cache_dir : String, shards_cache_dir : String? = nil, path_env : String? = ENV["PATH"]?, & : Policy -> T) : T forall T
        temp_dir = create_temp_dir
        begin
          yield build(cache_dir: cache_dir, temp_dir: temp_dir, shards_cache_dir: shards_cache_dir, path_env: path_env)
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
        first_creatable(compiler_cache_candidates, "cache directory")
      end

      # Returns the cache directory `shards` uses outside the sandbox,
      # creating it if missing. Passing it to `build` or `with_temp_dir`
      # lets the sandbox plant git hooks that run, unsandboxed, the next
      # time you install a dependency it holds.
      #
      # Raises PolicyError if no candidate directory can be created.
      def self.shared_shards_cache_dir : String
        first_creatable(shards_cache_candidates, "shards cache directory")
      end

      # Tries the tool's own candidates, in its order, from this process's
      # environment; the first that exists or can be created wins.
      private def self.first_creatable(candidates : Array(String?), what : String) : String
        dirs = candidates.compact.map! { |dir| File.expand_path(dir) }
        dirs.uniq!
        dirs.each do |dir|
          Dir.mkdir_p(dir)
          return dir
        rescue File::Error
        end
        raise PolicyError.new("Preset::Crystal found no creatable #{what} among: #{dirs.join(", ")}")
      end

      # The compiler's order, from `compiler/crystal/codegen/cache_dir.cr`.
      private def self.compiler_cache_candidates : Array(String?)
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

      # Shards' order, from `Shards.cache_path` in shards' `src/config.cr`.
      private def self.shards_cache_candidates : Array(String?)
        {% if flag?(:win32) %}
          [
            ENV["SHARDS_CACHE_PATH"]?,
            ENV["LOCALAPPDATA"]?.try { |dir| "#{dir}/shards/cache" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.cache/shards" },
            ENV["USERPROFILE"]?.try { |home| "#{home}/.shards" },
            ".shards",
          ] of String?
        {% else %}
          [
            ENV["SHARDS_CACHE_PATH"]?,
            ENV["XDG_CACHE_HOME"]?.try { |cache| "#{cache}/shards" },
            ENV["HOME"]?.try { |home| "#{home}/.cache/shards" },
            ENV["HOME"]?.try { |home| "#{home}/.cache/.shards" },
            ".shards",
          ] of String?
        {% end %}
      end

      private def self.create_temp_dir : String
        dir = File.tempname(TEMP_DIR_PREFIX, nil)
        Dir.mkdir(dir, 0o700)
        dir
      end

      private def self.macos_toolchain(path_env : String?) : Policy
        # Ask xcode-select and xcrun, outside the sandbox, where the active
        # developer tools live, on every call, so a change of toolchain
        # applies to the next build. Grant them read-only and point PATH and
        # SDKROOT at them, so nothing inside needs xcrun.
        developer_dir = tool_output("xcode-select", "-p")
        cc = tool_output("xcrun", "--find", "cc")
        sdk = tool_output("xcrun", "--show-sdk-path")
        bin = File.dirname(cc)
        Policy.build do |policy|
          policy.read_only developer_dir
          policy.read_only File.dirname(bin) unless cc.starts_with?("#{developer_dir}/")
          policy.read_only sdk unless sdk.starts_with?("#{developer_dir}/")
          policy.env["PATH"] = path_env ? "#{bin}:#{path_env}" : bin
          policy.env["SDKROOT"] = sdk
        end
      end

      # Linker paths outside the runner's baseline: the alternatives links
      # through which Debian-family distributions resolve `cc`, and GCC's
      # helpers such as `collect2`. Paths absent on this distribution are
      # skipped, since bwrap refuses to bind a missing path.
      LINUX_TOOLCHAIN_PATHS = %w[/etc/alternatives /usr/libexec/gcc]

      private def self.linux_toolchain : Policy
        Policy.build do |policy|
          LINUX_TOOLCHAIN_PATHS.each do |path|
            policy.read_only path if Dir.exists?(path)
          end
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
