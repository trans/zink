require "./spec_helper"

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
