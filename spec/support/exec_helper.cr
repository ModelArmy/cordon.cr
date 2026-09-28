require "../../src/cordon"

# Test program for the Windows #exec and #relaunch specs in
# spec/cordon/windows_mxc_spec.cr, which a spec cannot exercise in its own
# process. Build it statically, so a relaunch needs no DLLs beside it:
#
#   crystal build spec/support/exec_helper.cr --static -o exec-helper.exe
#
# Modes (*dir* is a scratch directory the sandbox may read and write):
#
#   exec-helper exec DIR               Mxc#exec on cmd.exe, which prints
#                                      "exec-helper-output" and exits 7.
#   exec-helper relaunch TARGET DIR    Cordon.relaunch, then, inside the
#                                      sandbox, prints the relaunch depth,
#                                      tries to read TARGET (outside the
#                                      policy), reports the result and
#                                      exits 3.

def scratch_policy(dir : String) : Cordon::Policy
  Cordon::Policy.build do |p|
    p.read_write dir
    p.working_dir = dir
  end
end

case ARGV[0]?
when "exec"
  command = ["cmd.exe", "/d", "/c", "echo", "exec-helper-output&", "exit", "7"]
  Cordon::Mxc.new.exec(command, scratch_policy(ARGV[1]))
when "relaunch"
  Cordon.relaunch(scratch_policy(ARGV[2]))

  puts "relaunched depth=#{ENV[Cordon::RELAUNCH_DEPTH_ENV]?}"
  begin
    File.read(ARGV[1])
    puts "outside read: allowed"
  rescue File::Error
    puts "outside read: denied"
  end
  exit 3
else
  STDERR.puts "usage: exec-helper exec DIR | exec-helper relaunch TARGET DIR"
  exit 2
end
