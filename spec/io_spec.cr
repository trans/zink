require "./spec_helper"

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
