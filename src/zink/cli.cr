require "option_parser"

module Zink
  class CLI
    def self.run(args : Array(String)) : Int32
      debug = !!(ENV["ZINK_DEBUG"]? == "1")
      max_steps : Int32? = nil
      story_path : String? = nil
      record_actions_path : String? = nil

      exit_code : Int32? = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: zink [options] STORY_FILE.z3"
        opts.separator "Hint: set ZINK_DEBUG=1 for VM trace output"

        opts.on("--debug", "Enable VM trace output") { debug = true }
        opts.on("--max-steps N", "Limit VM execution steps") { |n| max_steps = n.to_i }
        opts.on("--record-actions FILE", "Record player input to a file") { |f| record_actions_path = f }
        opts.on("-h", "--help", "Show this help") do
          STDERR.puts(opts)
          exit_code = 0
        end

        opts.unknown_args do |positional|
          if positional.size > 1
            STDERR.puts("Error: multiple story paths provided")
            STDERR.puts(opts)
            exit_code = 1
          end
          story_path = positional.first?
        end

        opts.invalid_option do |flag|
          STDERR.puts("Error: unknown option '#{flag}'")
          STDERR.puts(opts)
          exit_code = 1
        end

        opts.missing_option do |flag|
          STDERR.puts("Error: #{flag} requires a value")
          STDERR.puts(opts)
          exit_code = 1
        end
      end

      parser.parse(args)
      if code = exit_code
        return code
      end

      unless story_path
        STDERR.puts(parser)
        return 1
      end

      debug_mode = !!debug
      STDERR.puts("Debug mode enabled") if debug_mode

      story = Story.load(story_path.not_nil!)
      if story.header.version != 3_u8
        STDERR.puts("Only Z-machine version 3 is currently supported (got v#{story.header.version}).")
        return 2
      end

      if debug_mode
        STDERR.puts(
          "Loaded story: version=#{story.header.version} entry_pc=0x#{story.entry_pc.to_s(16)} " \
          "static_base=0x#{story.header.static_memory_base.to_s(16)} size=#{story.file_length} bytes"
        )
      end

      base_io = ConsoleIO.new
      recording_io : RecordingIO? = nil
      io : IODevice = base_io
      if path = record_actions_path
        recording_io = RecordingIO.new(base_io, path)
        io = recording_io
        STDERR.puts("Recording player actions to #{path}") if debug_mode
      end

      begin
        vm = VM.new(story, io, debug: debug_mode)
        if limit = max_steps
          vm.run(limit)
        else
          vm.run_unbounded
        end
      ensure
        recording_io.try(&.close)
      end
      0
    rescue ex : Exception
      STDERR.puts("Error: #{ex.message}")
      if debug_mode
        if backtrace = ex.backtrace?
          backtrace.each { |line| STDERR.puts("  #{line}") }
        end
      end
      3
    end
  end
end
