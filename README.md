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

### Quick start

A few common cases, using each preset's `for_current_platform` convenience method — no need to pick the right platform-specific constant by hand:

**Run a command with no access beyond its own location and a workspace directory:**

```crystal
require "cordon"

policy = Cordon::Policy.build do |policy|
  policy.read_only "/opt/mytools"      # where some-tool lives
  policy.read_write "/tmp/workspace"
end
result = Cordon.run(["/opt/mytools/some-tool", "--flag"], policy)
```

The command's own location must be granted like anything else — see the model paragraph below.

**Run a Homebrew-installed tool:**

```crystal
policy = Cordon::Policy.build(&.read_write("/tmp/workspace"))
  .merge(Cordon::Preset::Brew.for_current_platform)
result = Cordon.run(["jq", ".", "data.json"], policy)
```

**Run a Ruby or Python script:**

```crystal
policy = Cordon::Policy.build(&.read_write("/tmp/workspace"))
  .merge(Cordon::Preset::Ruby.for_current_platform(with_brew: true))
result = Cordon.run(["ruby", "script.rb"], policy)
```

**Let the command shell out** (`system()`/`popen()`, a `#!/bin/sh` line):

```crystal
policy = Cordon::Policy.build(&.read_write("/tmp/workspace"))
  .merge(Cordon::Preset::System.for_current_platform)
```

**The model in one paragraph:** a sandboxed process can only read, write, and exec what its `Policy` explicitly grants. An empty policy denies network and denies every path — including the location of the command you asked Cordon to run. Naming a binary is not authority to run it: the policy defines the perimeter, and a command outside that perimeter is refused rather than admitted. So an empty policy will not let you launch the system's own `ruby`, `sh`, or `python3`, and will not let a command you *did* grant shell out to them either. Presets (`Brew`, `System`, `Ruby`, `Python`) are pre-built `Policy` objects for common cases; merge them in rather than listing paths by hand. `for_current_platform` is a convenience over picking the right platform-specific constant yourself — it raises `UnsupportedPlatformError` rather than silently guessing.

That covers most use cases. The rest of this section goes deeper: building a policy from scratch, exactly what each field grants, and why exec access works the way it does — worth reading before running anything sensitive through Cordon.

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

**Exec follows read access, and nothing is exec-able by default.** A process can exec a binary if it can read it — `read_only_paths`, `read_write_paths`, and `tmpfs_paths` double as the set of paths a sandboxed process may launch programs from. There is no exception for the command Cordon was asked to run: it must be covered by the policy like anything else, or it will not launch. Cordon does **not** grant exec access to standard system directories (`/bin`, `/usr/bin`, etc.) automatically — an empty policy will not let your command shell out to the system's own `ruby`, `python3`, or `sh`, even if it can read the filesystem elsewhere. If your command needs to shell out (`system()`/`popen()`, a `#!/bin/sh` script, spawning another interpreter), merge in `Preset::System` — see [Presets](#presets) below.

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

### Relaunching the current process inside a sandbox

An app can sandbox itself, rather than shelling out to a separate command, by relaunching its own binary inside Cordon:

```crystal
Cordon.relaunch(my_policy)
# only reached once already running inside the sandbox
run_untrusted_code
```

`relaunch` re-executes the current process (via `Process.executable_path` and `ARGV`) inside a sandbox governed by `my_policy`, and does not return on success — the calling process image is replaced, same as `exec(1)`. Call it once, early, before any untrusted code runs.

**Your policy must account for the binary's dependencies, or the relaunched process will fail to start.** `relaunch` merges in a read-only grant for the executable itself, so the binary is always readable and exec-able. It grants nothing else — deliberately, since granting the containing directory would make every sibling binary exec-able inside the cordon. Everything the binary needs at load time is your policy's responsibility:

- **Shared libraries.** System libraries (`/usr/lib`, `/lib`, and on macOS the dyld shared cache) are covered by each runner's baseline. Anything outside that is not. A Crystal binary built on macOS links against Homebrew-supplied libraries such as `pcre2`, `libgc`, and `libevent` under `/opt/homebrew/lib`, so it needs `Preset::Brew` merged in — without it, the relaunched process dies in dyld before `main`.
- **Data files, config, and anything read at startup** — same rule, no special treatment.

Because the failure happens after the process image has been replaced, it surfaces as a loader error or a signal-kill rather than a Cordon exception. Check the policy with `cordon inspect` first, and test relaunch on each platform you ship to:

```crystal
# A self-sandboxing binary that links against Homebrew libraries.
policy = Cordon::Policy.build(&.read_write("/tmp/workspace"))
  .merge(Cordon::Preset::Brew.for_current_platform)

Cordon.relaunch(policy)
```

`relaunch` tracks how many times the process has relaunched itself via an env var (`CORDON_RELAUNCH_DEPTH` by default), so the sandboxed copy doesn't try to relaunch itself again. **This is a re-entrancy guard, not a security boundary** — anything already able to set env vars for the process before Cordon runs could set this var to skip relaunch entirely, but that's equivalent to just invoking the unsandboxed binary directly. All real protection comes from the sandbox applied on the first hop, before any untrusted code has run.

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

#### System

Grants read (and therefore exec) access to `/bin` and `/usr/bin` — the standard system binary directories, deliberately excluded from Cordon's default policy (see the exec note above). Merge this in when your command needs to shell out:

```crystal
policy = my_policy.merge(Cordon::Preset::System::MACOS)   # or ::LINUX
```

Scoped to `/bin` and `/usr/bin` only — `/usr/sbin` and `/sbin` (system administration tools) are excluded, since a sandboxed process has no ordinary reason to reach them. Add them to your own policy with `read_only` if you specifically need something there. Also available via the CLI as `--add system`.

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
