module Zink
  class VM
    private def execute_var(op : Int32, operands : Array(Operand), opcode_address : Int32) : Nil
      case op
      when 0, 12, 25, 26 # calls with variable argument counts
        ensure_operand_count(opcode_address, op, operands, 1)
        routine_packed = operand_value(operands[0])
        args = operands[1..].map { |operand| operand_value(operand) }
        store_var = op == 0 || op == 12 ? read_store_variable : nil
        call_routine(routine_packed, args, store_var)
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
        line, from_playback = read_input_line
        unless line
          debug_log("input EOF, halting session")
          @halted = true
          return
        end
        @recorded_commands += CommandScript.encode_line(line) if @command_recording_on && !from_playback
        @io.write("#{line}\n") if from_playback && @screen_stream_on
        @transcript += "#{line}\n" if (@memory.read_word(0x10) & 1_u16) != 0_u16
        @parser.read_into_buffers(line, text_buffer, parse_buffer)
        store_variable(read_store_variable, 13_u16) if @header.version >= 5
      when 5 # print_char
        ensure_operand_count(opcode_address, op, operands, 1)
        zscii = operand_value(operands[0]).to_i
        write_output(zscii_to_string(zscii))
      when 6 # print_num
        ensure_operand_count(opcode_address, op, operands, 1)
        value = signed_word(operand_value(operands[0]))
        write_output(value.to_s)
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
        assign_variable(varnum, pop_stack)
      when 10 # split_window
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.split_window(operand_value(operands[0]).to_i)
      when 11 # set_window
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.set_window(operand_value(operands[0]).to_i)
      when 13 # erase_window
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.erase_window(signed_word(operand_value(operands[0])))
      when 14 # erase_line
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.erase_line if operand_value(operands[0]) == 1_u16
      when 15 # set_cursor
        ensure_operand_count(opcode_address, op, operands, 2)
        @io.set_cursor(operand_value(operands[0]).to_i, operand_value(operands[1]).to_i)
      when 16 # get_cursor
        ensure_operand_count(opcode_address, op, operands, 1)
        address = operand_value(operands[0]).to_i
        row, column = @io.cursor
        @memory.write_word(address, row.to_u16)
        @memory.write_word(address + 2, column.to_u16)
      when 17 # set_text_style
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.set_text_style(operand_value(operands[0]).to_i)
      when 18 # buffer_mode
        ensure_operand_count(opcode_address, op, operands, 1)
        @io.buffer_mode(operand_value(operands[0]) != 0_u16)
      when 19 # output_stream
        ensure_operand_count(opcode_address, op, operands, 1)
        stream = signed_word(operand_value(operands[0]))
        case stream
        when 1
          @screen_stream_on = true
        when -1
          @screen_stream_on = false
        when 3
          ensure_operand_count(opcode_address, op, operands, 2)
          table = operand_value(operands[1]).to_i
          raise RuntimeError.new("Output stream 3 nesting limit exceeded") if @memory_streams.size >= 16
          @memory.write_word(table, 0_u16)
          @memory_streams << table
        when -3
          raise RuntimeError.new("Output stream 3 is not active") if @memory_streams.empty?
          @memory_streams.pop
        when 2
          @transcript_on = true
          set_transcript_flag(true)
        when -2
          @transcript_on = false
          set_transcript_flag(false)
        when 4
          @command_recording_on = true
        when -4
          @command_recording_on = false
        else
          raise UnsupportedInstructionError.new("Invalid output stream #{stream}")
        end
      when 20 # input_stream
        ensure_operand_count(opcode_address, op, operands, 1)
        select_input_stream(operand_value(operands[0]).to_i)
      when 21 # sound_effect
        operands.each { |operand| operand_value(operand) }
      when 22 # read_char
        ensure_operand_count(opcode_address, op, operands, 1)
        operands.each { |operand| operand_value(operand) }
        @last_read_pc = opcode_address
        char, from_playback = read_input_char
        unless char
          @halted = true
          return
        end
        @recorded_commands += CommandScript.encode_char(char) if @command_recording_on && !from_playback
        @transcript += char == 13 ? "\n" : char.chr.to_s if (@memory.read_word(0x10) & 1_u16) != 0_u16
        store_variable(read_store_variable, char.to_u16)
      when 23 # scan_table
        ensure_operand_count(opcode_address, op, operands, 3)
        sought = operand_value(operands[0])
        base = operand_value(operands[1]).to_i
        length = operand_value(operands[2]).to_i
        form = operands.size >= 4 ? operand_value(operands[3]).to_i : 0x82
        stride = form & 0x7f
        raise RuntimeError.new("scan_table has zero stride") if stride == 0
        found = 0_u16
        length.times do |index|
          address = base + index * stride
          candidate = (form & 0x80) != 0 ? @memory.read_word(address) : @memory.read_byte(address).to_u16
          if candidate == sought
            found = address.to_u16
            break
          end
        end
        store_variable(read_store_variable, found)
        apply_branch(found != 0_u16, read_branch)
      when 24 # not (v5+)
        ensure_operand_count(opcode_address, op, operands, 1)
        store_variable(read_store_variable, (~operand_value(operands[0])).to_u16)
      when 27 # tokenise
        ensure_operand_count(opcode_address, op, operands, 2)
        text_buffer = operand_value(operands[0])
        parse_buffer = operand_value(operands[1])
        dictionary = operands.size >= 3 ? operand_value(operands[2]) : 0_u16
        skip_unknown = operands.size >= 4 && operand_value(operands[3]) != 0_u16
        @parser.tokenise(text_buffer, parse_buffer, dictionary, skip_unknown)
      when 28 # encode_text
        ensure_operand_count(opcode_address, op, operands, 4)
        source = operand_value(operands[0]).to_i
        length = operand_value(operands[1]).to_i
        offset = operand_value(operands[2]).to_i
        destination = operand_value(operands[3]).to_i
        token = String.new(@memory.bytes[source + offset, length]).downcase
        @parser.encode_dictionary_key(token).each_with_index do |byte, index|
          @memory.write_byte(destination + index, byte)
        end
      when 29 # copy_table
        ensure_operand_count(opcode_address, op, operands, 3)
        source = operand_value(operands[0]).to_i
        destination = operand_value(operands[1]).to_i
        signed_size = signed_word(operand_value(operands[2]))
        size = signed_size.abs
        if destination == 0
          size.times { |index| @memory.write_byte(source + index, 0_u8) }
        elsif signed_size > 0 && destination > source && destination < source + size
          (size - 1).downto(0) do |index|
            @memory.write_byte(destination + index, @memory.read_byte(source + index))
          end
        else
          size.times do |index|
            @memory.write_byte(destination + index, @memory.read_byte(source + index))
          end
        end
      when 30 # print_table
        ensure_operand_count(opcode_address, op, operands, 2)
        source = operand_value(operands[0]).to_i
        width = operand_value(operands[1]).to_i
        height = operands.size >= 3 ? operand_value(operands[2]).to_i : 1
        skip = operands.size >= 4 ? operand_value(operands[3]).to_i : 0
        height.times do |row|
          write_output("\n") if row > 0
          width.times do |column|
            code = @memory.read_byte(source + row * (width + skip) + column).to_i
            write_output(zscii_to_string(code))
          end
        end
      when 31 # check_arg_count
        ensure_operand_count(opcode_address, op, operands, 1)
        requested = operand_value(operands[0]).to_i
        apply_branch(requested >= 1 && requested <= @arg_count, read_branch)
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
  end
end
