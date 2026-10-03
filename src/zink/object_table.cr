module Zink
  class ObjectTable
    @object_count : Int32

    def initialize(@memory : Memory, @header : Header)
      @object_count = count_initial_objects
    end

    def object_count : Int32
      @object_count
    end

    def default_property_count : Int32
      @header.version <= 3 ? 31 : 63
    end

    def attribute_count : Int32
      @header.version <= 3 ? 32 : 48
    end

    def object_entry_size : Int32
      @header.version <= 3 ? 9 : 14
    end

    def parent(object_number : UInt16) : UInt16
      read_link(object_number, 0)
    end

    def sibling(object_number : UInt16) : UInt16
      read_link(object_number, 1)
    end

    def child(object_number : UInt16) : UInt16
      read_link(object_number, 2)
    end

    def set_parent(object_number : UInt16, value : UInt16) : Nil
      write_link(object_number, 0, value)
    end

    def set_sibling(object_number : UInt16, value : UInt16) : Nil
      write_link(object_number, 1, value)
    end

    def set_child(object_number : UInt16, value : UInt16) : Nil
      write_link(object_number, 2, value)
    end

    def test_attribute(object_number : UInt16, attribute_number : UInt8) : Bool
      attribute_bounds_check(attribute_number)
      byte_index = attribute_number // 8
      bit = 7 - (attribute_number % 8)
      byte = @memory.read_byte(object_entry_address(object_number) + byte_index)
      (byte & (1_u8 << bit)) != 0
    end

    def set_attribute(object_number : UInt16, attribute_number : UInt8) : Nil
      attribute_bounds_check(attribute_number)
      byte_index = attribute_number // 8
      bit = 7 - (attribute_number % 8)
      address = object_entry_address(object_number) + byte_index
      byte = @memory.read_byte(address)
      @memory.write_byte(address, byte | (1_u8 << bit))
    end

    def clear_attribute(object_number : UInt16, attribute_number : UInt8) : Nil
      attribute_bounds_check(attribute_number)
      byte_index = attribute_number // 8
      bit = 7 - (attribute_number % 8)
      address = object_entry_address(object_number) + byte_index
      byte = @memory.read_byte(address)
      @memory.write_byte(address, byte & ~(1_u8 << bit))
    end

    def remove_object(object_number : UInt16) : Nil
      current_parent = parent(object_number)
      return if current_parent == 0_u16

      current_sibling = sibling(object_number)
      first_child = child(current_parent)
      if first_child == object_number
        set_child(current_parent, current_sibling)
      else
        cursor = first_child
        while cursor != 0_u16
          cursor_sibling = sibling(cursor)
          if cursor_sibling == object_number
            set_sibling(cursor, current_sibling)
            break
          end
          cursor = cursor_sibling
        end
      end

      set_parent(object_number, 0_u16)
      set_sibling(object_number, 0_u16)
    end

    def insert_object(object_number : UInt16, destination_number : UInt16) : Nil
      remove_object(object_number)
      destination_child = child(destination_number)
      set_parent(object_number, destination_number)
      set_sibling(object_number, destination_child)
      set_child(destination_number, object_number)
    end

    def property_table_address(object_number : UInt16) : UInt16
      offset = @header.version <= 3 ? 7 : 12
      @memory.read_word(object_entry_address(object_number) + offset)
    end

    def short_name_word_count(object_number : UInt16) : UInt8
      @memory.read_byte(property_table_address(object_number).to_i)
    end

    def short_name_address(object_number : UInt16) : UInt16
      (property_table_address(object_number) + 1).to_u16
    end

    def children(object_number : UInt16) : Array(UInt16)
      result = [] of UInt16
      cursor = child(object_number)
      while cursor != 0_u16
        result << cursor
        cursor = sibling(cursor)
      end
      result
    end

    def active_attributes(object_number : UInt16) : Array(UInt8)
      result = [] of UInt8
      attribute_count.times do |i|
        result << i.to_u8 if test_attribute(object_number, i.to_u8)
      end
      result
    end

    def all_properties(object_number : UInt16) : Hash(UInt8, UInt16)
      result = {} of UInt8 => UInt16
      property_entries(object_number).each do |number, size, data_address|
        value = if size == 1
                  @memory.read_byte(data_address).to_u16
                else
                  @memory.read_word(data_address)
                end
        result[number] = value
      end
      result
    end

    # Return every byte of each property, including values longer than a word.
    def all_property_bytes(object_number : UInt16) : Hash(UInt8, Array(UInt8))
      result = {} of UInt8 => Array(UInt8)
      property_entries(object_number).each do |number, size, data_address|
        result[number] = Array.new(size) { |offset| @memory.read_byte(data_address + offset) }
      end
      result
    end

    # Keep the initial count: a game may later change an object's property pointer.
    private def count_initial_objects : Int32
      objects_base = @header.object_table.to_i + default_property_count * 2
      first_property_table = @memory.size
      count = 0

      maximum = @header.version <= 3 ? 255 : 65535
      maximum.times do |index|
        number = index + 1
        entry_address = objects_base + index * object_entry_size
        break if entry_address + object_entry_size > first_property_table

        property_offset = @header.version <= 3 ? 7 : 12
        property_address = @memory.read_word(entry_address + property_offset).to_i
        break if property_address == 0
        if property_address < entry_address + object_entry_size || property_address >= @memory.size
          raise FormatError.new("Invalid property table address for object #{number}: 0x#{property_address.to_s(16)}")
        end

        first_property_table = Math.min(first_property_table, property_address)
        count += 1
      end

      count
    end

    def property_length(property_data_address : UInt16) : UInt8
      return 0_u8 if property_data_address == 0_u16
      header = @memory.read_byte(property_data_address.to_i - 1)
      return ((header >> 5) + 1).to_u8 if @header.version <= 3

      if (header & 0x80_u8) != 0
        size = header & 0x3f_u8
        size == 0_u8 ? 64_u8 : size
      else
        (header & 0x40_u8) == 0 ? 1_u8 : 2_u8
      end
    end

    def get_property(object_number : UInt16, property_number : UInt8) : UInt16
      property_bounds_check(property_number)
      location = find_property(object_number, property_number)
      unless location
        return default_property(property_number)
      end

      _, size, data_address = location
      if size == 1
        @memory.read_byte(data_address).to_u16
      else
        @memory.read_word(data_address)
      end
    end

    def get_property_address(object_number : UInt16, property_number : UInt8) : UInt16
      property_bounds_check(property_number)
      location = find_property(object_number, property_number)
      return 0_u16 unless location

      _, _, data_address = location
      data_address.to_u16
    end

    def get_next_property_number(object_number : UInt16, property_number : UInt8) : UInt8
      property_bounds_check(property_number) unless property_number == 0_u8

      entries = property_entries(object_number)
      return 0_u8 if entries.empty?

      if property_number == 0_u8
        return entries.first[0]
      end

      entries.each_with_index do |entry, index|
        number, _, _ = entry
        next unless number == property_number

        return 0_u8 if index + 1 >= entries.size
        return entries[index + 1][0]
      end

      raise RuntimeError.new("Property #{property_number} not found on object #{object_number}")
    end

    def put_property(object_number : UInt16, property_number : UInt8, value : UInt16) : Nil
      property_bounds_check(property_number)
      location = find_property(object_number, property_number)
      raise RuntimeError.new("Property #{property_number} not found on object #{object_number}") unless location

      _, size, data_address = location
      case size
      when 1
        @memory.write_byte(data_address, (value & 0xff).to_u8)
      when 2
        @memory.write_word(data_address, value)
      else
        raise RuntimeError.new("put_prop supports only size 1 or 2 (property #{property_number} has size #{size})")
      end
    end

    private def default_property(property_number : UInt8) : UInt16
      defaults_address = @header.object_table.to_i
      @memory.read_word(defaults_address + (property_number.to_i - 1) * 2)
    end

    private def property_entries(object_number : UInt16) : Array(Tuple(UInt8, Int32, Int32))
      entries = [] of Tuple(UInt8, Int32, Int32)
      pointer = first_property_entry_address(object_number)

      loop do
        header = @memory.read_byte(pointer)
        break if header == 0_u8

        if @header.version <= 3
          property_number = (header & 0x1f_u8).to_u8
          size = ((header >> 5) + 1).to_i
          data_address = pointer + 1
        else
          property_number = (header & 0x3f_u8).to_u8
          if (header & 0x80_u8) != 0
            size_byte = @memory.read_byte(pointer + 1)
            size = (size_byte & 0x3f_u8).to_i
            size = 64 if size == 0
            data_address = pointer + 2
          else
            size = (header & 0x40_u8) == 0 ? 1 : 2
            data_address = pointer + 1
          end
        end
        entries << {property_number, size, data_address}
        pointer = data_address + size
      end

      entries
    end

    private def find_property(object_number : UInt16, property_number : UInt8) : Tuple(UInt8, Int32, Int32)?
      property_entries(object_number).each do |entry|
        number, _, _ = entry
        return entry if number == property_number
        break if number < property_number
      end
      nil
    end

    private def first_property_entry_address(object_number : UInt16) : Int32
      table = property_table_address(object_number).to_i
      name_words = @memory.read_byte(table).to_i
      table + 1 + (name_words * 2)
    end

    private def object_entry_address(object_number : UInt16) : Int32
      object_bounds_check(object_number)
      objects_base = @header.object_table.to_i + default_property_count * 2
      objects_base + (object_number.to_i - 1) * object_entry_size
    end

    private def object_bounds_check(object_number : UInt16) : Nil
      maximum = @header.version <= 3 ? 255_u16 : 65535_u16
      return if object_number >= 1_u16 && object_number <= maximum
      raise RuntimeError.new("Invalid object number #{object_number}")
    end

    private def attribute_bounds_check(attribute_number : UInt8) : Nil
      return if attribute_number < attribute_count
      raise RuntimeError.new("Invalid attribute number #{attribute_number}")
    end

    private def property_bounds_check(property_number : UInt8) : Nil
      return if property_number >= 1_u8 && property_number <= default_property_count
      raise RuntimeError.new("Invalid property number #{property_number}")
    end

    private def read_link(object_number : UInt16, index : Int32) : UInt16
      address = object_entry_address(object_number) + (@header.version <= 3 ? 4 + index : 6 + 2 * index)
      @header.version <= 3 ? @memory.read_byte(address).to_u16 : @memory.read_word(address)
    end

    private def write_link(object_number : UInt16, index : Int32, value : UInt16) : Nil
      address = object_entry_address(object_number) + (@header.version <= 3 ? 4 + index : 6 + 2 * index)
      if @header.version <= 3
        raise RuntimeError.new("Invalid v3 object link #{value}") if value > 255_u16
        @memory.write_byte(address, value.to_u8)
      else
        @memory.write_word(address, value)
      end
    end
  end
end
