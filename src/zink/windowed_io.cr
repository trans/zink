module Zink
  # Presents the two Z-machine text windows on a linear output device.
  # Upper-window updates are collected into rows and emitted when the game
  # returns to the lower window or waits for input.
  class WindowedIO
    include IODevice

    @upper : Array(Array(Char))
    @selected : Int32
    @upper_row : Int32
    @upper_column : Int32
    @lower_row : Int32
    @lower_column : Int32
    @dirty : Bool

    def initialize(@inner : IODevice)
      @upper = [] of Array(Char)
      @selected = 0
      @upper_row = 1
      @upper_column = 1
      @lower_row = 1
      @lower_column = 1
      @dirty = false
    end

    def screen_width : Int32
      @inner.screen_width
    end

    def screen_height : Int32
      @inner.screen_height
    end

    def output_text : String
      @inner.output_text
    end

    def command_script : String?
      @inner.command_script
    end

    def write(text : String) : Nil
      if @selected == 0
        @inner.write(text)
        text.each_char do |char|
          if char == '\n'
            @lower_row += 1
            @lower_column = 1
          else
            @lower_column += 1
          end
        end
        return
      end

      text.each_char do |char|
        if char == '\n'
          @upper_row += 1
          @upper_column = 1
        elsif @upper_row <= @upper.size && @upper_column <= screen_width
          @upper[@upper_row - 1][@upper_column - 1] = char
          @upper_column += 1
          @dirty = true
        end
      end
    end

    def read_line : String?
      flush_upper
      @inner.read_line
    end

    def read_char : Int32?
      flush_upper
      @inner.read_char
    end

    def split_window(lines : Int32) : Nil
      height = lines.clamp(0, screen_height)
      width = screen_width
      previous = @upper
      @upper = Array.new(height) do |row|
        Array.new(width) { |column| previous[row]?.try(&.[column]?) || ' ' }
      end
      @upper_row = @upper_row.clamp(1, Math.max(height, 1))
      @upper_column = @upper_column.clamp(1, width)
    end

    def set_window(window : Int32) : Nil
      raise ArgumentError.new("Invalid Z-machine window #{window}") unless window == 0 || window == 1
      flush_upper if window == 0
      @selected = window
      if window == 1
        @upper_row = 1
        @upper_column = 1
      end
    end

    def erase_window(window : Int32) : Nil
      case window
      when -1
        @upper.clear
        @selected = 0
      when -2, 1
        @upper.each(&.fill(' '))
        @dirty = false
      when 0
        nil
      else
        raise ArgumentError.new("Invalid Z-machine window #{window}")
      end
      @upper_row = 1
      @upper_column = 1
    end

    def erase_line : Nil
      return unless @selected == 1 && @upper_row <= @upper.size
      (@upper_column - 1).upto(screen_width - 1) do |column|
        @upper[@upper_row - 1][column] = ' '
      end
      @dirty = true
    end

    def set_cursor(row : Int32, column : Int32) : Nil
      return unless @selected == 1
      @upper_row = row.clamp(1, Math.max(@upper.size, 1))
      @upper_column = column.clamp(1, screen_width)
    end

    def cursor : {Int32, Int32}
      @selected == 1 ? {@upper_row, @upper_column} : {@lower_row, @lower_column}
    end

    private def flush_upper : Nil
      return unless @dirty

      lines = @upper.map { |row| String.build { |io| row.each { |char| io << char } }.rstrip }
      lines.reject!(&.empty?)
      @inner.write(lines.join("\n") + "\n") unless lines.empty?
      @dirty = false
    end
  end
end
