require "base64"
require "json"

module Zink
  class UnsupportedInstructionError < Exception
  end

  private enum OperandType
    LargeConstant
    SmallConstant
    Variable
  end

  private struct Operand
    getter type : OperandType
    getter raw : UInt16

    def initialize(@type : OperandType, @raw : UInt16)
    end
  end

  private struct Branch
    getter branch_if_true : Bool
    getter offset : Int32

    def initialize(@branch_if_true : Bool, @offset : Int32)
    end
  end

  struct CallFrame
    include JSON::Serializable

    getter return_pc : Int32
    getter store_variable : UInt8?
    getter locals : Array(UInt16)
    getter stack_base : Int32
    getter arg_count : Int32

    def initialize(@return_pc : Int32, @store_variable : UInt8?, @locals : Array(UInt16), @stack_base : Int32, @arg_count : Int32 = 0)
    end
  end

  struct SaveSnapshot
    include JSON::Serializable

    @[JSON::Field(converter: Zink::Base64Converter)]
    getter dynamic_memory : Bytes
    getter pc : Int32
    getter stack : Array(UInt16)
    getter locals : Array(UInt16)
    getter call_stack : Array(CallFrame)
    getter rng_seed : UInt32?
    getter output : String
    getter arg_count : Int32
    getter resume_store_var : UInt8?
    getter memory_streams : Array(Int32)
    getter screen_stream_on : Bool
    getter transcript_on : Bool
    getter command_recording_on : Bool

    def initialize(
      @dynamic_memory : Bytes,
      @pc : Int32,
      @stack : Array(UInt16),
      @locals : Array(UInt16),
      @call_stack : Array(CallFrame),
      @rng_seed : UInt32?,
      @output : String = "",
      @arg_count : Int32 = 0,
      @resume_store_var : UInt8? = nil,
      @memory_streams : Array(Int32) = [] of Int32,
      @screen_stream_on : Bool = true,
      @transcript_on : Bool = false,
      @command_recording_on : Bool = false,
    )
    end
  end

  module Base64Converter
    def self.to_json(value : Bytes, json : JSON::Builder) : Nil
      json.string(Base64.strict_encode(value))
    end

    def self.from_json(pull : JSON::PullParser) : Bytes
      Base64.decode(pull.read_string)
    end
  end

  class VM
    DEFAULT_MAX_STEPS = 25_000

    @memory : Memory
    @header : Header
    @decoder : TextDecoder
    @parser : Parser
    @objects : ObjectTable
    @stack : Array(UInt16)
    @locals : Array(UInt16)
    @call_stack : Array(CallFrame)
    @arg_count : Int32
    @memory_streams : Array(Int32)
    @screen_stream_on : Bool
    @transcript_on : Bool
    @command_recording_on : Bool
    @transcript : String
    @recorded_commands : String
    @playback : CommandScript?
    @font : UInt16
    @initial_dynamic : Bytes
    @rng_seed : UInt32?
    @save_snapshot : SaveSnapshot?
    @undo_snapshot : SaveSnapshot?
    @auxiliary_saves : Hash(String, Bytes)
    @debug : Bool

    getter pc : Int32
    getter halted : Bool
    getter transcript : String
    getter recorded_commands : String

    # Select keyboard (0) or the command script provided by the IODevice (1).
    def select_input_stream(stream : Int32) : Nil
      case stream
      when 0
        @playback = nil
      when 1
        return if @playback
        script = @io.command_script
        @playback = CommandScript.new(script) if script
      else
        raise UnsupportedInstructionError.new("Invalid input stream #{stream}")
      end
    end

    def initialize(@story : Story, @io : IODevice = BufferIO.new, @debug : Bool = false)
      @memory = @story.memory
      @header = @story.header
      unless @header.version >= 3_u8 && @header.version <= 5_u8
        raise FormatError.new("Zink supports Z-machine versions 3, 4, and 5 (got v#{@header.version})")
      end
      @io = WindowedIO.new(@io) if @header.version >= 4
      @decoder = TextDecoder.new(@memory, @header)
      @parser = Parser.new(@memory, @header)
      @objects = ObjectTable.new(@memory, @header)
      initialize_interpreter_header
      @pc = @story.entry_pc
      @halted = false
      @stack = [] of UInt16
      @locals = Array.new(15, 0_u16)
      @call_stack = [] of CallFrame
      @arg_count = 0
      @memory_streams = [] of Int32
      @screen_stream_on = true
      @transcript_on = (@memory.read_word(0x10) & 1_u16) != 0_u16
      @command_recording_on = false
      @transcript = ""
      @recorded_commands = ""
      @playback = nil
      @font = 1_u16
      @initial_dynamic = Bytes.new(@memory.write_limit)
      @memory.bytes[0, @memory.write_limit].copy_to(@initial_dynamic)
      @rng_seed = nil
      @save_snapshot = nil
      @undo_snapshot = nil
      @auxiliary_saves = {} of String => Bytes
      @last_read_pc = @story.entry_pc
    end

    private def initialize_interpreter_header : Nil
      return if @header.version <= 3

      width = @io.screen_width.clamp(1, 255)
      height = @io.screen_height.clamp(1, 255)
      @memory.write_byte(0x1e, 6_u8) # IBM PC interpreter family
      @memory.write_byte(0x1f, 'A'.ord.to_u8)
      @memory.write_byte(0x20, height.to_u8)
      @memory.write_byte(0x21, width.to_u8)
      if @header.version >= 5
        @memory.write_word(0x22, width.to_u16)
        @memory.write_word(0x24, height.to_u16)
        @memory.write_byte(0x26, 1_u8)
        @memory.write_byte(0x27, 1_u8)
        @memory.write_byte(0x2c, 2_u8)
        @memory.write_byte(0x2d, 9_u8)
      end
      flags2 = @memory.read_word(0x10)
      @memory.write_word(0x10, flags2 & ~0x01e8_u16)
    end

    # Address of the most recent sread instruction — used by
    # export_save_for_persistence to rewind PC so that on restore
    # the VM re-executes the sread and blocks waiting for input.
    getter last_read_pc : Int32

    def worldview : Worldview
      globals = {} of UInt8 => UInt16
      16.upto(255) do |variable_number|
        globals[variable_number.to_u8] = global(variable_number.to_u8)
      end
      # Only v1-3 reserve the first global for the status-line location.
      location = @header.version <= 3 ? globals[16_u8] : 0_u16
      location_name = object_name(location)

      objects = [] of WorldObject
      1.upto(@objects.object_count) do |number|
        num = number.to_u16
        objects << WorldObject.new(
          number: num,
          name: object_name(num),
          parent: @objects.parent(num).to_u16,
          children: @objects.children(num),
          attributes: @objects.active_attributes(num),
          properties: @objects.all_properties(num),
          property_bytes: @objects.all_property_bytes(num),
        )
      end

      Worldview.new(
        location: location,
        location_name: location_name,
        objects: objects,
        globals: globals,
      )
    end

    def global(variable_number : UInt8) : UInt16
      raise ArgumentError.new("Global variable number must be 16 through 255") if variable_number < 16_u8
      read_variable(variable_number, pop_stack: false)
    end

    private def object_name(object_number : UInt16) : String
      return "" if object_number == 0_u16
      word_count = @objects.short_name_word_count(object_number)
      return "" if word_count == 0_u8
      text, _ = @decoder.decode_zstring_at(@objects.short_name_address(object_number).to_i)
      text
    end

    def export_save : SaveSnapshot
      capture_save_snapshot
    end

    # Export a snapshot with PC rewound to the last sread instruction.
    # On import + run_unbounded, the VM re-executes sread → read_line → blocks
    # waiting for input, which is the correct between-turns state.
    def export_save_for_persistence : SaveSnapshot
      snap = capture_save_snapshot
      SaveSnapshot.new(
        dynamic_memory: snap.dynamic_memory,
        pc: @last_read_pc,
        stack: snap.stack,
        locals: snap.locals,
        call_stack: snap.call_stack,
        rng_seed: snap.rng_seed,
        output: snap.output,
        arg_count: snap.arg_count,
        resume_store_var: snap.resume_store_var,
        memory_streams: snap.memory_streams,
        screen_stream_on: snap.screen_stream_on,
        transcript_on: snap.transcript_on,
        command_recording_on: snap.command_recording_on,
      )
    end

    def import_save(snapshot : SaveSnapshot) : Nil
      raise RuntimeError.new(
        "Save data size mismatch: expected #{@memory.write_limit}, got #{snapshot.dynamic_memory.size}"
      ) unless snapshot.dynamic_memory.size == @memory.write_limit

      snapshot.dynamic_memory.copy_to(@memory.bytes.to_slice[0, @memory.write_limit])
      @pc = snapshot.pc
      @stack = snapshot.stack.dup
      @locals = snapshot.locals.dup
      @call_stack = clone_call_stack(snapshot.call_stack)
      @arg_count = snapshot.arg_count
      @memory_streams = snapshot.memory_streams.dup
      @screen_stream_on = snapshot.screen_stream_on
      @transcript_on = snapshot.transcript_on
      @command_recording_on = snapshot.command_recording_on
      @rng_seed = snapshot.rng_seed
      @halted = false
    end

    def run(max_steps = DEFAULT_MAX_STEPS) : Nil
      steps = 0

      while !@halted && steps < max_steps
        step
        steps += 1
      end

      return if @halted
      raise RuntimeError.new("VM exceeded step limit (#{max_steps})")
    end

    def run_unbounded : Nil
      until @halted
        step
      end
    end

    def step : Nil
      opcode_address = @pc
      opcode = read_next_byte
      debug_log("pc=0x#{opcode_address.to_s(16).rjust(4, '0')} opcode=0x#{opcode.to_s(16).rjust(2, '0')}")

      if opcode == 0xbe_u8 && @header.version >= 5
        execute_extended(opcode_address)
        return
      end

      if opcode >= 0xb0 && opcode <= 0xbf
        execute_0op((opcode & 0x0f).to_i)
        return
      end

      case opcode
      when 0x00_u8..0x7f_u8
        execute_long_form(opcode, opcode_address)
      when 0x80_u8..0xaf_u8
        execute_short_form(opcode, opcode_address)
      else
        execute_variable_form(opcode, opcode_address)
      end
    end

    private def execute_long_form(opcode : UInt8, opcode_address : Int32) : Nil
      op = (opcode & 0x1f).to_i
      type1 = ((opcode & 0x40) == 0) ? OperandType::SmallConstant : OperandType::Variable
      type2 = ((opcode & 0x20) == 0) ? OperandType::SmallConstant : OperandType::Variable
      operands = [read_operand(type1), read_operand(type2)]
      execute_2op(op, operands, opcode_address)
    end

    private def execute_short_form(opcode : UInt8, opcode_address : Int32) : Nil
      op = (opcode & 0x0f).to_i
      type_code = ((opcode >> 4) & 0x03).to_i
      if type_code == 0x03
        raise UnsupportedInstructionError.new("Unexpected short 0OP at 0x#{opcode_address.to_s(16)}")
      end

      operand = read_operand(short_operand_type(type_code))
      execute_1op(op, operand, opcode_address)
    end

    private def execute_variable_form(opcode : UInt8, opcode_address : Int32) : Nil
      op = (opcode & 0x1f).to_i
      double_types = @header.version >= 4 && opcode == 0xec_u8 || @header.version >= 5 && opcode == 0xfa_u8
      operands = read_variable_operands(double_types)
      if opcode < 0xe0_u8
        execute_2op(op, operands, opcode_address)
      else
        execute_var(op, operands, opcode_address)
      end
    end

    private def short_operand_type(code : Int32) : OperandType
      case code
      when 0
        OperandType::LargeConstant
      when 1
        OperandType::SmallConstant
      when 2
        OperandType::Variable
      else
        raise UnsupportedInstructionError.new("Unexpected short-form operand type #{code}")
      end
    end

    private def read_variable_operands(double_types : Bool = false) : Array(Operand)
      type_specs = [read_next_byte]
      type_specs << read_next_byte if double_types
      operands = [] of Operand
      type_specs.each do |type_spec|
        {6, 4, 2, 0}.each do |shift|
          code = ((type_spec >> shift) & 0x03).to_i
          break if code == 0x03

          operand_type = short_operand_type(code)
          operands << read_operand(operand_type)
        end
      end
      operands
    end

    private def read_operand(type : OperandType) : Operand
      raw =
        case type
        when OperandType::LargeConstant
          read_next_word
        when OperandType::SmallConstant, OperandType::Variable
          read_next_byte.to_u16
        else
          raise UnsupportedInstructionError.new("Unknown operand type #{type}")
        end
      Operand.new(type, raw)
    end

    private def operand_value(operand : Operand) : UInt16
      case operand.type
      when OperandType::Variable
        read_variable(operand.raw.to_u8)
      else
        operand.raw
      end
    end

    private def operand_as_varnum(operand : Operand, op_name : String) : UInt8
      value = operand_value(operand)
      if value > 0xff_u16
        raise UnsupportedInstructionError.new("Invalid variable number for #{op_name}: #{value}")
      end
      value.to_u8
    end

    private def as_object_number(value : UInt16, op_name : String, allow_zero : Bool = false) : UInt16
      return 0_u16 if allow_zero && value == 0_u16
      maximum = @header.version <= 3 ? 255_u16 : 65535_u16
      return value if value >= 1_u16 && value <= maximum
      raise UnsupportedInstructionError.new("Invalid object number for #{op_name}: #{value}")
    end

    private def as_attribute_number(value : UInt16, op_name : String) : UInt8
      if value < @objects.attribute_count
        return value.to_u8
      end
      raise UnsupportedInstructionError.new("Invalid attribute number for #{op_name}: #{value}")
    end

    private def as_property_number(value : UInt16, op_name : String) : UInt8
      if value >= 1_u16 && value <= @objects.default_property_count
        return value.to_u8
      end
      raise UnsupportedInstructionError.new("Invalid property number for #{op_name}: #{value}")
    end

    private def wrap_u16(value : Int32) : UInt16
      (value & 0xffff).to_u16
    end

    private def read_branch : Branch
      first = read_next_byte
      branch_if_true = (first & 0x80_u8) != 0
      short_form = (first & 0x40_u8) != 0

      offset =
        if short_form
          (first & 0x3f_u8).to_i
        else
          second = read_next_byte
          raw = (((first & 0x3f_u8).to_i << 8) | second.to_i)
          raw >= 0x2000 ? raw - 0x4000 : raw
        end

      Branch.new(branch_if_true, offset)
    end

    private def apply_branch(condition : Bool, branch : Branch) : Nil
      return unless condition == branch.branch_if_true

      case branch.offset
      when 0
        return_from_routine(0_u16)
      when 1
        return_from_routine(1_u16)
      else
        @pc += branch.offset - 2
      end
    end

    private def read_variable(varnum : UInt8, pop_stack : Bool = true) : UInt16
      case varnum
      when 0_u8
        if @stack.empty?
          raise RuntimeError.new("Stack underflow")
        end
        pop_stack ? @stack.pop : @stack.last
      when 1_u8..15_u8
        @locals[varnum.to_i - 1]
      else
        globals_address = @header.globals_table.to_i + ((varnum.to_i - 16) * 2)
        @memory.read_word(globals_address)
      end
    end

    private def store_variable(varnum : UInt8, value : UInt16) : Nil
      case varnum
      when 0_u8
        @stack << value
      when 1_u8..15_u8
        @locals[varnum.to_i - 1] = value
      else
        globals_address = @header.globals_table.to_i + ((varnum.to_i - 16) * 2)
        @memory.write_word(globals_address, value)
      end
    end

    private def assign_variable(varnum : UInt8, value : UInt16) : Nil
      case varnum
      when 0_u8
        if @stack.empty?
          raise RuntimeError.new("Stack underflow")
        end
        @stack[@stack.size - 1] = value
      else
        store_variable(varnum, value)
      end
    end

    private def pop_stack : UInt16
      raise RuntimeError.new("Stack underflow") if @stack.empty?
      @stack.pop
    end

    private def read_store_variable : UInt8
      read_next_byte
    end

    private def call_routine(routine_packed_address : UInt16, args : Array(UInt16), store_var : UInt8?) : Nil
      if routine_packed_address == 0_u16
        store_variable(store_var, 0_u16) if store_var
        return
      end

      routine_address = @header.unpack_address(routine_packed_address)
      local_count = @memory.read_byte(routine_address).to_i
      if local_count > 15
        raise RuntimeError.new("Routine at 0x#{routine_address.to_s(16)} declares invalid locals count #{local_count}")
      end

      cursor = routine_address + 1
      new_locals = Array.new(15, 0_u16)

      if @header.version <= 4
        local_count.times do |index|
          new_locals[index] = @memory.read_word(cursor)
          cursor += 2
        end
      end

      args.each_with_index do |value, index|
        break if index >= local_count
        new_locals[index] = value
      end

      @call_stack << CallFrame.new(
        return_pc: @pc,
        store_variable: store_var,
        locals: @locals,
        stack_base: @stack.size,
        arg_count: @arg_count
      )

      @locals = new_locals
      @arg_count = args.size
      @pc = cursor
    end

    private def read_next_byte : UInt8
      value = @memory.read_byte(@pc)
      @pc += 1
      value
    end

    private def read_next_word : UInt16
      value = @memory.read_word(@pc)
      @pc += 2
      value
    end

    private def signed_word(value : UInt16) : Int32
      int = value.to_i
      int >= 0x8000 ? int - 0x10000 : int
    end

    private def random_in_range(range : Int32) : UInt16
      if seed = @rng_seed
        next_seed = ((seed.to_u64 * 1103515245_u64) + 12345_u64) & 0x7fffffff_u64
        @rng_seed = next_seed.to_u32
        return ((next_seed % range.to_u64) + 1).to_u16
      end

      (Random.rand(range) + 1).to_u16
    end

    private def capture_save_snapshot(resume_store_var : UInt8? = nil) : SaveSnapshot
      dynamic = Bytes.new(@memory.write_limit)
      @memory.bytes[0, @memory.write_limit].copy_to(dynamic)
      SaveSnapshot.new(
        dynamic_memory: dynamic,
        pc: @pc,
        stack: @stack.dup,
        locals: @locals.dup,
        call_stack: clone_call_stack(@call_stack),
        rng_seed: @rng_seed,
        output: @io.output_text,
        arg_count: @arg_count,
        resume_store_var: resume_store_var,
        memory_streams: @memory_streams.dup,
        screen_stream_on: @screen_stream_on,
        transcript_on: @transcript_on,
        command_recording_on: @command_recording_on,
      )
    end

    private def restore_from_snapshot : Nil
      snapshot = @save_snapshot
      return unless snapshot

      restore_snapshot(snapshot)
    end

    private def restore_snapshot(snapshot : SaveSnapshot) : Nil
      current_flags = @memory.read_word(0x10) & 0x0003_u16
      snapshot.dynamic_memory.copy_to(@memory.bytes.to_slice[0, @memory.write_limit])
      saved_flags = @memory.read_word(0x10)
      @memory.write_word(0x10, (saved_flags & ~0x0003_u16) | current_flags)
      @pc = snapshot.pc
      @stack = snapshot.stack.dup
      @locals = snapshot.locals.dup
      @call_stack = clone_call_stack(snapshot.call_stack)
      @arg_count = snapshot.arg_count
      @transcript_on = (current_flags & 1_u16) != 0_u16
      @halted = false
    end

    private def clone_call_stack(source : Array(CallFrame)) : Array(CallFrame)
      source.map do |frame|
        CallFrame.new(
          return_pc: frame.return_pc,
          store_variable: frame.store_variable,
          locals: frame.locals.dup,
          stack_base: frame.stack_base,
          arg_count: frame.arg_count
        )
      end
    end

    private def restart_vm : Nil
      preserved_flags = @memory.read_word(0x10) & 0x0003_u16
      @initial_dynamic.copy_to(@memory.bytes.to_slice[0, @memory.write_limit])
      initial_flags = @memory.read_word(0x10)
      @memory.write_word(0x10, (initial_flags & ~0x0003_u16) | preserved_flags)
      @pc = @story.entry_pc
      @stack.clear
      @locals = Array.new(15, 0_u16)
      @call_stack.clear
      @arg_count = 0
      @memory_streams.clear
      @screen_stream_on = true
      @transcript_on = (preserved_flags & 1_u16) != 0_u16
      @command_recording_on = false
      @playback = nil
      @font = 1_u16
      @io.erase_window(-1)
      @halted = false
    end

    private def zscii_to_string(zscii : Int32) : String
      return "\n" if zscii == 13
      return zscii.chr.to_s if zscii >= 32 && zscii <= 126
      "?"
    end

    private def read_input_line : {String?, Bool}
      if playback = @playback
        if line = playback.read_line
          return {line, true}
        end
        @playback = nil
      end
      {@io.read_line, false}
    end

    private def read_input_char : {Int32?, Bool}
      if playback = @playback
        if char = playback.read_char
          return {char, true}
        end
        @playback = nil
      end
      {@io.read_char, false}
    end

    private def write_output(text : String) : Nil
      @transcript_on = (@memory.read_word(0x10) & 1_u16) != 0_u16
      if table = @memory_streams.last?
        text.each_char do |char|
          length = @memory.read_word(table).to_i
          code = char == '\n' ? 13 : char.ord
          code = '?'.ord if code > 255
          @memory.write_byte(table + 2 + length, code.to_u8)
          @memory.write_word(table, (length + 1).to_u16)
        end
      elsif @screen_stream_on
        @io.write(text)
      end
      @transcript += text if @memory_streams.empty? && @transcript_on
    end

    private def set_transcript_flag(enabled : Bool) : Nil
      flags = @memory.read_word(0x10)
      @memory.write_word(0x10, enabled ? (flags | 1_u16) : (flags & ~1_u16))
    end

    private def auxiliary_name(address : UInt16) : String
      return "" if address == 0_u16
      length = @memory.read_byte(address).to_i
      String.new(@memory.bytes[address.to_i + 1, length])
    end

    private def debug_log(message : String) : Nil
      return unless @debug
      STDERR.puts("[zink] #{message}")
    end

    private def return_from_routine(value : UInt16) : Nil
      if @call_stack.empty?
        @halted = true
        return
      end

      frame = @call_stack.pop
      while @stack.size > frame.stack_base
        @stack.pop
      end

      @locals = frame.locals
      @arg_count = frame.arg_count
      @pc = frame.return_pc
      if store_var = frame.store_variable
        store_variable(store_var, value)
      end
    end
  end
end
