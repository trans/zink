module Zink
  class VM
    private def execute_0op(op : Int32) : Nil
      case op
      when 0 # rtrue
        return_from_routine(1_u16)
      when 1 # rfalse
        return_from_routine(0_u16)
      when 2 # print
        text, next_pc = @decoder.decode_zstring_at(@pc)
        @pc = next_pc
        write_output(text)
      when 3 # print_ret
        text, next_pc = @decoder.decode_zstring_at(@pc)
        @pc = next_pc
        write_output(text)
        write_output("\n")
        return_from_routine(1_u16)
      when 4 # nop
        nil
      when 5 # save
        if @header.version == 3
          branch = read_branch
          @save_snapshot = capture_save_snapshot
          debug_log("save snapshot captured")
          apply_branch(true, branch)
        elsif @header.version == 4
          store_var = read_store_variable
          @save_snapshot = capture_save_snapshot(store_var)
          store_variable(store_var, 1_u16)
        else
          raise UnsupportedInstructionError.new("0OP save is not valid in v5")
        end
      when 6 # restore
        if @header.version == 3
          read_branch
          restore_from_snapshot
          debug_log("restore attempted")
        elsif @header.version == 4
          store_var = read_store_variable
          if snapshot = @save_snapshot
            restore_snapshot(snapshot)
            if resume_var = snapshot.resume_store_var
              store_variable(resume_var, 2_u16)
            end
          else
            store_variable(store_var, 0_u16)
          end
        else
          raise UnsupportedInstructionError.new("0OP restore is not valid in v5")
        end
      when 7 # restart
        debug_log("restart")
        restart_vm
      when 8 # ret_popped
        return_from_routine(pop_stack)
      when 9 # pop
        if @header.version >= 5
          store_variable(read_store_variable, @call_stack.size.to_u16)
        else
          pop_stack
        end
      when 10 # quit
        @halted = true
      when 11 # new_line
        write_output("\n")
      when 12 # show_status
        # Status line rendering is a UI concern; no-op in this interpreter.
        nil
      when 13 # verify
        apply_branch(@story.checksum_valid?, read_branch)
      when 15 # piracy
        apply_branch(true, read_branch)
      else
        raise UnsupportedInstructionError.new("Unsupported 0OP opcode #{op} at 0x#{(@pc - 1).to_s(16)}")
      end
    end
  end
end
