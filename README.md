# Cordon

> **Usable on macOS and Linux. Still in development to add Windows support.**

A Crystal shard for running shell commands inside a platform-native "cordon" or sandbox, with a configurable access policy.

|Platform|Mechanism                                |Status  |
|--------|-----------------------------------------|--------|
|macOS   |`sandbox-exec` + SBPL profiles (Seatbelt)|✔️ Tested|
|Linux   |`bwrap` (Bubblewrap) user namespaces     |✔️ Tested|

## Usage as a shard

Add to your `shard.yml`:

```yaml
dependencies:
  cordon:
    github: modelarmy/cordon.cr
```

Then `shards install`.

### Defining a policy

```crystal
require "cordon"

policy = Cordon::Policy.build do |p|
  p.read_only "/usr/share/myapp"   # paths the process may read
  p.read_write "/tmp/workspace"    # paths the process may read and write
  p.tmpfs "/tmp"                   # in-memory scratch space (Linux); RW grant (macOS)
  p.allow_network = false          # deny all network access
  p.working_dir = "/tmp/workspace"
  p.env["APP_ENV"] = "sandbox"     # explicit env vars inside the sandbox
end
```

All fields are optional. Omitted fields default to the safest option: no network, no paths, no extra env vars.

Policies can also be loaded from a JSON file:

```crystal
policy = Cordon::Policy.from_json(File.read("policy.json"))
```

```json
{
  "read_only_paths":  ["/usr/share/myapp"],
  "read_write_paths": ["/tmp/workspace"],
  "tmpfs_paths":      ["/tmp"],
  "allow_network":    false,
  "working_dir":      "/tmp/workspace",
  "env":              { "APP_ENV": "sandbox" }
}
```

### Running a command

```crystal
result = Cordon.run(["python3", "script.py"], policy)

if result.success?
  puts result.stdout
else
  STDERR.puts result.stderr
  exit result.exit_code
end
```

`Cordon.run` selects the appropriate runner for the current platform automatically. Exit codes follow Unix conventions; signal exits are mapped to `128 + signal_number`.

### Inspecting the generated invocation

Both runners expose their native policy representation without executing, which is useful for logging, auditing, or iterating on a policy:

```crystal
# Linux: print the bwrap flag list
runner = Cordon::Bwrap.new
puts runner.build_argv(["python3", "script.py"], policy).join(" ")

# macOS: print the SBPL profile
runner = Cordon::SandboxExec.new
puts runner.generate_profile(policy)
```

### Checking runner availability

```crystal
Cordon.platform_runners.each do |runner|
  puts "#{runner.class}: #{runner.available? ? "available" : "not found"}"
end
```

### Merging policies

Policies can be merged to layer reusable building blocks on top of a base policy:

```crystal
merged = my_policy.merge(other_policy)
```

Merge rules:
- **Path arrays** (`read_only_paths`, `read_write_paths`, `tmpfs_paths`, `unset_env`): union, duplicates removed.
- **`allow_network`**: `true` if either policy allows it.
- **`new_session`**: `true` if either policy requires it.
- **`working_dir`**: `other` wins if set, otherwise `self` is kept.
- **`env`**: merged; `other` wins on key collision.

`merge` returns a new `Policy`; neither original is modified.

### Presets

Cordon ships pre-defined policies for common toolchains under `Cordon::Preset`. Merge one into your policy rather than enumerating paths manually:

```crystal
# Homebrew on Apple Silicon
policy = my_policy.merge(Cordon::Preset::Brew::MACOS_ARM)

# Homebrew on Intel macOS
policy = my_policy.merge(Cordon::Preset::Brew::MACOS_INTEL)

# Homebrew on Linux
policy = my_policy.merge(Cordon::Preset::Brew::LINUX)
```

Presets only add permissions — they never enable network access or override your `working_dir` unless you merge them in that order intentionally.

#### Ruby

Static presets cover known fixed layouts (Homebrew, system packages):

```crystal
policy = my_policy.merge(Cordon::Preset::Ruby::MACOS_ARM_BREW)
policy = my_policy.merge(Cordon::Preset::Ruby::MACOS_INTEL_BREW)
policy = my_policy.merge(Cordon::Preset::Ruby::LINUX_SYSTEM)
policy = my_policy.merge(Cordon::Preset::Ruby::LINUX_BREW)
```

For version-managed rubies (`ruby-install`, `rbenv`, `chruby`, `asdf`), where the install root varies at runtime, derive a policy from the actual binary instead:

```crystal
policy = my_policy.merge(Cordon::Preset::Ruby.for_executable("/path/to/ruby"))
```

`for_executable` resolves symlinks and works for any self-contained Ruby install tree. For shim-based managers, resolve the real binary first — `rbenv which ruby` or `asdf which ruby` — since the shim itself isn't the binary to point at.

All Ruby presets include the default per-user gem directory (`~/.gem`). macOS system Ruby is intentionally not covered — its lib paths depend on the active Xcode/CLT toolchain and aren't stable. See [DEVELOPMENT.md](./DEVELOPMENT.md) for the full rationale.

#### Python

Static presets cover known fixed layouts the same way Ruby's do:

```crystal
policy = my_policy.merge(Cordon::Preset::Python::MACOS_ARM_BREW)
policy = my_policy.merge(Cordon::Preset::Python::MACOS_INTEL_BREW)
policy = my_policy.merge(Cordon::Preset::Python::LINUX_SYSTEM)
policy = my_policy.merge(Cordon::Preset::Python::LINUX_BREW)
```

For version-managed interpreters (`pyenv`, `uv python install`), use `for_executable`, same as Ruby:

```crystal
policy = my_policy.merge(Cordon::Preset::Python.for_executable("/path/to/python3"))
```

Python also has virtual environments, which `uv` and `python -m venv` both create — typically at `.venv` next to a project's `pyproject.toml`. A venv is a thin directory pointing back at a base interpreter rather than containing a full one, so `for_venv` reads its `pyvenv.cfg`, resolves the base interpreter, and grants access to both:

```crystal
policy = my_policy.merge(Cordon::Preset::Python.for_venv("/path/to/project/.venv"))
```

`for_venv` is read-only — it covers running a script against an already-resolved environment, not `pip install` / `uv add`. macOS system Python is excluded for the same reason as Ruby's.

## CLI

> **Note:** The CLI is not yet distributed as a release binary. If you need it today, build from source — see [DEVELOPMENT.md](./DEVELOPMENT.md). A release workflow is planned.

The CLI will supports the following subcommands:

```sh
# Run a command inside a sandbox
cordon run --policy policy.json -- command [args...]

# Run a brew-installed command
cordon run --policy policy.json --add brew -- brew list

# Run a Ruby script, deriving the policy from the active ruby binary
cordon run --ruby $(which ruby) -- ruby script.rb
cordon run --ruby $(rbenv which ruby) -- ruby script.rb
`
# Run a Python script, deriving the policy from the active python3 binary
cordon run --python $(which python3) -- python3 script.py

# Run a Python script inside a project's virtualenv
cordon run --python-venv .venv -- python3 script.py

# Print the native invocation without executing
cordon inspect --policy policy.json [--platform linux|macos]

# Preview the effect of a preset without executing
cordon inspect --policy policy.json --add brew [--platform linux|macos]
cordon inspect --ruby $(which ruby) [--platform linux|macos]
cordon inspect --python-venv .venv [--platform linux|macos]

# Check which sandbox runners are available on this host
cordon check
```

## Development

See [DEVELOPMENT.md](./DEVELOPMENT.md) for how to build, run the specs, and understand the internals.

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _Sandboxer_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
