module Zink
  module IODevice
    abstract def write(text : String) : Nil
    abstract def read_line : String?

    def command_script : String?
      nil
    end

    def read_char : Int32?
      line = read_line
      return nil unless line
      line.empty? ? 13 : line[0].ord
    end

    def screen_width : Int32
      80
    end

    def screen_height : Int32
      25
    end

    # Screen operations are optional for transcript-oriented devices.
    def split_window(lines : Int32) : Nil
    end

    def set_window(window : Int32) : Nil
    end

    def erase_window(window : Int32) : Nil
    end

    def erase_line : Nil
    end

    def set_cursor(row : Int32, column : Int32) : Nil
    end

    def cursor : {Int32, Int32}
      {1, 1}
    end

    def set_text_style(style : Int32) : Nil
    end

    def buffer_mode(enabled : Bool) : Nil
    end

    def set_colour(foreground : Int32, background : Int32) : Nil
    end

    def output_text : String
      ""
    end
  end

  class ConsoleIO
    include IODevice

    @output : IO
    @input : IO
    @wrap_width : Int32
    @column : Int32
    @line_start : Bool
    @skip_space_after_prompt : Bool

    def initialize(@output : IO = STDOUT, @input : IO = STDIN, width : Int32? = nil, @command_script : String? = nil)
      @wrap_width = normalize_width(width || ENV["COLUMNS"]?.try(&.to_i?) || 80)
      @column = 0
      @line_start = true
      @skip_space_after_prompt = false
    end

    def write(text : String) : Nil
      rendered = String::Builder.new
      word = String::Builder.new

      text.each_char do |char|
        if @skip_space_after_prompt && char == ' '
          @skip_space_after_prompt = false
          next
        end
        @skip_space_after_prompt = false

        case char
        when '\r'
          next
        when '\n'
          emit_word(rendered, word.to_s)
          word = String::Builder.new
          rendered << '\n'
          @column = 0
          @line_start = true
        else
          if @line_start && char == '>'
            emit_word(rendered, word.to_s)
            word = String::Builder.new
            rendered << "> "
            @column += 2
            @line_start = false
            @skip_space_after_prompt = true
          elsif char.whitespace?
            emit_word(rendered, word.to_s)
            word = String::Builder.new
            emit_space(rendered)
          else
            word << char
          end
        end
      end

      emit_word(rendered, word.to_s)
      @output << rendered.to_s
    end

    def read_line : String?
      @input.gets
    end

    def command_script : String?
      return @command_script if @command_script

      write("\nCommand file to replay (blank to cancel): ")
      path = @input.gets
      return nil if path.nil? || path.empty?
      File.read(path)
    rescue ex : File::Error
      write("\nCannot open command file: #{ex.message}\n")
      nil
    end

    def screen_width : Int32
      @wrap_width
    end

    def screen_height : Int32
      (ENV["LINES"]?.try(&.to_i?) || 25).clamp(1, 255)
    end

    private def emit_word(builder : String::Builder, word : String) : Nil
      return if word.empty?

      if @column > 0 && (@column + word.size > @wrap_width)
        builder << '\n'
        @column = 0
        @line_start = true
      end

      builder << word
      @column += word.size
      @line_start = false
    end

    private def emit_space(builder : String::Builder) : Nil
      return if @line_start

      if @column + 1 > @wrap_width
        builder << '\n'
        @column = 0
        @line_start = true
      else
        builder << ' '
        @column += 1
      end
    end

    private def normalize_width(width : Int32) : Int32
      return 1 if width < 1
      width
    end
  end

  class BufferIO
    include IODevice

    def initialize
      @output = ""
    end

    def write(text : String) : Nil
      @output += text
    end

    def read_line : String?
      nil
    end

    def output_text : String
      @output
    end

    def to_s : String
      @output
    end
  end

  class ScriptedIO
    include IODevice

    getter command_script : String?

    def initialize(@inputs : Array(String), @command_script : String? = nil)
      @output = ""
    end

    def write(text : String) : Nil
      @output += text
    end

    def read_line : String?
      return nil if @inputs.empty?
      @inputs.shift
    end

    def output_text : String
      @output
    end

    def to_s : String
      @output
    end
  end

  class RecordingIO
    include IODevice

    def initialize(@inner : IODevice, path : String)
      @file = File.new(path, "w")
    end

    def write(text : String) : Nil
      @inner.write(text)
    end

    def command_script : String?
      @inner.command_script
    end

    def read_line : String?
      line = @inner.read_line
      return nil unless line

      @file << CommandScript.encode_line(line)
      @file.flush
      line
    end

    def read_char : Int32?
      char = @inner.read_char
      return nil unless char

      @file << CommandScript.encode_char(char)
      @file.flush
      char
    end

    def close : Nil
      @file.close unless @file.closed?
    end
  end
end
