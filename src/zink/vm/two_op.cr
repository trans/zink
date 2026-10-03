module Zink
  class VM
    private def execute_2op(op : Int32, operands : Array(Operand), opcode_address : Int32) : Nil
      case op
      when 1 # je
        ensure_operand_count(opcode_address, op, operands, 2)
        values = operands.map { |operand| operand_value(operand) }
        left = values[0]
        match = values[1..].any? { |candidate| candidate == left }
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
        apply_branch(@objects.parent(object) == parent, read_branch)
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
        assign_variable(varnum, value)
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
        store_variable(read_store_variable, wrap_u16(dividend.tdiv(divisor)))
      when 24 # mod
        ensure_operand_count(opcode_address, op, operands, 2)
        divisor = signed_word(operand_value(operands[1]))
        raise RuntimeError.new("Division by zero") if divisor == 0
        dividend = signed_word(operand_value(operands[0]))
        quotient = dividend.tdiv(divisor)
        store_variable(read_store_variable, wrap_u16(dividend - quotient * divisor))
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
      when 27 # set_colour
        ensure_operand_count(opcode_address, op, operands, 2)
        @io.set_colour(signed_word(operand_value(operands[0])), signed_word(operand_value(operands[1])))
      when 28 # throw
        ensure_operand_count(opcode_address, op, operands, 2)
        value = operand_value(operands[0])
        frame_number = operand_value(operands[1]).to_i
        raise RuntimeError.new("Invalid stack frame #{frame_number}") if frame_number < 1 || frame_number > @call_stack.size
        while @call_stack.size > frame_number
          frame = @call_stack.pop
          while @stack.size > frame.stack_base
            @stack.pop
          end
          @locals = frame.locals
          @arg_count = frame.arg_count
        end
        return_from_routine(value)
      else
        raise UnsupportedInstructionError.new("Unsupported 2OP opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end
  end
end
