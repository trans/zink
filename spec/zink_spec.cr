require "./spec_helper"

private def write_word(bytes : Bytes, address : Int32, value : UInt16) : Nil
  bytes[address] = ((value >> 8) & 0xff).to_u8
  bytes[address + 1] = (value & 0xff).to_u8
end

private def write_bytes(bytes : Bytes, address : Int32, data : Bytes) : Nil
  data.each_with_index do |value, index|
    bytes[address + index] = value
  end
end

private def zword(a : Int32, b : Int32, c : Int32, last : Bool = true) : UInt16
  packed = ((a & 0x1f) << 10) | ((b & 0x1f) << 5) | (c & 0x1f)
  packed |= 0x8000 if last
  packed.to_u16
end

private def build_story_bytes(
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

private def build_object_story_bytes : Bytes
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

private def build_v5_object_story_bytes : Bytes
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

private def set_story_checksum(bytes : Bytes) : Nil
  checksum = 0_u32
  0x40.upto(bytes.size - 1) do |address|
    checksum += bytes[address].to_u32
  end
  write_word(bytes, 0x1c, (checksum & 0xffff).to_u16)
end

describe Zink::Header do
  it "parses header fields and version-3 packed addresses" do
    story = Zink::Story.from_bytes(build_story_bytes)
    header = story.header

    header.version.should eq(3_u8)
    header.initial_pc.should eq(0x40_u16)
    header.static_memory_base.should eq(0x80_u16)
    header.unpack_address(0x1234_u16).should eq(0x2468)
  end
end

describe Zink::Memory do
  it "enforces writes only in dynamic memory" do
    story = Zink::Story.from_bytes(build_story_bytes(static_base: 0x50_u16))
    memory = story.memory

    memory.write_byte(0x10, 0xaa_u8)
    memory.read_byte(0x10).should eq(0xaa_u8)

    expect_raises(RuntimeError, /static memory/) do
      memory.write_byte(0x90, 0x01_u8)
    end

    before = memory.read_byte(0x4f)
    expect_raises(RuntimeError, /static memory/) do
      memory.write_word(0x4f, 0xbeef_u16)
    end
    memory.read_byte(0x4f).should eq(before)
  end
end

describe Zink::RecordingIO do
  it "records read input lines to a file" do
    path = "/tmp/zink-actions-#{Process.pid}-#{Random.rand(1_000_000)}.txt"

    begin
      inner = Zink::ScriptedIO.new(["look", "south"])
      recorder = Zink::RecordingIO.new(inner, path)

      recorder.read_line.should eq("look")
      recorder.read_line.should eq("south")
      recorder.read_line.should be_nil
      recorder.close

      File.read(path).should eq("look\nsouth\n")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe Zink::ConsoleIO do
  it "adds a trailing space after prompt character" do
    output = IO::Memory.new
    io = Zink::ConsoleIO.new(output: output, input: IO::Memory.new(""), width: 80)

    io.write(">")
    output.to_s.should eq("> ")
  end

  it "does not duplicate existing prompt spacing" do
    output = IO::Memory.new
    io = Zink::ConsoleIO.new(output: output, input: IO::Memory.new(""), width: 80)

    io.write("> look")
    output.to_s.should eq("> look")
  end

  it "soft-wraps long lines at configured width" do
    output = IO::Memory.new
    io = Zink::ConsoleIO.new(output: output, input: IO::Memory.new(""), width: 10)

    io.write("alpha beta gamma")
    output.to_s.should eq("alpha beta\ngamma")
  end
end

describe Zink::TextDecoder do
  it "decodes basic alphabet-0 z-characters" do
    story = Zink::Story.from_bytes(build_story_bytes)
    memory = story.memory

    # Encodes "go "
    write_word(memory.bytes, 0x40, zword(12, 20, 0))
    decoder = Zink::TextDecoder.new(memory, story.header)
    text, next_pc = decoder.decode_zstring_at(0x40)

    text.should eq("go ")
    next_pc.should eq(0x42)
  end

  it "decodes A2 newline character" do
    story = Zink::Story.from_bytes(build_story_bytes)
    memory = story.memory

    # Shift to A2 then emit zchar 7 (newline), then space.
    write_word(memory.bytes, 0x42, zword(5, 7, 0))
    decoder = Zink::TextDecoder.new(memory, story.header)
    text, _next_pc = decoder.decode_zstring_at(0x42)

    text.should eq("\n ")
  end

  it "uses word addresses for abbreviations in v5" do
    bytes = build_story_bytes(version: 5_u8)
    write_word(bytes, 0x18, 0x0100_u16)
    write_word(bytes, 0x0100, 0x0090_u16)       # word address -> byte address 0x120
    write_word(bytes, 0x0120, zword(13, 14, 0)) # "hi "
    write_word(bytes, 0x40, zword(1, 0, 0))     # abbreviation 0, then space

    story = Zink::Story.from_bytes(bytes)
    text, _ = Zink::TextDecoder.new(story.memory, story.header).decode_zstring_at(0x40)
    text.should eq("hi  ")
  end

  it "uses the v5 custom alphabet table when present" do
    bytes = build_story_bytes(version: 5_u8)
    write_word(bytes, 0x34, 0x0100_u16)
    bytes[0x0100] = 'x'.ord.to_u8 # A0 zchar 6
    write_word(bytes, 0x40, zword(6, 0, 0))

    story = Zink::Story.from_bytes(bytes)
    text, _ = Zink::TextDecoder.new(story.memory, story.header).decode_zstring_at(0x40)
    text.should eq("x  ")
  end
end

describe Zink::Parser do
  it "writes v5 input length and v5 token positions" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x80] = 20_u8
    bytes[0xa0] = 4_u8
    story = Zink::Story.from_bytes(bytes)
    Zink::Parser.new(story.memory, story.header).read_into_buffers("look", 0x80_u16, 0xa0_u16)

    story.memory.read_byte(0x81).should eq(4_u8)
    String.new(story.memory.bytes[0x82, 4]).should eq("look")
    story.memory.read_byte(0xa1).should eq(1_u8)
    story.memory.read_byte(0xa5).should eq(2_u8)
  end

  it "continues preloaded v5 input before tokenising" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x80] = 20_u8
    bytes[0x81] = 3_u8
    write_bytes(bytes, 0x82, "ope".to_slice)
    bytes[0xa0] = 4_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::Parser.new(story.memory, story.header).read_into_buffers("n", 0x80_u16, 0xa0_u16)
    story.memory.read_byte(0x81).should eq(4_u8)
    String.new(story.memory.bytes[0x82, 4]).should eq("open")
    story.memory.read_byte(0xa5).should eq(2_u8)
    story.memory.read_byte(0xa4).should eq(4_u8)
  end

  it "encodes dictionary keys with a v5 custom alphabet" do
    bytes = build_story_bytes(version: 5_u8)
    write_word(bytes, 0x34, 0x0100_u16)
    bytes[0x0100] = 'x'.ord.to_u8
    story = Zink::Story.from_bytes(bytes)
    encoded = Zink::Parser.new(story.memory, story.header).encode_dictionary_key("x")
    encoded[0].should eq(((zword(6, 5, 5, false) >> 8) & 0xff).to_u8)
  end
end

describe Zink::WindowedIO do
  it "renders upper-window rows when returning to the story window" do
    inner = Zink::BufferIO.new
    screen = Zink::WindowedIO.new(inner)
    screen.split_window(2)
    screen.set_window(1)
    screen.set_cursor(1, 1)
    screen.write("Status")
    screen.set_cursor(2, 3)
    screen.write("Menu")
    screen.set_window(0)
    screen.write("Story")

    inner.to_s.should eq("Status\n  Menu\nStory")
  end
end

describe Zink::ObjectTable do
  it "supports tree, attributes, and properties for v3 objects" do
    story = Zink::Story.from_bytes(build_object_story_bytes)
    objects = Zink::ObjectTable.new(story.memory, story.header)

    objects.parent(1_u16).should eq(2_u8)
    objects.child(2_u16).should eq(1_u8)
    objects.test_attribute(1_u16, 10_u8).should be_true

    objects.get_property(1_u16, 5_u8).should eq(42_u16)
    objects.get_property(1_u16, 3_u8).should eq(0x1234_u16)
    objects.get_property(1_u16, 2_u8).should eq(0x1234_u16)
    objects.get_property(1_u16, 7_u8).should eq(0_u16)

    objects.all_property_bytes(1_u16)[2_u8].should eq([0x12_u8, 0x34_u8, 0x56_u8, 0x78_u8, 0x9a_u8])
    objects.all_property_bytes(1_u16)[5_u8].should eq([0x2a_u8])
    objects.object_count.should eq(2)

    prop5_addr = objects.get_property_address(1_u16, 5_u8)
    prop3_addr = objects.get_property_address(1_u16, 3_u8)
    objects.property_length(prop5_addr).should eq(1_u8)
    objects.property_length(prop3_addr).should eq(2_u8)

    objects.get_next_property_number(1_u16, 0_u8).should eq(5_u8)
    objects.get_next_property_number(1_u16, 5_u8).should eq(3_u8)
    objects.get_next_property_number(1_u16, 3_u8).should eq(2_u8)
    objects.get_next_property_number(1_u16, 2_u8).should eq(0_u8)

    objects.remove_object(1_u16)
    objects.parent(1_u16).should eq(0_u8)
    objects.child(2_u16).should eq(0_u8)

    objects.insert_object(1_u16, 2_u16)
    objects.parent(1_u16).should eq(2_u8)
    objects.child(2_u16).should eq(1_u8)

    objects.put_property(1_u16, 5_u8, 7_u16)
    objects.get_property(1_u16, 5_u8).should eq(7_u16)
  end

  it "reads v5 objects, wide links, attributes, and property sizes" do
    story = Zink::Story.from_bytes(build_v5_object_story_bytes)
    objects = Zink::ObjectTable.new(story.memory, story.header)
    objects.object_count.should eq(260)
    objects.parent(1_u16).should eq(256_u16)
    objects.child(256_u16).should eq(1_u16)
    objects.test_attribute(1_u16, 47_u8).should be_true
    objects.get_property(1_u16, 63_u8).should eq(0x1234_u16)
    objects.get_property(1_u16, 62_u8).should eq(0x0102_u16)
    objects.all_property_bytes(1_u16)[62_u8].should eq([1_u8, 2_u8, 3_u8, 4_u8, 5_u8])
    address = objects.get_property_address(1_u16, 62_u8)
    objects.property_length(address).should eq(5_u8)

    view = Zink::VM.new(story).worldview
    view.objects.size.should eq(260)
    view.location.should eq(0_u16)
  end

  it "uses the wide object layout in v4" do
    bytes = build_v5_object_story_bytes
    bytes[0] = 4_u8
    story = Zink::Story.from_bytes(bytes)
    objects = Zink::ObjectTable.new(story.memory, story.header)
    objects.object_count.should eq(260)
    objects.parent(1_u16).should eq(256_u16)
    objects.property_length(objects.get_property_address(1_u16, 62_u8)).should eq(5_u8)
  end
end

describe "object table boundary" do
  it "stops at the first property table even when property data resembles an object" do
    bytes = build_object_story_bytes
    first_entry = 0x0090 + 62
    first_property_table = first_entry + 2 * 9
    write_word(bytes, first_entry + 7, first_property_table.to_u16)
    write_word(bytes, first_entry + 9 + 7, 0x0140_u16)
    bytes[first_property_table] = 0_u8
    bytes[first_property_table + 1] = 0_u8
    write_word(bytes, first_property_table + 7, 0x0150_u16)

    story = Zink::Story.from_bytes(bytes)
    objects = Zink::ObjectTable.new(story.memory, story.header)
    objects.object_count.should eq(2)

    wv = Zink::VM.new(story).worldview
    wv.objects.map(&.number).should eq([1_u16, 2_u16])
  end
end

describe Zink::Worldview do
  it "captures object tree, location, and JSON output" do
    bytes = build_object_story_bytes

    # Set global 0 (location) to object 2 via a store then quit.
    bytes[0x40] = 0x0d_u8 # store
    bytes[0x41] = 0x10_u8 # global 0
    bytes[0x42] = 0x02_u8 # value 2
    bytes[0x43] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)
    vm.run

    wv = vm.worldview
    wv.location.should eq(2_u16)

    obj1 = wv[1_u16]
    obj1.should_not be_nil
    obj1 = obj1.not_nil!
    obj1.parent.should eq(2_u16)
    obj1.children.should be_empty
    obj1.attributes.should contain(10_u8)
    obj1.properties[5_u8].should eq(42_u16)
    obj1.properties[3_u8].should eq(0x1234_u16)
    obj1.property_bytes[2_u8].should eq([0x12_u8, 0x34_u8, 0x56_u8, 0x78_u8, 0x9a_u8])
    obj1.property_bytes[3_u8].should eq([0x12_u8, 0x34_u8])
    wv.globals[16_u8].should eq(2_u16)
    wv.globals.size.should eq(240)
    vm.global(16_u8).should eq(2_u16)
    expect_raises(ArgumentError) { vm.global(15_u8) }

    obj2 = wv[2_u16]
    obj2.should_not be_nil
    obj2 = obj2.not_nil!
    obj2.parent.should eq(0_u16)
    obj2.children.should eq([1_u16])

    wv.contents(2_u16).size.should eq(1)
    wv.contents(2_u16).first.number.should eq(1_u16)

    wv.parent_of(1_u16).not_nil!.number.should eq(2_u16)
    wv.parent_of(2_u16).should be_nil

    json = wv.to_json
    parsed = JSON.parse(json)
    parsed["location"].as_i.should eq(2)
    parsed["objects"].as_a.size.should eq(2)
    parsed["globals"]["16"].as_i.should eq(2)
    parsed["objects"][0]["property_bytes"]["2"].as_a.map(&.as_i).should eq([0x12, 0x34, 0x56, 0x78, 0x9a])
    Zink::Worldview.from_json(json).globals[16_u8].should eq(2_u16)
  end
end

describe Zink::SaveSnapshot do
  it "round-trips through JSON for persistence" do
    bytes = build_story_bytes

    # print "go ", store global 0 = 42, then quit
    bytes[0x40] = 0xb2_u8 # print
    write_word(bytes, 0x41, zword(12, 20, 0))
    bytes[0x43] = 0x0d_u8
    bytes[0x44] = 0x10_u8
    bytes[0x45] = 0x2a_u8
    bytes[0x46] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)
    vm.run

    snapshot = vm.export_save
    snapshot.output.should eq("go ")

    json = snapshot.to_json
    restored = Zink::SaveSnapshot.from_json(json)

    restored.pc.should eq(snapshot.pc)
    restored.stack.should eq(snapshot.stack)
    restored.locals.should eq(snapshot.locals)
    restored.rng_seed.should eq(snapshot.rng_seed)
    restored.dynamic_memory.should eq(snapshot.dynamic_memory)
    restored.call_stack.size.should eq(snapshot.call_stack.size)
    restored.output.should eq("go ")

    # Import into a fresh VM and verify state
    story2 = Zink::Story.from_bytes(build_story_bytes)
    vm2 = Zink::VM.new(story2, Zink::BufferIO.new)
    vm2.import_save(restored)

    story2.memory.read_word(0x0070).should eq(42_u16)
    vm2.pc.should eq(snapshot.pc)
  end

  it "export_save_for_persistence rewinds PC to sread for correct resume" do
    bytes = build_story_bytes(static_base: 0xc0_u16)

    # Program: print "hi", sread, print "bye", sread (loop via jump)
    # 0x40: print "hi"
    bytes[0x40] = 0xb2_u8
    write_word(bytes, 0x41, zword(13, 14, 0)) # "hi "

    # 0x43: sread 0x80 0xA0
    bytes[0x43] = 0xe4_u8 # VAR sread
    bytes[0x44] = 0x0f_u8 # types: large, large
    write_word(bytes, 0x45, 0x0080_u16)
    write_word(bytes, 0x47, 0x00a0_u16)

    # 0x49: print "bye"
    bytes[0x49] = 0xb2_u8
    write_word(bytes, 0x4a, zword(7, 30, 10)) # "bye"

    # 0x4c: quit
    bytes[0x4c] = 0xba_u8

    bytes[0x80] = 20_u8
    bytes[0xa0] = 6_u8

    # Run with one input line — VM processes sread then continues to quit
    story = Zink::Story.from_bytes(bytes)
    io = Zink::ScriptedIO.new(["look"])
    vm = Zink::VM.new(story, io)
    vm.run

    # last_read_pc should point to the sread at 0x43
    vm.last_read_pc.should eq(0x43)

    # export_save has current (post-quit) PC
    normal = vm.export_save
    normal.pc.should_not eq(0x43)

    # export_save_for_persistence rewinds to sread
    persistent = vm.export_save_for_persistence
    persistent.pc.should eq(0x43)

    # Import into fresh VM with new input — should re-execute sread
    story2 = Zink::Story.from_bytes(bytes)
    io2 = Zink::ScriptedIO.new(["inventory"])
    vm2 = Zink::VM.new(story2, io2)
    vm2.import_save(persistent)
    vm2.run

    # VM resumed at sread, consumed "inventory", then printed "bye" and quit
    io2.to_s.should eq("bye")
  end
end

describe Zink::VM do
  it "decodes call_vs2 arguments and checks their count in v5" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x0100_u16)
    bytes[0x40] = 0xec_u8                                # call_vs2
    bytes[0x41] = 0x55_u8                                # four small operands
    bytes[0x42] = 0x5f_u8                                # two more, then omitted
    write_bytes(bytes, 0x43, Bytes[0x30, 1, 2, 3, 4, 5]) # routine 0xc0, five args
    bytes[0x49] = 0x10_u8                                # -> global 0
    bytes[0x4a] = 0xba_u8
    bytes[0xc0] = 5_u8    # five zero-initialized locals in v5
    bytes[0xc1] = 0xff_u8 # check_arg_count 5
    bytes[0xc2] = 0x7f_u8
    bytes[0xc3] = 5_u8
    bytes[0xc4] = 0xc4_u8 # branch to 0xc7
    bytes[0xc5] = 0xb1_u8 # rfalse
    bytes[0xc6] = 0xb4_u8 # nop
    bytes[0xc7] = 0xab_u8 # ret local 5
    bytes[0xc8] = 5_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::VM.new(story).run
    story.memory.read_word(0x70).should eq(5_u16)
  end

  it "reads v4 routine default locals" do
    bytes = build_story_bytes(version: 4_u8, static_base: 0x0100_u16)
    bytes[0x40] = 0x98_u8 # call_1s packed routine 0x30 -> byte address 0xc0
    bytes[0x41] = 0x30_u8
    bytes[0x42] = 0x10_u8 # -> global 0
    bytes[0x43] = 0xba_u8
    bytes[0xc0] = 1_u8 # one local
    write_word(bytes, 0xc1, 0x1234_u16)
    bytes[0xc3] = 0xab_u8 # ret local 1
    bytes[0xc4] = 1_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::VM.new(story).run
    story.memory.read_word(0x70).should eq(0x1234_u16)
  end

  it "returns 2 from v4 save after restore and preserves display flags" do
    bytes = build_story_bytes(version: 4_u8)
    bytes[0x40] = 0xb5_u8 # save -> global 0
    bytes[0x41] = 0x10_u8
    bytes[0x42] = 0xb6_u8 # restore -> global 1
    bytes[0x43] = 0x11_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story)
    vm.step
    story.memory.read_word(0x70).should eq(1_u16)

    story.memory.write_word(0x10, 3_u16) # transcript and fixed pitch
    vm.step
    vm.pc.should eq(0x42)
    story.memory.read_word(0x70).should eq(2_u16)
    (story.memory.read_word(0x10) & 3_u16).should eq(3_u16)
  end

  it "stores the v5 read terminator and writes the length-prefixed input buffer" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x40] = 0xe4_u8 # read text parse -> global 0
    bytes[0x41] = 0x0f_u8
    write_word(bytes, 0x42, 0x0080_u16)
    write_word(bytes, 0x44, 0x00a0_u16)
    bytes[0x46] = 0x10_u8
    bytes[0x47] = 0xba_u8
    bytes[0x80] = 20_u8
    bytes[0xa0] = 4_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::VM.new(story, Zink::ScriptedIO.new(["look"])).run
    story.memory.read_word(0x70).should eq(13_u16)
    story.memory.read_byte(0x81).should eq(4_u8)
    story.memory.read_byte(0xa5).should eq(2_u8)
    story.memory.read_byte(0x21).should eq(80_u8)
  end

  it "captures v5 output stream 3 text in story memory" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x40] = 0xf3_u8 # output_stream 3 table
    bytes[0x41] = 0x4f_u8
    bytes[0x42] = 3_u8
    write_word(bytes, 0x43, 0x0090_u16)
    bytes[0x45] = 0xe5_u8 # print_char 'A'
    bytes[0x46] = 0x7f_u8
    bytes[0x47] = 'A'.ord.to_u8
    bytes[0x48] = 0xf3_u8 # output_stream -3
    bytes[0x49] = 0x3f_u8
    write_word(bytes, 0x4a, 0xfffd_u16)
    bytes[0x4c] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    Zink::VM.new(story, io).run
    story.memory.read_word(0x90).should eq(1_u16)
    story.memory.read_byte(0x92).should eq('A'.ord.to_u8)
    io.to_s.should be_empty
  end

  it "captures transcript and command streams when selected" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x40] = 0xf3_u8 # output_stream 2
    bytes[0x41] = 0x7f_u8
    bytes[0x42] = 2_u8
    bytes[0x43] = 0xf3_u8 # output_stream 4
    bytes[0x44] = 0x7f_u8
    bytes[0x45] = 4_u8
    bytes[0x46] = 0xe5_u8 # print_char 'A'
    bytes[0x47] = 0x7f_u8
    bytes[0x48] = 'A'.ord.to_u8
    bytes[0x49] = 0xe4_u8 # read
    bytes[0x4a] = 0x0f_u8
    write_word(bytes, 0x4b, 0x0080_u16)
    write_word(bytes, 0x4d, 0x00a0_u16)
    bytes[0x4f] = 0x10_u8
    bytes[0x50] = 0xf3_u8 # output_stream -2
    bytes[0x51] = 0x3f_u8
    write_word(bytes, 0x52, 0xfffe_u16)
    bytes[0x54] = 0xba_u8
    bytes[0x80] = 20_u8
    bytes[0xa0] = 4_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::ScriptedIO.new(["look"]))
    vm.run
    vm.transcript.should eq("Alook\n")
    vm.recorded_commands.should eq("look\n")
    (story.memory.read_word(0x10) & 1_u16).should eq(0_u16)
  end

  it "resumes v5 extended restore at save with result 2" do
    bytes = build_story_bytes(version: 5_u8)
    bytes[0x40] = 0xbe_u8 # EXT save, no operands -> global 0
    bytes[0x41] = 0_u8
    bytes[0x42] = 0xff_u8
    bytes[0x43] = 0x10_u8
    bytes[0x44] = 0xbe_u8 # EXT restore, no operands -> global 1
    bytes[0x45] = 1_u8
    bytes[0x46] = 0xff_u8
    bytes[0x47] = 0x11_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story)
    vm.step
    story.memory.read_word(0x70).should eq(1_u16)
    vm.step
    vm.pc.should eq(0x44)
    story.memory.read_word(0x70).should eq(2_u16)
  end

  it "resumes v5 undo at save_undo with result 2" do
    bytes = build_story_bytes(version: 5_u8)
    bytes[0x40] = 0xbe_u8
    bytes[0x41] = 9_u8 # save_undo
    bytes[0x42] = 0xff_u8
    bytes[0x43] = 0x10_u8
    bytes[0x44] = 0xbe_u8
    bytes[0x45] = 10_u8 # restore_undo
    bytes[0x46] = 0xff_u8
    bytes[0x47] = 0x11_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story)
    vm.step
    story.memory.read_word(0x70).should eq(1_u16)
    vm.step
    vm.pc.should eq(0x44)
    story.memory.read_word(0x70).should eq(2_u16)
  end

  it "saves and restores a v5 auxiliary byte range" do
    bytes = build_story_bytes(version: 5_u8, static_base: 0x00c0_u16)
    bytes[0x40] = 0xbe_u8 # EXT save table 0x90, length 3
    bytes[0x41] = 0_u8
    bytes[0x42] = 0x0f_u8
    write_word(bytes, 0x43, 0x0090_u16)
    write_word(bytes, 0x45, 3_u16)
    bytes[0x47] = 0x10_u8
    bytes[0x48] = 0xbe_u8 # EXT restore table 0x90, length 3
    bytes[0x49] = 1_u8
    bytes[0x4a] = 0x0f_u8
    write_word(bytes, 0x4b, 0x0090_u16)
    write_word(bytes, 0x4d, 3_u16)
    bytes[0x4f] = 0x11_u8
    write_bytes(bytes, 0x90, Bytes[3, 4, 5])

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story)
    vm.step
    story.memory.write_byte(0x91, 0_u8)
    vm.step
    story.memory.read_byte(0x91).should eq(4_u8)
    story.memory.read_word(0x72).should eq(3_u16)
  end

  it "resolves indirect variable numbers for store and inc" do
    bytes = build_story_bytes
    bytes[0x40] = 0x0d_u8 # store global 0 = variable number 17
    bytes[0x41] = 0x10_u8
    bytes[0x42] = 0x11_u8
    bytes[0x43] = 0x4d_u8 # store (variable global 0), 42
    bytes[0x44] = 0x10_u8
    bytes[0x45] = 0x2a_u8
    bytes[0x46] = 0xa5_u8 # inc (variable global 0)
    bytes[0x47] = 0x10_u8
    bytes[0x48] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::VM.new(story).run
    story.memory.read_word(0x70).should eq(17_u16)
    story.memory.read_word(0x72).should eq(43_u16)
  end

  it "evaluates every je operand even after finding a match" do
    bytes = build_story_bytes
    cursor = 0x40
    [9_u8, 3_u8, 3_u8].each do |value|
      bytes[cursor] = 0xe8_u8 # push small constant
      bytes[cursor + 1] = 0x7f_u8
      bytes[cursor + 2] = value
      cursor += 3
    end
    bytes[cursor] = 0xc1_u8     # je sp sp sp
    bytes[cursor + 1] = 0xab_u8 # three variable operands
    bytes[cursor + 2] = 0_u8
    bytes[cursor + 3] = 0_u8
    bytes[cursor + 4] = 0_u8
    bytes[cursor + 5] = 0xc2_u8 # branch true, offset 2
    bytes[cursor + 6] = 0xba_u8

    vm = Zink::VM.new(Zink::Story.from_bytes(bytes))
    vm.run
    vm.export_save.stack.should be_empty
  end

  it "rounds signed division toward zero and keeps the dividend's remainder sign" do
    bytes = build_story_bytes
    bytes[0x40] = 0xd7_u8 # div, two large constants
    bytes[0x41] = 0x0f_u8
    write_word(bytes, 0x42, 0xfff9_u16) # -7
    write_word(bytes, 0x44, 3_u16)
    bytes[0x46] = 0x10_u8 # -> global 0
    bytes[0x47] = 0xd8_u8 # mod, two large constants
    bytes[0x48] = 0x0f_u8
    write_word(bytes, 0x49, 0xfff9_u16) # -7
    write_word(bytes, 0x4b, 3_u16)
    bytes[0x4d] = 0x11_u8 # -> global 1
    bytes[0x4e] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    Zink::VM.new(story).run
    story.memory.read_word(0x70).should eq(0xfffe_u16) # -2
    story.memory.read_word(0x72).should eq(0xffff_u16) # -1
  end

  it "runs a minimal print/new_line/quit program" do
    bytes = build_story_bytes
    bytes[0x40] = 0xb2_u8 # print
    write_word(bytes, 0x41, zword(12, 20, 0))
    bytes[0x43] = 0xbb_u8 # new_line
    bytes[0x44] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)

    vm.run

    io.to_s.should eq("go \n")
    vm.halted.should be_true
  end

  it "branches on je and skips fallthrough code" do
    bytes = build_story_bytes

    bytes[0x40] = 0x01_u8 # 2OP je (small, small)
    bytes[0x41] = 0x05_u8
    bytes[0x42] = 0x05_u8
    bytes[0x43] = 0xc6_u8 # branch-if-true, 1-byte offset 6 -> target 0x48

    bytes[0x44] = 0xb2_u8 # print "no " (should be skipped)
    write_word(bytes, 0x45, zword(19, 20, 0))
    bytes[0x47] = 0xba_u8 # quit

    bytes[0x48] = 0xb2_u8 # print "ok "
    write_word(bytes, 0x49, zword(20, 16, 0))
    bytes[0x4b] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)

    vm.run

    io.to_s.should eq("ok ")
  end

  it "stores and mutates globals then prints with print_num" do
    bytes = build_story_bytes

    bytes[0x40] = 0x0d_u8 # 2OP store (small, small)
    bytes[0x41] = 0x10_u8 # global 0
    bytes[0x42] = 0x2a_u8 # 42

    bytes[0x43] = 0x95_u8 # 1OP inc (small)
    bytes[0x44] = 0x10_u8

    bytes[0x45] = 0x96_u8 # 1OP dec (small)
    bytes[0x46] = 0x10_u8

    bytes[0x47] = 0xe6_u8 # VAR print_num
    bytes[0x48] = 0xbf_u8 # types: variable, omitted, omitted, omitted
    bytes[0x49] = 0x10_u8 # global 0

    bytes[0x4a] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)

    vm.run

    io.to_s.should eq("42")
  end

  it "supports routine calls, local defaults, and argument override" do
    bytes = build_story_bytes

    bytes[0x40] = 0x98_u8 # 1OP call_1s (small constant)
    bytes[0x41] = 0x30_u8 # packed routine address => 0x60
    bytes[0x42] = 0x10_u8 # store to global 0
    bytes[0x43] = 0xe6_u8 # VAR print_num
    bytes[0x44] = 0xbf_u8 # operand types: variable
    bytes[0x45] = 0x10_u8 # global 0
    bytes[0x46] = 0xbb_u8 # new_line

    bytes[0x47] = 0xe0_u8 # VAR call_vs
    bytes[0x48] = 0x5f_u8 # operand types: small, small
    bytes[0x49] = 0x30_u8 # packed routine address => 0x60
    bytes[0x4a] = 0x07_u8 # arg1
    bytes[0x4b] = 0x10_u8 # store to global 0
    bytes[0x4c] = 0xe6_u8 # VAR print_num
    bytes[0x4d] = 0xbf_u8 # operand types: variable
    bytes[0x4e] = 0x10_u8 # global 0
    bytes[0x4f] = 0xba_u8 # quit

    # Routine at 0x60:
    # - one local, default value 11
    # - ret local1
    bytes[0x60] = 0x01_u8
    bytes[0x61] = 0x00_u8
    bytes[0x62] = 0x0b_u8
    bytes[0x63] = 0xab_u8 # 1OP ret (variable)
    bytes[0x64] = 0x01_u8 # local 1

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)

    vm.run

    io.to_s.should eq("11\n7")
  end

  it "reads input into text/parse buffers and resolves dictionary entries" do
    bytes = build_story_bytes(static_base: 0xc0_u16)

    # Dictionary at 0x50: separators=',' ; entry_length=4 ; entries=2 ("take", "lamp")
    bytes[0x50] = 0x01_u8
    bytes[0x51] = ','.ord.to_u8
    bytes[0x52] = 0x04_u8
    write_word(bytes, 0x53, 0x0002_u16)

    take_key = Zink::Parser.encode_dictionary_key("take", 3_u8)
    lamp_key = Zink::Parser.encode_dictionary_key("lamp", 3_u8)
    write_bytes(bytes, 0x55, take_key)
    write_bytes(bytes, 0x59, lamp_key)

    # Program:
    # read 0x80 0xA0
    # quit
    bytes[0x40] = 0xe4_u8 # VAR sread/read
    bytes[0x41] = 0x0f_u8 # types: large, large
    write_word(bytes, 0x42, 0x0080_u16)
    write_word(bytes, 0x44, 0x00a0_u16)
    bytes[0x46] = 0xba_u8 # quit

    # Buffers
    bytes[0x80] = 20_u8 # max input chars
    bytes[0xa0] = 6_u8  # max tokens

    story = Zink::Story.from_bytes(bytes)
    io = Zink::ScriptedIO.new(["take lamp"])
    vm = Zink::VM.new(story, io)

    vm.run

    memory = story.memory

    memory.read_byte(0x81).should eq('t'.ord.to_u8)
    memory.read_byte(0x82).should eq('a'.ord.to_u8)
    memory.read_byte(0x83).should eq('k'.ord.to_u8)
    memory.read_byte(0x84).should eq('e'.ord.to_u8)
    memory.read_byte(0x85).should eq(' '.ord.to_u8)
    memory.read_byte(0x86).should eq('l'.ord.to_u8)
    memory.read_byte(0x87).should eq('a'.ord.to_u8)
    memory.read_byte(0x88).should eq('m'.ord.to_u8)
    memory.read_byte(0x89).should eq('p'.ord.to_u8)
    memory.read_byte(0x8a).should eq(0_u8)

    memory.read_byte(0xa1).should eq(2_u8) # token count

    memory.read_word(0xa2).should eq(0x55_u16) # "take" dict address
    memory.read_byte(0xa4).should eq(4_u8)     # token length
    memory.read_byte(0xa5).should eq(1_u8)     # token position

    memory.read_word(0xa6).should eq(0x59_u16) # "lamp" dict address
    memory.read_byte(0xa8).should eq(4_u8)
    memory.read_byte(0xa9).should eq(6_u8)
  end

  it "halts cleanly on input EOF instead of spinning" do
    bytes = build_story_bytes(static_base: 0xc0_u16)

    # Looping read program; VM should stop once input stream is exhausted.
    bytes[0x40] = 0xe4_u8 # VAR sread/read
    bytes[0x41] = 0x0f_u8 # types: large, large
    write_word(bytes, 0x42, 0x0080_u16)
    write_word(bytes, 0x44, 0x00a0_u16)
    bytes[0x46] = 0x8c_u8               # jump
    write_word(bytes, 0x47, 0xfff9_u16) # -7 => back to 0x40

    bytes[0x80] = 20_u8
    bytes[0xa0] = 6_u8

    story = Zink::Story.from_bytes(bytes)
    io = Zink::ScriptedIO.new(["look"])
    vm = Zink::VM.new(story, io)

    vm.run_unbounded
    vm.halted.should be_true
  end

  it "executes object/property opcodes and stores results in globals" do
    bytes = build_object_story_bytes

    bytes[0x40] = 0x93_u8 # 1OP get_parent (small)
    bytes[0x41] = 0x01_u8 # object 1
    bytes[0x42] = 0x10_u8 # -> global 0

    bytes[0x43] = 0x11_u8 # 2OP get_prop
    bytes[0x44] = 0x01_u8 # object 1
    bytes[0x45] = 0x05_u8 # property 5
    bytes[0x46] = 0x11_u8 # -> global 1

    bytes[0x47] = 0x13_u8 # 2OP get_next_prop
    bytes[0x48] = 0x01_u8 # object 1
    bytes[0x49] = 0x00_u8 # first property
    bytes[0x4a] = 0x12_u8 # -> global 2

    bytes[0x4b] = 0xe3_u8 # VAR put_prop
    bytes[0x4c] = 0x57_u8 # small, small, small
    bytes[0x4d] = 0x01_u8 # object 1
    bytes[0x4e] = 0x05_u8 # property 5
    bytes[0x4f] = 0x07_u8 # value 7

    bytes[0x50] = 0x11_u8 # 2OP get_prop
    bytes[0x51] = 0x01_u8 # object 1
    bytes[0x52] = 0x05_u8 # property 5
    bytes[0x53] = 0x13_u8 # -> global 3

    bytes[0x54] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)
    vm.run

    memory = story.memory
    memory.read_word(0x0200).should eq(2_u16)  # global 0
    memory.read_word(0x0202).should eq(42_u16) # global 1
    memory.read_word(0x0204).should eq(5_u16)  # global 2
    memory.read_word(0x0206).should eq(7_u16)  # global 3
  end

  it "supports print_addr, print_paddr, and print_char" do
    bytes = build_story_bytes

    bytes[0x40] = 0x87_u8 # 1OP print_addr (large)
    write_word(bytes, 0x41, 0x0100_u16)

    bytes[0x43] = 0x9d_u8 # 1OP print_paddr (small)
    bytes[0x44] = 0x90_u8 # packed => 0x120

    bytes[0x45] = 0xe5_u8 # VAR print_char
    bytes[0x46] = 0x7f_u8 # one small operand
    bytes[0x47] = '!'.ord.to_u8

    bytes[0x48] = 0xba_u8 # quit

    write_word(bytes, 0x0100, zword(13, 14, 0)) # "hi "
    write_word(bytes, 0x0120, zword(20, 16, 0)) # "ok "

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)
    vm.run

    io.to_s.should eq("hi ok !")
  end

  it "supports deterministic random seeding via random opcode" do
    bytes = build_story_bytes

    bytes[0x40] = 0xe7_u8               # random
    bytes[0x41] = 0x3f_u8               # one large operand
    write_word(bytes, 0x42, 0xfff9_u16) # -7
    bytes[0x44] = 0x10_u8               # -> global 0 (result 0)

    bytes[0x45] = 0xe7_u8 # random 100
    bytes[0x46] = 0x7f_u8
    bytes[0x47] = 100_u8
    bytes[0x48] = 0x11_u8 # -> global 1

    bytes[0x49] = 0xe7_u8 # reseed
    bytes[0x4a] = 0x3f_u8
    write_word(bytes, 0x4b, 0xfff9_u16) # -7
    bytes[0x4d] = 0x12_u8               # -> global 2

    bytes[0x4e] = 0xe7_u8 # random 100 again
    bytes[0x4f] = 0x7f_u8
    bytes[0x50] = 100_u8
    bytes[0x51] = 0x13_u8 # -> global 3

    bytes[0x52] = 0xba_u8 # quit

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)
    vm.run

    memory = story.memory
    first = memory.read_word(0x0072)
    second = memory.read_word(0x0076)
    first.should eq(second)
    first.should be > 0_u16
    first.should be <= 100_u16
  end

  it "restarts VM state and restores dynamic memory" do
    bytes = build_story_bytes

    bytes[0x40] = 0x0d_u8 # store global 0 = 5
    bytes[0x41] = 0x10_u8
    bytes[0x42] = 0x05_u8
    bytes[0x43] = 0xb7_u8 # restart

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)

    vm.step
    story.memory.read_word(0x0070).should eq(5_u16)

    vm.step
    story.memory.read_word(0x0070).should eq(0_u16)
    vm.pc.should eq(0x40)
  end

  it "branches on verify when checksum matches" do
    bytes = build_story_bytes

    bytes[0x40] = 0xbd_u8 # 0OP verify
    bytes[0x41] = 0xc6_u8 # branch true offset 6 -> 0x46

    bytes[0x42] = 0xb2_u8 # print "no "
    write_word(bytes, 0x43, zword(19, 20, 0))
    bytes[0x45] = 0xba_u8

    bytes[0x46] = 0xb2_u8 # print "ok "
    write_word(bytes, 0x47, zword(20, 16, 0))
    bytes[0x49] = 0xba_u8

    set_story_checksum(bytes)

    story = Zink::Story.from_bytes(bytes)
    io = Zink::BufferIO.new
    vm = Zink::VM.new(story, io)
    vm.run

    io.to_s.should eq("ok ")
  end

  it "supports v3 save/restore resume semantics" do
    bytes = build_story_bytes

    bytes[0x40] = 0xb5_u8 # save
    bytes[0x41] = 0xc6_u8 # branch-if-true to 0x46

    # Fallthrough path after restore resume.
    bytes[0x42] = 0x0d_u8 # store global 0 = 2
    bytes[0x43] = 0x10_u8
    bytes[0x44] = 0x02_u8
    bytes[0x45] = 0xba_u8 # quit

    # Initial save success path.
    bytes[0x46] = 0x0d_u8 # store global 0 = 1
    bytes[0x47] = 0x10_u8
    bytes[0x48] = 0x01_u8
    bytes[0x49] = 0xb6_u8 # restore
    bytes[0x4a] = 0xc1_u8 # branch payload (ignored on successful restore)
    bytes[0x4b] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)
    vm.run

    story.memory.read_word(0x0070).should eq(2_u16)
  end

  it "falls through restore when no snapshot exists" do
    bytes = build_story_bytes

    bytes[0x40] = 0xb6_u8 # restore
    bytes[0x41] = 0xc6_u8 # if branched, goes to 0x46

    bytes[0x42] = 0x0d_u8 # fallthrough: store global 0 = 9
    bytes[0x43] = 0x10_u8
    bytes[0x44] = 0x09_u8
    bytes[0x45] = 0xba_u8

    bytes[0x46] = 0x0d_u8 # branched path (should not run)
    bytes[0x47] = 0x10_u8
    bytes[0x48] = 0x01_u8
    bytes[0x49] = 0xba_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story, Zink::BufferIO.new)
    vm.run

    story.memory.read_word(0x0070).should eq(9_u16)
  end

  it "applies inc_chk and dec_chk with signed branch checks" do
    inc_bytes = build_story_bytes
    inc_bytes[0x40] = 0x0d_u8 # store global 0 = 1
    inc_bytes[0x41] = 0x10_u8
    inc_bytes[0x42] = 0x01_u8
    inc_bytes[0x43] = 0x05_u8 # inc_chk
    inc_bytes[0x44] = 0x10_u8
    inc_bytes[0x45] = 0x01_u8
    inc_bytes[0x46] = 0xc1_u8 # if true then rtrue

    inc_story = Zink::Story.from_bytes(inc_bytes)
    inc_vm = Zink::VM.new(inc_story, Zink::BufferIO.new)
    inc_vm.step
    inc_vm.step
    inc_story.memory.read_word(0x0070).should eq(2_u16)
    inc_vm.halted.should be_true

    dec_bytes = build_story_bytes
    dec_bytes[0x40] = 0x0d_u8 # store global 0 = 2
    dec_bytes[0x41] = 0x10_u8
    dec_bytes[0x42] = 0x02_u8
    dec_bytes[0x43] = 0x04_u8 # dec_chk
    dec_bytes[0x44] = 0x10_u8
    dec_bytes[0x45] = 0x02_u8
    dec_bytes[0x46] = 0xc1_u8 # if true then rtrue

    dec_story = Zink::Story.from_bytes(dec_bytes)
    dec_vm = Zink::VM.new(dec_story, Zink::BufferIO.new)
    dec_vm.step
    dec_vm.step
    dec_story.memory.read_word(0x0070).should eq(1_u16)
    dec_vm.halted.should be_true
  end

  it "raises on unsupported opcodes" do
    bytes = build_story_bytes
    bytes[0x40] = 0x00_u8

    story = Zink::Story.from_bytes(bytes)
    vm = Zink::VM.new(story)

    expect_raises(Zink::UnsupportedInstructionError) do
      vm.step
    end
  end
end
