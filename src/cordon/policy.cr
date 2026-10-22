require "json"

module Cordon
  # Describes what a sandboxed process is permitted to access.
  # Platform runners translate this into their native policy format —
  # an SBPL profile on macOS, a bwrap flag list on Linux.
  #
  # Can be constructed programmatically or deserialised from JSON:
  #
  #   # Programmatic
  #   policy = Cordon::Policy.build do |p|
  #     p.read_only "/usr/share/myapp"
  #     p.read_write "/tmp/workspace"
  #     p.tmpfs "/tmp"
  #     p.allow_network = false
  #     p.working_dir = "/tmp/workspace"
  #     p.env["MYAPP_ENV"] = "production"
  #   end
  #
  #   # From a JSON file
  #   policy = Cordon::Policy.from_json(File.read("policy.json"))
  #
  #   # Round-trip to JSON
  #   puts policy.to_json
  #
  class Policy
    include JSON::Serializable

    # Paths the sandboxed process may read but not write.
    @[JSON::Field(key: "read_only_paths")]
    property read_only_paths : Array(String) = [] of String

    # Paths the sandboxed process may read and write.
    @[JSON::Field(key: "read_write_paths")]
    property read_write_paths : Array(String) = [] of String

    # Paths to back with in-memory scratch space (tmpfs on Linux).
    # On macOS, sandbox-exec cannot mount tmpfs — these paths receive
    # RW access to the existing filesystem location instead.
    # Pass a pre-created Dir.tempdir value for true scratch isolation.
    @[JSON::Field(key: "tmpfs_paths")]
    property tmpfs_paths : Array(String) = [] of String

    # Whether outbound network access is permitted. Default: false.
    @[JSON::Field(key: "allow_network")]
    property? allow_network : Bool = false

    # Directory the sandboxed command starts in; nil keeps the caller's.
    # Grants nothing: it must fall within one of the path lists.
    @[JSON::Field(key: "working_dir")]
    property working_dir : String? = nil

    # Environment variables to set inside the sandbox. The sandbox does not
    # inherit the parent's environment: it starts with the runner's
    # DEFAULT_ENV_PASSTHROUGH set, taken from the parent, and these are
    # added on top, replacing any passthrough variable of the same name.
    @[JSON::Field(key: "env")]
    property env : Hash(String, String) = {} of String => String

    # Environment variables to remove from the sandbox's environment, after
    # #env is applied. Removes passthrough variables too, e.g. "TZ".
    @[JSON::Field(key: "unset_env")]
    property unset_env : Array(String) = [] of String

    # Start a new session (setsid). Prevents TTY escape attacks.
    # Default: true.
    @[JSON::Field(key: "new_session")]
    property? new_session : Bool = true

    def initialize
    end

    # Yields a new Policy for configuration, then returns it.
    def self.build(&) : self
      policy = new
      yield policy
      policy
    end

    # Convenience: add one or more read-only paths (chainable).
    def read_only(*paths : String) : self
      @read_only_paths.concat(paths.to_a)
      self
    end

    # Convenience: add one or more read-write paths (chainable).
    def read_write(*paths : String) : self
      @read_write_paths.concat(paths.to_a)
      self
    end

    # Convenience: add one or more tmpfs scratch paths (chainable).
    def tmpfs(*paths : String) : self
      @tmpfs_paths.concat(paths.to_a)
      self
    end

    # Returns a new Policy that is the union of self and *other*.
    #
    # Merge rules:
    # - Arrays (paths, unset_env): union, duplicates removed, order preserved.
    # - allow_network: true if either policy allows it (OR semantics).
    # - new_session: true if either policy requires it (OR semantics — safer).
    # - working_dir: *other* wins if set, otherwise self is kept.
    # - env: merged; *other* wins on key collision.
    def merge(other : Policy) : Policy
      merged = Policy.new
      merged.read_only_paths = (@read_only_paths + other.read_only_paths).uniq
      merged.read_write_paths = (@read_write_paths + other.read_write_paths).uniq
      merged.tmpfs_paths = (@tmpfs_paths + other.tmpfs_paths).uniq
      merged.unset_env = (@unset_env + other.unset_env).uniq
      merged.allow_network = @allow_network || other.allow_network?
      merged.new_session = @new_session || other.new_session?
      merged.working_dir = other.working_dir || @working_dir
      merged.env = @env.merge(other.env)
      merged
    end
  end
end
