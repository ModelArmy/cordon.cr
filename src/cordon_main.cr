# cordon_main.cr — the actual executable entrypoint for the `cordon` binary.
#
# Deliberately separate from cordon_cli/cordon_cli.cr: that file defines
# Cordon::CLI as a plain module (routing, argument parsing, exit-code
# logic) with no top-level side effects, so it's safe to `require` from
# specs and call `Cordon::CLI.run(argv)` directly in-process — see
# spec/cordon_cli_spec.cr.
#
# If `exit Cordon::CLI.run(ARGV)` lived in cordon_cli.cr itself, any
# spec file requiring that file would trigger a real CLI invocation and
# `exit` as a side effect of `crystal spec` concatenating all spec
# files into one program — which happened, silently truncating the
# suite on some file-ordering outcomes. See DEVELOPMENT.md.
#
# shard.yml's `main:` target points here, not at cordon_cli.cr.
require "./cordon_cli"

exit Cordon::CLI.run(ARGV)
