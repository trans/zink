module Zink
  class Memory
    getter bytes : Bytes
    getter write_limit : Int32

    def initialize(source : Bytes, @write_limit : Int32 = source.size)
      @bytes = Bytes.new(source.size)
      source.copy_to(@bytes)
    end

    def size : Int32
      @bytes.size
    end

    def read_byte(address : Int) : UInt8
      bounds_check(address)
      @bytes[address]
    end

    def read_word(address : Int) : UInt16
      high = read_byte(address).to_u16
      low = read_byte(address + 1).to_u16
      (high << 8) | low
    end

    def write_byte(address : Int, value : UInt8) : Nil
      bounds_check_write(address)
      @bytes[address] = value
    end

    def write_word(address : Int, value : UInt16) : Nil
      write_byte(address, ((value >> 8) & 0xff).to_u8)
      write_byte(address + 1, (value & 0xff).to_u8)
    end

    private def bounds_check(address : Int) : Nil
      return if address >= 0 && address < size
      raise IndexError.new("Address out of range: 0x#{address.to_s(16)}")
    end

    private def bounds_check_write(address : Int) : Nil
      bounds_check(address)
      return if address < @write_limit
      raise RuntimeError.new("Write to static memory at 0x#{address.to_s(16)}")
    end
  end
end
