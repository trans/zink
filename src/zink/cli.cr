require "option_parser"

module Zink
  class CLI
    def self.run(args : Array(String)) : Int32
      debug = !!(ENV["ZINK_DEBUG"]? == "1")
      max_steps : Int32? = nil
      story_path : String? = nil
      record_actions_path : String? = nil
      playback_commands_path : String? = nil
      dump_worldview = false

      exit_code : Int32? = nil

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: zink [options] STORY_FILE.z3|.z4|.z5"
        opts.separator "Hint: set ZINK_DEBUG=1 for VM trace output"

        opts.on("--debug", "Enable VM trace output") { debug = true }
        opts.on("--max-steps N", "Limit VM execution steps") { |n| max_steps = n.to_i }
        opts.on("--record-actions FILE", "Record player input to a file") { |f| record_actions_path = f }
        opts.on("--playback-commands FILE", "Replay commands from a file") { |f| playback_commands_path = f }
        opts.on("--worldview", "Boot game and dump worldview as JSON") { dump_worldview = true }
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
      unless story.header.version >= 3_u8 && story.header.version <= 5_u8
        STDERR.puts("Only Z-machine versions 3, 4, and 5 are supported (got v#{story.header.version}).")
        return 2
      end

      if debug_mode
        STDERR.puts(
          "Loaded story: version=#{story.header.version} entry_pc=0x#{story.entry_pc.to_s(16)} " \
          "static_base=0x#{story.header.static_memory_base.to_s(16)} size=#{story.file_length} bytes"
        )
      end

      if dump_worldview
        wv_io = ScriptedIO.new(["look"])
        wv_vm = VM.new(story, wv_io, debug: debug_mode)
        wv_vm.run(100_000)
        puts wv_vm.worldview.to_pretty_json
        return 0
      end

      command_script = playback_commands_path.try { |path| File.read(path) }
      base_io = ConsoleIO.new(command_script: command_script)
      recording_io : RecordingIO? = nil
      io : IODevice = base_io
      if path = record_actions_path
        recording_io = RecordingIO.new(base_io, path)
        io = recording_io
        STDERR.puts("Recording player actions to #{path}") if debug_mode
      end

      begin
        vm = VM.new(story, io, debug: debug_mode)
        vm.select_input_stream(1) if command_script
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
