module Zink
  class FormatError < Exception
  end

  struct Header
    getter version : UInt8
    getter high_memory_base : UInt16
    getter initial_pc : UInt16
    getter dictionary_table : UInt16
    getter object_table : UInt16
    getter globals_table : UInt16
    getter static_memory_base : UInt16
    getter abbreviations_table : UInt16
    getter file_length_words : UInt16

    def initialize(
      @version : UInt8,
      @high_memory_base : UInt16,
      @initial_pc : UInt16,
      @dictionary_table : UInt16,
      @object_table : UInt16,
      @globals_table : UInt16,
      @static_memory_base : UInt16,
      @abbreviations_table : UInt16,
      @file_length_words : UInt16,
    )
    end

    def self.read(memory : Memory) : Header
      raise FormatError.new("Story file too small: #{memory.size} bytes") if memory.size < 0x40

      version = memory.read_byte(0x00)
      unless version >= 1 && version <= 8
        raise FormatError.new("Unsupported Z-machine version: #{version}")
      end

      Header.new(
        version: version,
        high_memory_base: memory.read_word(0x04),
        initial_pc: memory.read_word(0x06),
        dictionary_table: memory.read_word(0x08),
        object_table: memory.read_word(0x0a),
        globals_table: memory.read_word(0x0c),
        static_memory_base: memory.read_word(0x0e),
        abbreviations_table: memory.read_word(0x18),
        file_length_words: memory.read_word(0x1a)
      )
    end

    def file_length_multiplier : Int32
      case version
      when 1..3
        2
      when 4..5
        4
      else
        8
      end
    end

    def file_length_bytes(fallback_size : Int32) : Int32
      return fallback_size if file_length_words == 0_u16
      file_length_words.to_i * file_length_multiplier
    end

    def unpack_address(packed_address : UInt16) : Int32
      case version
      when 1..3
        packed_address.to_i * 2
      when 4..5
        packed_address.to_i * 4
      when 8
        packed_address.to_i * 8
      else
        raise FormatError.new("Packed address decoding for v#{version} requires routine/string offsets")
      end
    end
  end
end
