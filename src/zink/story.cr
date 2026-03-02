module Zink
  class Story
    getter memory : Memory
    getter header : Header
    getter file_length : Int32

    def initialize(@memory : Memory, @header : Header, @file_length : Int32)
    end

    def self.load(path : String) : Story
      from_bytes(File.read(path).to_slice)
    end

    def self.from_bytes(bytes : Bytes) : Story
      preview = Memory.new(bytes)
      header = Header.read(preview)

      write_limit = header.static_memory_base.to_i
      write_limit = bytes.size if write_limit <= 0 || write_limit > bytes.size

      memory = Memory.new(bytes, write_limit: write_limit)
      header = Header.read(memory)
      declared_length = header.file_length_bytes(bytes.size)
      file_length = Math.min(declared_length, bytes.size)

      Story.new(memory, header, file_length)
    end

    def entry_pc : Int32
      @header.initial_pc.to_i
    end

    def checksum_valid? : Bool
      expected = @memory.read_word(0x1c)
      return true if expected == 0_u16

      checksum = 0_u32
      start = 0x40
      finish = Math.min(@file_length, @memory.size)
      start.upto(finish - 1) do |address|
        checksum += @memory.read_byte(address).to_u32
      end

      (checksum & 0xffff).to_u16 == expected
    end
  end
end
