require "./spec_helper"

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
