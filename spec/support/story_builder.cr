def write_word(bytes : Bytes, address : Int32, value : UInt16) : Nil
  bytes[address] = ((value >> 8) & 0xff).to_u8
  bytes[address + 1] = (value & 0xff).to_u8
end

# Places small hand-written programs in a complete story image. Existing tests
# can use the lower-level helpers above for object tables and other data.
class SpecStoryBuilder
  getter bytes : Bytes
  getter cursor : Int32

  def initialize(version : UInt8 = 3_u8, static_base : UInt16 = 0x80_u16,
                 dictionary_table : UInt16 = 0x50_u16, size : Int32 = 512)
    @bytes = build_story_bytes(version: version, static_base: static_base,
      dictionary_table: dictionary_table, size: size)
    @cursor = 0x40
  end

  def at(address : Int32) : self
    @cursor = address
    self
  end

  def emit(*values : UInt8) : self
    values.each do |value|
      @bytes[@cursor] = value
      @cursor += 1
    end
    self
  end

  def emit_word(value : UInt16) : self
    emit(((value >> 8) & 0xff).to_u8, (value & 0xff).to_u8)
  end

  def story : Zink::Story
    Zink::Story.from_bytes(@bytes)
  end
end

def write_bytes(bytes : Bytes, address : Int32, data : Bytes) : Nil
  data.each_with_index do |value, index|
    bytes[address + index] = value
  end
end

def zword(a : Int32, b : Int32, c : Int32, last : Bool = true) : UInt16
  packed = ((a & 0x1f) << 10) | ((b & 0x1f) << 5) | (c & 0x1f)
  packed |= 0x8000 if last
  packed.to_u16
end

def build_story_bytes(
  version : UInt8 = 3_u8,
  initial_pc : UInt16 = 0x40_u16,
  static_base : UInt16 = 0x80_u16,
  dictionary_table : UInt16 = 0x50_u16,
  object_table : UInt16 = 0x60_u16,
  globals_table : UInt16 = 0x70_u16,
  size : Int32 = 512,
) : Bytes
  bytes = Bytes.new(size, 0_u8)
  bytes[0x00] = version

  write_word(bytes, 0x04, 0x40_u16) # High memory base
  write_word(bytes, 0x06, initial_pc)
  write_word(bytes, 0x08, dictionary_table)
  write_word(bytes, 0x0a, object_table)
  write_word(bytes, 0x0c, globals_table)
  write_word(bytes, 0x0e, static_base)
  write_word(bytes, 0x18, 0x00_u16) # Abbrev table
  length_unit = version <= 3 ? 2 : version <= 5 ? 4 : 8
  write_word(bytes, 0x1a, (bytes.size // length_unit).to_u16)
  bytes
end

def build_object_story_bytes : Bytes
  bytes = build_story_bytes(
    static_base: 0x0400_u16,
    dictionary_table: 0x0050_u16,
    object_table: 0x0090_u16,
    globals_table: 0x0200_u16,
    size: 2048
  )

  # Property defaults: property 5 defaults to 99 if missing.
  write_word(bytes, 0x0090 + ((5 - 1) * 2), 0x0063_u16)

  object_entries = 0x0090 + 62
  object1 = object_entries
  object2 = object_entries + 9

  # Object 1: parent=2, sibling=0, child=0, attr10 set, property table at 0x120.
  bytes[object1 + 0] = 0x00_u8
  bytes[object1 + 1] = 0x20_u8
  bytes[object1 + 2] = 0x00_u8
  bytes[object1 + 3] = 0x00_u8
  bytes[object1 + 4] = 0x02_u8
  bytes[object1 + 5] = 0x00_u8
  bytes[object1 + 6] = 0x00_u8
  write_word(bytes, object1 + 7, 0x0120_u16)

  # Object 2: parent=0, sibling=0, child=1, property table at 0x140.
  bytes[object2 + 0] = 0x00_u8
  bytes[object2 + 1] = 0x00_u8
  bytes[object2 + 2] = 0x00_u8
  bytes[object2 + 3] = 0x00_u8
  bytes[object2 + 4] = 0x00_u8
  bytes[object2 + 5] = 0x00_u8
  bytes[object2 + 6] = 0x01_u8
  write_word(bytes, object2 + 7, 0x0140_u16)

  # Object 1 properties: prop 5 size 1, prop 3 size 2, prop 2 size 5.
  bytes[0x0120] = 0_u8 # short name words
  bytes[0x0121] = 0x05_u8
  bytes[0x0122] = 0x2a_u8
  bytes[0x0123] = 0x23_u8
  bytes[0x0124] = 0x12_u8
  bytes[0x0125] = 0x34_u8
  bytes[0x0126] = 0x82_u8
  write_bytes(bytes, 0x0127, Bytes[0x12, 0x34, 0x56, 0x78, 0x9a])
  bytes[0x012c] = 0x00_u8

  # Object 2 has no properties.
  bytes[0x0140] = 0_u8
  bytes[0x0141] = 0_u8

  bytes
end

def build_v5_object_story_bytes : Bytes
  bytes = build_story_bytes(
    version: 5_u8,
    object_table: 0x0500_u16,
    globals_table: 0x0300_u16,
    static_base: 0x2500_u16,
    size: 0x3000
  )
  objects_base = 0x0500 + 126
  property_table = objects_base + 260 * 14
  260.times do |index|
    write_word(bytes, objects_base + index * 14 + 12, property_table.to_u16)
  end
  write_word(bytes, objects_base + 6, 256_u16)           # object 1 parent
  bytes[objects_base + 5] = 1_u8                         # attribute 47
  write_word(bytes, objects_base + 255 * 14 + 10, 1_u16) # object 256 child

  bytes[property_table] = 0_u8
  bytes[property_table + 1] = 0x7f_u8 # property 63, two bytes
  write_word(bytes, property_table + 2, 0x1234_u16)
  bytes[property_table + 4] = 0xbe_u8 # property 62, two size bytes
  bytes[property_table + 5] = 0x85_u8 # five data bytes
  write_bytes(bytes, property_table + 6, Bytes[1, 2, 3, 4, 5])
  bytes[property_table + 11] = 0_u8
  bytes
end

def set_story_checksum(bytes : Bytes) : Nil
  checksum = 0_u32
  0x40.upto(bytes.size - 1) do |address|
    checksum += bytes[address].to_u32
  end
  write_word(bytes, 0x1c, (checksum & 0xffff).to_u16)
end
