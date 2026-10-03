module Zink
  class VM
    private def execute_extended(opcode_address : Int32) : Nil
      op = read_next_byte.to_i
      operands = read_variable_operands
      case op
      when 0, 9 # save, save_undo
        values = operands.map { |operand| operand_value(operand) }
        store_var = read_store_variable
        if values.empty?
          snapshot = capture_save_snapshot(store_var)
          if op == 0
            @save_snapshot = snapshot
          else
            @undo_snapshot = snapshot
          end
          store_variable(store_var, 1_u16)
        elsif op == 0 && values.size >= 2
          table = values[0].to_i
          length = values[1].to_i
          name = auxiliary_name(values[2]? || 0_u16)
          copy = Bytes.new(length) { |index| @memory.read_byte(table + index) }
          @auxiliary_saves[name] = copy
          store_variable(store_var, length.to_u16)
        else
          store_variable(store_var, 0_u16)
        end
      when 1, 10 # restore, restore_undo
        values = operands.map { |operand| operand_value(operand) }
        store_var = read_store_variable
        snapshot = op == 1 ? @save_snapshot : @undo_snapshot
        if snapshot && values.empty?
          restore_snapshot(snapshot)
          if resume_var = snapshot.resume_store_var
            store_variable(resume_var, 2_u16)
          end
        elsif op == 1 && values.size >= 2
          table = values[0].to_i
          length = values[1].to_i
          name = auxiliary_name(values[2]? || 0_u16)
          if copy = @auxiliary_saves[name]?
            copied = Math.min(length, copy.size)
            copied.times { |index| @memory.write_byte(table + index, copy[index]) }
            store_variable(store_var, copied.to_u16)
          else
            store_variable(store_var, 0_u16)
          end
        else
          store_variable(store_var, 0_u16)
        end
      when 2, 3 # logical and arithmetic shifts
        ensure_operand_count(opcode_address, op, operands, 2)
        number = operand_value(operands[0])
        places = signed_word(operand_value(operands[1]))
        value = if op == 2
                  places >= 0 ? wrap_u16(number.to_i << places) : (number >> -places).to_u16
                else
                  signed = signed_word(number)
                  places >= 0 ? wrap_u16(signed << places) : wrap_u16(signed >> -places)
                end
        store_variable(read_store_variable, value)
      when 4 # set_font
        ensure_operand_count(opcode_address, op, operands, 1)
        requested = operand_value(operands[0])
        previous = @font
        result = if requested == 0_u16
                   previous
                 elsif requested == 1_u16
                   @font = requested
                   previous
                 else
                   0_u16
                 end
        store_variable(read_store_variable, result)
      when 11 # print_unicode
        ensure_operand_count(opcode_address, op, operands, 1)
        code = operand_value(operands[0]).to_i
        write_output(code.chr.to_s)
      when 12 # check_unicode
        ensure_operand_count(opcode_address, op, operands, 1)
        code = operand_value(operands[0]).to_i
        store_variable(read_store_variable, (code >= 32 && code <= 126 ? 3 : 0).to_u16)
      when 13 # set_true_colour
        operands.each { |operand| operand_value(operand) }
      else
        return if op >= 29
        raise UnsupportedInstructionError.new("Unsupported EXT opcode #{op} at 0x#{opcode_address.to_s(16)}")
      end
    end
  end
end
