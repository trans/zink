require "./spec_helper"

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
