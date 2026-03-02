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
  write_word(bytes, 0x1a, (bytes.size // 2).to_u16)
  bytes
end

private def build_object_story_bytes : Bytes
  bytes = build_story_bytes(
    static_base: 0x0200_u16,
    dictionary_table: 0x0050_u16,
    object_table: 0x0090_u16,
    globals_table: 0x0080_u16
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

  # Object 1 properties: prop 5 size 1 => 42, prop 3 size 2 => 0x1234.
  bytes[0x0120] = 0_u8 # short name words
  bytes[0x0121] = 0x05_u8
  bytes[0x0122] = 0x2a_u8
  bytes[0x0123] = 0x23_u8
  bytes[0x0124] = 0x12_u8
  bytes[0x0125] = 0x34_u8
  bytes[0x0126] = 0x00_u8

  # Object 2 has no properties.
  bytes[0x0140] = 0_u8
  bytes[0x0141] = 0_u8

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
    objects.get_property(1_u16, 7_u8).should eq(0_u16)

    prop5_addr = objects.get_property_address(1_u16, 5_u8)
    prop3_addr = objects.get_property_address(1_u16, 3_u8)
    objects.property_length(prop5_addr).should eq(1_u8)
    objects.property_length(prop3_addr).should eq(2_u8)

    objects.get_next_property_number(1_u16, 0_u8).should eq(5_u8)
    objects.get_next_property_number(1_u16, 5_u8).should eq(3_u8)
    objects.get_next_property_number(1_u16, 3_u8).should eq(0_u8)

    objects.remove_object(1_u16)
    objects.parent(1_u16).should eq(0_u8)
    objects.child(2_u16).should eq(0_u8)

    objects.insert_object(1_u16, 2_u16)
    objects.parent(1_u16).should eq(2_u8)
    objects.child(2_u16).should eq(1_u8)

    objects.put_property(1_u16, 5_u8, 7_u16)
    objects.get_property(1_u16, 5_u8).should eq(7_u16)
  end
end

describe Zink::VM do
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
    memory.read_word(0x0080).should eq(2_u16)  # global 0
    memory.read_word(0x0082).should eq(42_u16) # global 1
    memory.read_word(0x0084).should eq(5_u16)  # global 2
    memory.read_word(0x0086).should eq(7_u16)  # global 3
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
