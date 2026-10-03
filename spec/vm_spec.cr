require "./spec_helper"

describe Zink::VM do
  it "replaces the stack top for store and pull into variable zero" do
    builder = SpecStoryBuilder.new
    [41_u8, 42_u8, 43_u8].each do |value|
      builder.emit(0xe8_u8, 0x7f_u8, value) # push
    end
    builder.emit(0x0d_u8, 0x00_u8, 83_u8)   # store sp 83
    builder.emit(0xe9_u8, 0x7f_u8, 0x00_u8) # pull sp
    builder.emit(0xba_u8)                   # quit

    vm = Zink::VM.new(builder.story)
    vm.run
    vm.export_save.stack.should eq([41_u16, 83_u16])
  end

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
    builder = SpecStoryBuilder.new(version: 4_u8)
    builder.emit(0xb5_u8, 0x10_u8) # save -> global 0
    builder.emit(0xb6_u8, 0x11_u8) # restore -> global 1

    story = builder.story
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

  it "replays command-file keys and lines, then returns to keyboard at EOF" do
    builder = SpecStoryBuilder.new(version: 5_u8, static_base: 0x0180_u16,
      dictionary_table: 0x01c0_u16)
    builder.emit(0xf3_u8, 0x7f_u8, 4_u8)          # output_stream 4
    builder.emit(0xf6_u8, 0x7f_u8, 1_u8, 0x10_u8) # read_char -> global 0
    builder.emit(0xe4_u8, 0x0f_u8).emit_word(0x0080_u16).emit_word(0x00a0_u16).emit(0x11_u8)
    builder.emit(0xe4_u8, 0x0f_u8).emit_word(0x00c0_u16).emit_word(0x00e0_u16).emit(0x12_u8)
    builder.emit(0xf6_u8, 0x7f_u8, 1_u8, 0x13_u8) # read_char -> global 3
    builder.emit(0xba_u8)
    [0x80, 0xc0].each { |address| builder.bytes[address] = 20_u8 }
    [0xa0, 0xe0].each { |address| builder.bytes[address] = 4_u8 }

    story = builder.story
    io = Zink::ScriptedIO.new(["south", "["], command_script: "[91]\nlook\n")
    vm = Zink::VM.new(story, io)
    vm.select_input_stream(1)
    vm.run

    story.memory.read_word(0x70).should eq(91_u16)
    story.memory.read_word(0x76).should eq(91_u16)
    story.memory.read_byte(0x81).should eq(4_u8)
    story.memory.read_byte(0xc1).should eq(5_u8)
    io.output_text.should eq("look\n")
    vm.recorded_commands.should eq("south\n[91]\n")
  end

  it "switches command-file input off and restarts it when reselected" do
    builder = SpecStoryBuilder.new(version: 5_u8, static_base: 0x0180_u16,
      dictionary_table: 0x01c0_u16)
    builder.emit(0xf4_u8, 0x7f_u8, 1_u8) # input_stream 1
    builder.emit(0xe4_u8, 0x0f_u8).emit_word(0x0080_u16).emit_word(0x00a0_u16).emit(0x10_u8)
    builder.emit(0xf4_u8, 0x7f_u8, 0_u8) # input_stream 0
    builder.emit(0xe4_u8, 0x0f_u8).emit_word(0x00c0_u16).emit_word(0x00e0_u16).emit(0x11_u8)
    builder.emit(0xf4_u8, 0x7f_u8, 1_u8) # input_stream 1
    builder.emit(0xe4_u8, 0x0f_u8).emit_word(0x0100_u16).emit_word(0x0110_u16).emit(0x12_u8)
    builder.emit(0xba_u8)
    [0x80, 0xc0, 0x100].each { |address| builder.bytes[address] = 20_u8 }
    [0xa0, 0xe0, 0x110].each { |address| builder.bytes[address] = 4_u8 }

    story = builder.story
    io = Zink::ScriptedIO.new(["west"], command_script: "east\n")
    vm = Zink::VM.new(story, io)
    vm.run

    story.memory.read_byte(0x101).should eq(4_u8)
    String.new(story.memory.bytes[0x102, 4]).should eq("east")
    io.output_text.should eq("east\neast\n")
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
