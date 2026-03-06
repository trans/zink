module Zink
  module IODevice
    abstract def write(text : String) : Nil
    abstract def read_line : String?

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

    def initialize(@output : IO = STDOUT, @input : IO = STDIN, width : Int32? = nil)
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

    def initialize(@inputs : Array(String))
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

    def read_line : String?
      line = @inner.read_line
      return nil unless line

      @file << line
      unless line.ends_with?('\n')
        @file << '\n'
      end
      @file.flush
      line
    end

    def close : Nil
      @file.close unless @file.closed?
    end
  end
end
