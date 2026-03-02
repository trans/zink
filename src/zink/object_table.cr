module Zink
  class ObjectTable
    DEFAULT_PROPERTY_COUNT = 31
    ATTRIBUTE_COUNT        = 32
    OBJECT_ENTRY_SIZE      =  9

    def initialize(@memory : Memory, @header : Header)
      if @header.version > 3
        raise RuntimeError.new("Object table parser currently supports versions 1-3 only")
      end
    end

    def parent(object_number : UInt16) : UInt8
      @memory.read_byte(object_entry_address(object_number) + 4)
    end

    def sibling(object_number : UInt16) : UInt8
      @memory.read_byte(object_entry_address(object_number) + 5)
    end

    def child(object_number : UInt16) : UInt8
      @memory.read_byte(object_entry_address(object_number) + 6)
    end

    def set_parent(object_number : UInt16, value : UInt8) : Nil
      @memory.write_byte(object_entry_address(object_number) + 4, value)
    end

    def set_sibling(object_number : UInt16, value : UInt8) : Nil
      @memory.write_byte(object_entry_address(object_number) + 5, value)
    end

    def set_child(object_number : UInt16, value : UInt8) : Nil
      @memory.write_byte(object_entry_address(object_number) + 6, value)
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
      return if current_parent == 0_u8

      current_sibling = sibling(object_number)
      first_child = child(current_parent.to_u16)
      if first_child == object_number.to_u8
        set_child(current_parent.to_u16, current_sibling)
      else
        cursor = first_child
        while cursor != 0_u8
          cursor_sibling = sibling(cursor.to_u16)
          if cursor_sibling == object_number.to_u8
            set_sibling(cursor.to_u16, current_sibling)
            break
          end
          cursor = cursor_sibling
        end
      end

      set_parent(object_number, 0_u8)
      set_sibling(object_number, 0_u8)
    end

    def insert_object(object_number : UInt16, destination_number : UInt16) : Nil
      remove_object(object_number)
      destination_child = child(destination_number)
      set_parent(object_number, destination_number.to_u8)
      set_sibling(object_number, destination_child)
      set_child(destination_number, object_number.to_u8)
    end

    def property_table_address(object_number : UInt16) : UInt16
      @memory.read_word(object_entry_address(object_number) + 7)
    end

    def short_name_word_count(object_number : UInt16) : UInt8
      @memory.read_byte(property_table_address(object_number).to_i)
    end

    def short_name_address(object_number : UInt16) : UInt16
      (property_table_address(object_number) + 1).to_u16
    end

    def property_length(property_data_address : UInt16) : UInt8
      return 0_u8 if property_data_address == 0_u16
      header = @memory.read_byte(property_data_address.to_i - 1)
      ((header >> 5) + 1).to_u8
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

        property_number = (header & 0x1f_u8).to_u8
        size = ((header >> 5) + 1).to_i
        data_address = pointer + 1
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
      objects_base = @header.object_table.to_i + DEFAULT_PROPERTY_COUNT * 2
      objects_base + (object_number.to_i - 1) * OBJECT_ENTRY_SIZE
    end

    private def object_bounds_check(object_number : UInt16) : Nil
      return if object_number >= 1_u16 && object_number <= 255_u16
      raise RuntimeError.new("Invalid object number #{object_number}")
    end

    private def attribute_bounds_check(attribute_number : UInt8) : Nil
      return if attribute_number < ATTRIBUTE_COUNT
      raise RuntimeError.new("Invalid attribute number #{attribute_number}")
    end

    private def property_bounds_check(property_number : UInt8) : Nil
      return if property_number >= 1_u8 && property_number <= DEFAULT_PROPERTY_COUNT
      raise RuntimeError.new("Invalid property number #{property_number}")
    end
  end
end
