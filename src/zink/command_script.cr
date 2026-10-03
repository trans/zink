module Zink
  # Command files use one line per read or read_char result. Non-printable
  # ZSCII codes and literal '[' are written as decimal codes in brackets.
  class CommandScript
    def initialize(text : String)
      @input = IO::Memory.new(text)
    end

    def read_line : String?
      raw = @input.gets
      return nil unless raw

      String.build do |result|
        decode(raw).each do |code|
          unless code >= 32 && code <= 126
            raise ArgumentError.new("Unsupported ZSCII command character #{code}")
          end
          result << code.chr
        end
      end
    end

    def read_char : Int32?
      raw = @input.gets
      return nil unless raw
      return 13 if raw.empty?

      codes = decode(raw)
      raise ArgumentError.new("Expected one keypress per command-file line") unless codes.size == 1
      codes.first
    end

    def self.encode_line(line : String) : String
      String.build do |result|
        line.each_char { |char| encode_code(result, char.ord) }
        result << '\n'
      end
    end

    def self.encode_char(code : Int32) : String
      return "\n" if code == 13
      String.build do |result|
        encode_code(result, code)
        result << '\n'
      end
    end

    private def self.encode_code(result : String::Builder, code : Int32) : Nil
      if code == '['.ord || code < 32 || code > 126
        result << '[' << code << ']'
      else
        result << code.chr
      end
    end

    private def decode(raw : String) : Array(Int32)
      codes = [] of Int32
      index = 0
      while index < raw.bytesize
        byte = raw.byte_at(index)
        if byte == '['.ord
          ending = raw.index(']', index + 1)
          raise ArgumentError.new("Unclosed ZSCII code in command file") unless ending
          value = raw.byte_slice(index + 1, ending - index - 1).to_i?
          raise ArgumentError.new("Invalid ZSCII code in command file") unless value && value >= 0 && value <= 255
          codes << value
          index = ending + 1
        else
          raise ArgumentError.new("Command file must use ASCII or bracketed ZSCII codes") if byte > 126
          codes << byte.to_i
          index += 1
        end
      end
      codes
    end
  end
end
