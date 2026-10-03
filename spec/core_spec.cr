require "./spec_helper"

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

describe Zink::Story do
  it "verifies the original file after dynamic memory changes" do
    bytes = build_story_bytes
    set_story_checksum(bytes)
    story = Zink::Story.from_bytes(bytes)
    story.memory.write_byte(0x50, 1_u8)
    story.checksum_valid?.should be_true
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
