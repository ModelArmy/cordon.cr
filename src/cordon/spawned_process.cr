module Cordon
  # The running sandboxed command that Runner#spawn yields. A Process whose
  # #wait may be called more than once: the first call waits, later calls
  # return the same status.
  #
  #   Cordon.spawn(["cat"], policy, input: :pipe, output: :pipe) do |process|
  #     process.input.puts "hello"
  #     process.input.close
  #     process.output.gets # => "hello"
  #     process.wait.success?
  #   end
  class SpawnedProcess < ::Process
    @status : ::Process::Status? = nil

    # Waits for the process to exit, closes its pipes and returns its status.
    def wait : ::Process::Status
      @status ||= super
    end

    # Whether #wait has returned.
    def waited? : Bool
      !@status.nil?
    end
  end
end
