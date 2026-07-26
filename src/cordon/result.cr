module Cordon
  # Result of a sandboxed command execution.
  struct Result
    getter exit_code : Int32
    getter stdout : String
    getter stderr : String

    def initialize(@exit_code : Int32, @stdout : String, @stderr : String)
    end

    def success? : Bool
      @exit_code == 0
    end

    def to_s(io : IO) : Nil
      io << "#<Cordon::Result exit_code=#{@exit_code} " \
            "stdout=#{@stdout.bytesize}b stderr=#{@stderr.bytesize}b>"
    end
  end
end
