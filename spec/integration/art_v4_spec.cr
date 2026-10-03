require "../spec_helper"
require "digest/sha256"

# The IF Archive story is downloaded separately; its redistribution terms are
# unclear, so it is intentionally absent from the repository.
if path = ENV["ZINK_ART_V4_STORY"]?
  describe "Art (IF Art Show 2000) v4 smoke test" do
    it "runs its positioned-text and key-input sequence" do
      Digest::SHA256.hexdigest(File.read(path)).should eq("5bb9d312c61f6af47c7d67fd138adf338ef3dba36163a0177da5904e49d6a962")
      story = Zink::Story.load(path)
      story.header.version.should eq(4_u8)
      story.checksum_valid?.should be_true

      io = Zink::ScriptedIO.new(["q"])
      vm = Zink::VM.new(story, io)
      vm.run(100_000)

      vm.halted.should be_true
      vm.worldview.objects.size.should eq(4)
      io.output_text.should contain("words get")
      io.output_text.should contain("4-q-6")
    end
  end
end
