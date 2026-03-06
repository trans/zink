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

    def initialize(@return_pc : Int32, @store_variable : UInt8?, @locals : Array(UInt16), @stack_base : Int32)
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

    def initialize(
      @dynamic_memory : Bytes,
      @pc : Int32,
      @stack : Array(UInt16),
      @locals : Array(UInt16),
      @call_stack : Array(CallFrame),
      @rng_seed : UInt32?,
      @output : String = "",
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
    @initial_dynamic : Bytes
    @rng_seed : UInt32?
    @save_snapshot : SaveSnapshot?
    @debug : Bool

    getter pc : Int32
    getter halted : Bool

    def initialize(@story : Story, @io : IODevice = BufferIO.new, @debug : Bool = false)
      @memory = @story.memory
      @header = @story.header
      @decoder = TextDecoder.new(@memory, @header)
      @parser = Parser.new(@memory, @header)
      @objects = ObjectTable.new(@memory, @header)
      @pc = @story.entry_pc
      @halted = false
      @stack = [] of UInt16
      @locals = Array.new(15, 0_u16)
      @call_stack = [] of CallFrame
      @initial_dynamic = Bytes.new(@memory.write_limit)
      @memory.bytes[0, @memory.write_limit].copy_to(@initial_dynamic)
      @rng_seed = nil
      @save_snapshot = nil
      @last_read_pc = @story.entry_pc
    end

    # Address of the most recent sread instruction — used by
    # export_save_for_persistence to rewind PC so that on restore
    # the VM re-executes the sread and blocks waiting for input.
    getter last_read_pc : Int32

    def worldview : Worldview
      location = read_variable(16_u8, pop_stack: false)
      location_name = object_name(location)

      objects = [] of WorldObject
      1_u16.upto(255_u16) do |num|
        begin
          parent_num = @objects.parent(num)
        rescue
          break
        end
        # Skip objects with no property table (uninitialized)
        prop_table = @objects.property_table_address(num)
        break if prop_table == 0_u16

        objects << WorldObject.new(
          number: num,
          name: object_name(num),
          parent: parent_num.to_u16,
          children: @objects.children(num),
          attributes: @objects.active_attributes(num),
          properties: @objects.all_properties(num),
        )
      end

      Worldview.new(
        location: location,
        location_name: location_name,
        objects: objects,
      )
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
      operands = read_variable_operands
      if opcode < 0xe0_u8
        execute_2op(op, operands, opcode_address)
      else
        execute_var(op, operands, opcode_address)
      end
    end

    private def execute_2op(op : Int32, operands : Array(Operand), opcode_address : Int32) : Nil
      case op
      when 1 # je
        ensure_operand_count(opcode_address, op, operands, 2)
        left = operand_value(operands[0])
        match = operands[1..].any? { |candidate| operand_value(candidate) == left }
        branch = read_branch
        apply_branch(match, branch)
      when 2 # jl
        ensure_operand_count(opcode_address, op, operands, 2)
        left = signed_word(operand_value(operands[0]))
        right = signed_word(operand_value(operands[1]))
        apply_branch(left < right, read_branch)
      when 3 # jg
        ensure_operand_count(opcode_address, op, operands, 2)
        left = signed_word(operand_value(operands[0]))
        right = signed_word(operand_value(operands[1]))
        apply_branch(left > right, read_branch)
      when 4 # dec_chk
        ensure_operand_count(opcode_address, op, operands, 2)
        varnum = operand_as_varnum(operands[0], "dec_chk")
        updated = wrap_u16(signed_word(read_variable(varnum, pop_stack: false)) - 1)
        assign_variable(varnum, updated)
        compare_to = signed_word(operand_value(operands[1]))
        apply_branch(signed_word(updated) < compare_to, read_branch)
      when 5 # inc_chk
        ensure_operand_count(opcode_address, op, operands, 2)
        varnum = operand_as_varnum(operands[0], "inc_chk")
        updated = wrap_u16(signed_word(read_variable(varnum, pop_stack: false)) + 1)
        assign_variable(varnum, updated)
        compare_to = signed_word(operand_value(operands[1]))
        apply_branch(signed_word(updated) > compare_to, read_branch)
      when 6 # jin
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "jin")
        parent = as_object_number(operand_value(operands[1]), "jin", allow_zero: true)
        apply_branch(@objects.parent(object).to_u16 == parent, read_branch)
      when 7 # test
        ensure_operand_count(opcode_address, op, operands, 2)
        flags = operand_value(operands[0])
        mask = operand_value(operands[1])
        apply_branch((flags & mask) == mask, read_branch)
      when 8 # or
        ensure_operand_count(opcode_address, op, operands, 2)
        left = operand_value(operands[0])
        right = operand_value(operands[1])
        store_variable(read_store_variable, (left | right).to_u16)
      when 9 # and
        ensure_operand_count(opcode_address, op, operands, 2)
        left = operand_value(operands[0])
        right = operand_value(operands[1])
        store_variable(read_store_variable, (left & right).to_u16)
      when 10 # test_attr
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "test_attr")
        attribute = as_attribute_number(operand_value(operands[1]), "test_attr")
        apply_branch(@objects.test_attribute(object, attribute), read_branch)
      when 11 # set_attr
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "set_attr")
        attribute = as_attribute_number(operand_value(operands[1]), "set_attr")
        @objects.set_attribute(object, attribute)
      when 12 # clear_attr
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "clear_attr")
        attribute = as_attribute_number(operand_value(operands[1]), "clear_attr")
        @objects.clear_attribute(object, attribute)
      when 13 # store
        ensure_operand_count(opcode_address, op, operands, 2)
        varnum = operand_as_varnum(operands[0], "store")
        value = operand_value(operands[1])
        store_variable(varnum, value)
      when 14 # insert_obj
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "insert_obj")
        destination = as_object_number(operand_value(operands[1]), "insert_obj")
        @objects.insert_object(object, destination)
      when 15 # loadw
        ensure_operand_count(opcode_address, op, operands, 2)
        base = operand_value(operands[0]).to_i
        word_index = operand_value(operands[1]).to_i
        value = @memory.read_word(base + (word_index * 2))
        store_variable(read_store_variable, value)
      when 16 # loadb
        ensure_operand_count(opcode_address, op, operands, 2)
        base = operand_value(operands[0]).to_i
        byte_index = operand_value(operands[1]).to_i
        value = @memory.read_byte(base + byte_index).to_u16
        store_variable(read_store_variable, value)
      when 17 # get_prop
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "get_prop")
        property = as_property_number(operand_value(operands[1]), "get_prop")
        value = @objects.get_property(object, property)
        store_variable(read_store_variable, value)
      when 18 # get_prop_addr
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "get_prop_addr")
        property = as_property_number(operand_value(operands[1]), "get_prop_addr")
        value = @objects.get_property_address(object, property)
        store_variable(read_store_variable, value)
      when 19 # get_next_prop
        ensure_operand_count(opcode_address, op, operands, 2)
        object = as_object_number(operand_value(operands[0]), "get_next_prop")
        property_raw = operand_value(operands[1])
        property = property_raw == 0_u16 ? 0_u8 : as_property_number(property_raw, "get_next_prop")
        value = @objects.get_next_property_number(object, property).to_u16
        store_variable(read_store_variable, value)
      when 20 # add
        ensure_operand_count(opcode_address, op, operands, 2)
        left = operand_value(operands[0]).to_i
        right = operand_value(operands[1]).to_i
        store_variable(read_store_variable, wrap_u16(left + right))
      when 21 # sub
        ensure_operand_count(opcode_address, op, operands, 2)
        left = operand_value(operands[0]).to_i
        right = operand_value(operands[1]).to_i
        store_variable(read_store_variable, wrap_u16(left - right))
      when 22 # mul
        ensure_operand_count(opcode_address, op, operands, 2)
        left = signed_word(operand_value(operands[0]))
        right = signed_word(operand_value(operands[1]))
        store_variable(read_store_variable, wrap_u16(left * right))
      when 23 # div
        ensure_operand_count(opcode_address, op, operands, 2)
        divisor = signed_word(operand_value(operands[1]))
        raise RuntimeError.new("Division by zero") if divisor == 0
        dividend = signed_word(operand_value(operands[0]))
        store_variable(read_store_variable, wrap_u16(dividend // divisor))
      when 24 # mod
        ensure_operand_count(opcode_address, op, operands, 2)
        divisor = signed_word(operand_value(operands[1]))
        raise RuntimeError.new("Division by zero") if divisor == 0
        dividend = signed_word(operand_value(operands[0]))
        store_variable(read_store_variable, wrap_u16(dividend % divisor))
      when 25 # call_2s
        ensure_operand_count(opcode_address, op, operands, 2)
        routine_packed = operand_value(operands[0])
        arg1 = operand_value(operands[1])
        call_routine(routine_packed, [arg1], read_store_variable)
      when 26 # call_2n
        ensure_operand_count(opcode_address, op, operands, 2)
        routine_packed = operand_value(operands[0])
        arg1 = operand_value(operands[1])
        call_routine(routine_packed, [arg1], nil)
      else
        raise UnsupportedInstructionError.new("Unsupported 2OP opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end

    private def execute_1op(op : Int32, operand : Operand, opcode_address : Int32) : Nil
      case op
      when 0 # jz
        branch = read_branch
        apply_branch(operand_value(operand) == 0_u16, branch)
      when 1 # get_sibling
        object = as_object_number(operand_value(operand), "get_sibling")
        sibling = @objects.sibling(object)
        store_variable(read_store_variable, sibling.to_u16)
        apply_branch(sibling != 0_u8, read_branch)
      when 2 # get_child
        object = as_object_number(operand_value(operand), "get_child")
        child = @objects.child(object)
        store_variable(read_store_variable, child.to_u16)
        apply_branch(child != 0_u8, read_branch)
      when 3 # get_parent
        object = as_object_number(operand_value(operand), "get_parent")
        parent = @objects.parent(object)
        store_variable(read_store_variable, parent.to_u16)
      when 4 # get_prop_len
        prop_addr = operand_value(operand)
        length = @objects.property_length(prop_addr)
        store_variable(read_store_variable, length.to_u16)
      when 7 # print_addr
        address = operand_value(operand).to_i
        text, _next_pc = @decoder.decode_zstring_at(address)
        @io.write(text)
      when 8 # call_1s
        routine_packed = operand_value(operand)
        call_routine(routine_packed, [] of UInt16, read_store_variable)
      when 9 # remove_obj
        object = as_object_number(operand_value(operand), "remove_obj")
        @objects.remove_object(object)
      when 10 # print_obj
        object = as_object_number(operand_value(operand), "print_obj")
        if @objects.short_name_word_count(object) > 0_u8
          text, _next_pc = @decoder.decode_zstring_at(@objects.short_name_address(object).to_i)
          @io.write(text)
        end
      when 5 # inc
        varnum = operand_as_varnum(operand, "inc")
        current = read_variable(varnum, pop_stack: false)
        assign_variable(varnum, wrap_u16(current.to_i + 1))
      when 6 # dec
        varnum = operand_as_varnum(operand, "dec")
        current = read_variable(varnum, pop_stack: false)
        assign_variable(varnum, wrap_u16(current.to_i - 1))
      when 12 # jump
        offset = signed_word(operand_value(operand))
        @pc += offset - 2
      when 13 # print_paddr
        packed = operand_value(operand)
        address = @header.unpack_address(packed)
        text, _next_pc = @decoder.decode_zstring_at(address)
        @io.write(text)
      when 14 # load
        varnum = operand_as_varnum(operand, "load")
        value = read_variable(varnum, pop_stack: false)
        store_variable(read_store_variable, value)
      when 15 # not
        value = operand_value(operand)
        store_variable(read_store_variable, (~value).to_u16)
      when 11 # ret
        return_from_routine(operand_value(operand))
      else
        raise UnsupportedInstructionError.new("Unsupported 1OP opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end

    private def execute_var(op : Int32, operands : Array(Operand), opcode_address : Int32) : Nil
      case op
      when 0 # call_vs
        ensure_operand_count(opcode_address, op, operands, 1)
        routine_packed = operand_value(operands[0])
        args = operands[1..].map { |operand| operand_value(operand) }
        call_routine(routine_packed, args, read_store_variable)
      when 1 # storew
        ensure_operand_count(opcode_address, op, operands, 3)
        array = operand_value(operands[0]).to_i
        word_index = operand_value(operands[1]).to_i
        value = operand_value(operands[2])
        @memory.write_word(array + (word_index * 2), value)
      when 2 # storeb
        ensure_operand_count(opcode_address, op, operands, 3)
        array = operand_value(operands[0]).to_i
        byte_index = operand_value(operands[1]).to_i
        value = operand_value(operands[2])
        @memory.write_byte(array + byte_index, (value & 0xff).to_u8)
      when 3 # put_prop
        ensure_operand_count(opcode_address, op, operands, 3)
        object = as_object_number(operand_value(operands[0]), "put_prop")
        property = as_property_number(operand_value(operands[1]), "put_prop")
        value = operand_value(operands[2])
        @objects.put_property(object, property, value)
      when 4 # sread/read
        ensure_operand_count(opcode_address, op, operands, 2)
        text_buffer = operand_value(operands[0])
        parse_buffer = operand_value(operands[1])
        @last_read_pc = opcode_address
        line = @io.read_line
        unless line
          debug_log("input EOF, halting session")
          @halted = true
          return
        end
        @parser.read_into_buffers(line, text_buffer, parse_buffer)
      when 5 # print_char
        ensure_operand_count(opcode_address, op, operands, 1)
        zscii = operand_value(operands[0]).to_i
        @io.write(zscii_to_string(zscii))
      when 6 # print_num
        ensure_operand_count(opcode_address, op, operands, 1)
        value = signed_word(operand_value(operands[0]))
        @io.write(value.to_s)
      when 7 # random
        ensure_operand_count(opcode_address, op, operands, 1)
        range = signed_word(operand_value(operands[0]))
        value =
          if range > 0
            random_in_range(range)
          elsif range < 0
            @rng_seed = (-range).to_u32
            debug_log("random seed set to #{@rng_seed}")
            0_u16
          else
            @rng_seed = nil
            debug_log("random seed cleared")
            0_u16
          end
        store_variable(read_store_variable, value)
      when 8 # push
        ensure_operand_count(opcode_address, op, operands, 1)
        @stack << operand_value(operands[0])
      when 9 # pull
        ensure_operand_count(opcode_address, op, operands, 1)
        varnum = operand_as_varnum(operands[0], "pull")
        store_variable(varnum, pop_stack)
      else
        raise UnsupportedInstructionError.new("Unsupported VAR opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end

    private def ensure_operand_count(
      opcode_address : Int32,
      opcode_number : Int32,
      operands : Array(Operand),
      min_count : Int32,
    ) : Nil
      return if operands.size >= min_count

      raise UnsupportedInstructionError.new(
        "Opcode #{opcode_number} at 0x#{opcode_address.to_s(16)} expected #{min_count} operands, got #{operands.size}"
      )
    end

    private def execute_0op(op : Int32) : Nil
      case op
      when 0 # rtrue
        return_from_routine(1_u16)
      when 1 # rfalse
        return_from_routine(0_u16)
      when 2 # print
        text, next_pc = @decoder.decode_zstring_at(@pc)
        @pc = next_pc
        @io.write(text)
      when 3 # print_ret
        text, next_pc = @decoder.decode_zstring_at(@pc)
        @pc = next_pc
        @io.write(text)
        @io.write("\n")
        return_from_routine(1_u16)
      when 4 # nop
        nil
      when 5 # save
        if @header.version <= 3
          branch = read_branch
          @save_snapshot = capture_save_snapshot
          debug_log("save snapshot captured")
          apply_branch(true, branch)
        else
          raise UnsupportedInstructionError.new("save is only implemented for v1-3")
        end
      when 6 # restore
        if @header.version <= 3
          _branch = read_branch
          restore_from_snapshot
          debug_log("restore attempted")
        else
          raise UnsupportedInstructionError.new("restore is only implemented for v1-3")
        end
      when 7 # restart
        debug_log("restart")
        restart_vm
      when 8 # ret_popped
        return_from_routine(pop_stack)
      when 9 # pop
        pop_stack
      when 10 # quit
        @halted = true
      when 11 # new_line
        @io.write("\n")
      when 12 # show_status
        # Status line rendering is a UI concern; no-op in this interpreter.
        nil
      when 13 # verify
        apply_branch(@story.checksum_valid?, read_branch)
      else
        raise UnsupportedInstructionError.new("Unsupported 0OP opcode #{op} at 0x#{(@pc - 1).to_s(16)}")
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

    private def read_variable_operands : Array(Operand)
      type_spec = read_next_byte
      operands = [] of Operand
      {6, 4, 2, 0}.each do |shift|
        code = ((type_spec >> shift) & 0x03).to_i
        break if code == 0x03

        operand_type = short_operand_type(code)
        operands << read_operand(operand_type)
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
      if operand.raw > 0xff_u16
        raise UnsupportedInstructionError.new("Invalid variable number for #{op_name}: #{operand.raw}")
      end
      operand.raw.to_u8
    end

    private def as_object_number(value : UInt16, op_name : String, allow_zero : Bool = false) : UInt16
      return 0_u16 if allow_zero && value == 0_u16
      return value if value >= 1_u16 && value <= 255_u16
      raise UnsupportedInstructionError.new("Invalid object number for #{op_name}: #{value}")
    end

    private def as_attribute_number(value : UInt16, op_name : String) : UInt8
      if value <= 31_u16
        return value.to_u8
      end
      raise UnsupportedInstructionError.new("Invalid attribute number for #{op_name}: #{value}")
    end

    private def as_property_number(value : UInt16, op_name : String) : UInt8
      if value >= 1_u16 && value <= 31_u16
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
        stack_base: @stack.size
      )

      @locals = new_locals
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

    private def capture_save_snapshot : SaveSnapshot
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
      )
    end

    private def restore_from_snapshot : Nil
      snapshot = @save_snapshot
      return unless snapshot

      snapshot.dynamic_memory.copy_to(@memory.bytes.to_slice[0, @memory.write_limit])
      @pc = snapshot.pc
      @stack = snapshot.stack.dup
      @locals = snapshot.locals.dup
      @call_stack = clone_call_stack(snapshot.call_stack)
      @rng_seed = snapshot.rng_seed
      @halted = false
    end

    private def clone_call_stack(source : Array(CallFrame)) : Array(CallFrame)
      source.map do |frame|
        CallFrame.new(
          return_pc: frame.return_pc,
          store_variable: frame.store_variable,
          locals: frame.locals.dup,
          stack_base: frame.stack_base
        )
      end
    end

    private def restart_vm : Nil
      @initial_dynamic.copy_to(@memory.bytes.to_slice[0, @memory.write_limit])
      @pc = @story.entry_pc
      @stack.clear
      @locals = Array.new(15, 0_u16)
      @call_stack.clear
      @halted = false
    end

    private def zscii_to_string(zscii : Int32) : String
      return "\n" if zscii == 13
      return zscii.chr.to_s if zscii >= 32 && zscii <= 126
      "?"
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
      @pc = frame.return_pc
      if store_var = frame.store_variable
        store_variable(store_var, value)
      end
    end
  end
end
