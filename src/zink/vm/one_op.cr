module Zink
  class VM
    private def execute_1op(op : Int32, operand : Operand, opcode_address : Int32) : Nil
      case op
      when 0 # jz
        branch = read_branch
        apply_branch(operand_value(operand) == 0_u16, branch)
      when 1 # get_sibling
        object = as_object_number(operand_value(operand), "get_sibling")
        sibling = @objects.sibling(object)
        store_variable(read_store_variable, sibling.to_u16)
        apply_branch(sibling != 0_u16, read_branch)
      when 2 # get_child
        object = as_object_number(operand_value(operand), "get_child")
        child = @objects.child(object)
        store_variable(read_store_variable, child.to_u16)
        apply_branch(child != 0_u16, read_branch)
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
        write_output(text)
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
          write_output(text)
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
        write_output(text)
      when 14 # load
        varnum = operand_as_varnum(operand, "load")
        value = read_variable(varnum, pop_stack: false)
        store_variable(read_store_variable, value)
      when 15 # not
        if @header.version >= 5
          call_routine(operand_value(operand), [] of UInt16, nil)
        else
          value = operand_value(operand)
          store_variable(read_store_variable, (~value).to_u16)
        end
      when 11 # ret
        return_from_routine(operand_value(operand))
      else
        raise UnsupportedInstructionError.new("Unsupported 1OP opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end
  end
end
