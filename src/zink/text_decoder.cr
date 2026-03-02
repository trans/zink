module Zink
  class TextDecoder
    A0 = "abcdefghijklmnopqrstuvwxyz"
    A1 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    A2 = " ^0123456789.,!?_#'\"/\\-:()"

    def initialize(@memory : Memory, @header : Header)
    end

    def decode_zstring_at(address : Int32, depth : Int32 = 0) : {String, Int32}
      zchars = [] of UInt8
      pointer = address

      loop do
        word = @memory.read_word(pointer).to_u16
        pointer += 2

        zchars << ((word >> 10) & 0x1f).to_u8
        zchars << ((word >> 5) & 0x1f).to_u8
        zchars << (word & 0x1f).to_u8

        break if (word & 0x8000) != 0
      end

      {decode_zchars(zchars, depth), pointer}
    end

    private def decode_zchars(zchars : Array(UInt8), depth : Int32) : String
      output = String::Builder.new
      temporary_alphabet : Int32? = nil
      i = 0

      while i < zchars.size
        z = zchars[i].to_i

        case z
        when 0
          output << ' '
        when 1, 2, 3
          if i + 1 < zchars.size && depth < 3
            abbreviation_index = 32 * (z - 1) + zchars[i + 1].to_i
            output << decode_abbreviation(abbreviation_index, depth + 1)
            i += 1
          end
        when 4
          temporary_alphabet = 1
        when 5
          temporary_alphabet = 2
        else
          alphabet = temporary_alphabet || 0
          if alphabet == 2 && z == 6
            if i + 2 < zchars.size
              zscii = ((zchars[i + 1].to_i & 0x1f) << 5) | (zchars[i + 2].to_i & 0x1f)
              output << zscii_to_char(zscii)
              i += 2
            end
          else
            output << alphabet_char(alphabet, z)
          end
          temporary_alphabet = nil
        end

        i += 1
      end

      output.to_s
    end

    private def decode_abbreviation(index : Int32, depth : Int32) : String
      table_addr = @header.abbreviations_table.to_i
      return "" if table_addr == 0

      entry_address = table_addr + (index * 2)
      packed = @memory.read_word(entry_address)
      expanded_addr = @header.unpack_address(packed)
      text, _next_pc = decode_zstring_at(expanded_addr, depth)
      text
    end

    private def alphabet_char(alphabet : Int32, zchar : Int32) : Char
      return '?' if zchar < 6 || zchar > 31

      # In v1-3 A2 alphabet, zchar 7 is newline.
      return '\n' if alphabet == 2 && zchar == 7

      index = zchar - 6
      source =
        case alphabet
        when 0
          A0
        when 1
          A1
        else
          A2
        end

      source[index]? || '?'
    end

    private def zscii_to_char(code : Int32) : Char
      return '\n' if code == 13
      return code.chr if code >= 32 && code <= 126
      '?'
    end
  end
end
