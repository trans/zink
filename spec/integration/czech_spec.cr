require "../spec_helper"

describe "CZECH interpreter checks" do
  {
    {"czech.z3", 3_u8, 368, 349},
    {"czech.z4", 4_u8, 386, 367},
    {"czech.z5", 5_u8, 425, 406},
  }.each do |filename, version, total, passed|
    it "passes the v#{version} core checks" do
      path = File.join(__DIR__, "..", "fixtures", "czech", filename)
      story = Zink::Story.load(path)
      story.header.version.should eq(version)
      story.checksum_valid?.should be_true

      io = Zink::ScriptedIO.new([] of String)
      vm = Zink::VM.new(story, io)
      vm.run(200_000)

      vm.halted.should be_true
      io.output_text.should contain("Performed #{total} tests.")
      io.output_text.should contain("Passed: #{passed}, Failed: 0, Print tests: 19")
      io.output_text.should_not contain("ERROR")
    end
  end
end
