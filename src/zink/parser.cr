module Zink
  class Parser
    private struct DictionaryInfo
      getter separators : Set(Char)
      getter entry_length : Int32
      getter entry_count : Int32
      getter entries_address : Int32

      def initialize(
        @separators : Set(Char),
        @entry_length : Int32,
        @entry_count : Int32,
        @entries_address : Int32,
      )
      end
    end

    private struct Token
      getter text : String
      getter start : Int32
      getter length : Int32

      def initialize(@text : String, @start : Int32, @length : Int32)
      end
    end

    A2 = " ^0123456789.,!?_#'\"/\\-:()"

    def initialize(@memory : Memory, @header : Header)
    end

    def read_into_buffers(line : String, text_buffer_addr : UInt16, parse_buffer_addr : UInt16) : Nil
      normalized = normalize_input(line)
      buffer_text = write_text_buffer(normalized, text_buffer_addr.to_i)
      return if parse_buffer_addr == 0_u16

      write_parse_buffer(buffer_text, parse_buffer_addr.to_i)
    end

    def self.encode_dictionary_key(token : String, version : UInt8) : Bytes
      encoded_chars = version <= 3 ? 6 : 9
      word_count = encoded_chars // 3
      zchars = [] of UInt8

      token.each_char do |char|
        encode_char(char).each do |zchar|
          break if zchars.size >= encoded_chars
          zchars << zchar
        end
        break if zchars.size >= encoded_chars
      end

      while zchars.size < encoded_chars
        zchars << 5_u8
      end

      bytes = Bytes.new(word_count * 2, 0_u8)
      word_count.times do |index|
        first = zchars[index * 3].to_u16
        second = zchars[index * 3 + 1].to_u16
        third = zchars[index * 3 + 2].to_u16
        word = ((first << 10) | (second << 5) | third).to_u16
        word |= 0x8000_u16 if index == word_count - 1
        bytes[index * 2] = ((word >> 8) & 0xff).to_u8
        bytes[index * 2 + 1] = (word & 0xff).to_u8
      end

      bytes
    end

    private def normalize_input(line : String) : String
      cleaned = line.gsub('\r', "").gsub('\n', "").downcase
      cleaned.gsub(/[^\x20-\x7e]/, "")
    end

    private def write_text_buffer(text : String, text_buffer_addr : Int32) : String
      max_chars = @memory.read_byte(text_buffer_addr).to_i
      truncated = text.bytes.first(max_chars).map(&.chr).join
      start = text_buffer_addr + 1

      truncated.to_slice.each_with_index do |byte, index|
        @memory.write_byte(start + index, byte)
      end

      terminator_address = start + truncated.bytesize
      if terminator_address < @memory.size
        @memory.write_byte(terminator_address, 0_u8)
      end

      truncated
    end

    private def write_parse_buffer(text : String, parse_buffer_addr : Int32) : Nil
      max_words = @memory.read_byte(parse_buffer_addr).to_i
      dictionary = read_dictionary_info
      tokens = tokenize(text, dictionary.separators)
      count = Math.min(max_words, tokens.size)

      @memory.write_byte(parse_buffer_addr + 1, count.to_u8)
      count.times do |index|
        token = tokens[index]
        dictionary_address = lookup_dictionary_entry(token.text, dictionary)
        entry_base = parse_buffer_addr + 2 + index * 4
        @memory.write_word(entry_base, dictionary_address.to_u16)
        @memory.write_byte(entry_base + 2, token.length.to_u8)
        @memory.write_byte(entry_base + 3, token.start.to_u8)
      end
    end

    private def tokenize(text : String, separators : Set(Char)) : Array(Token)
      tokens = [] of Token
      current_start = 0
      current = ""
      position = 1

      text.each_char do |char|
        if char.whitespace?
          flush_token(tokens, current, current_start)
          current = ""
          current_start = 0
        elsif separators.includes?(char)
          flush_token(tokens, current, current_start)
          current = ""
          current_start = 0
          tokens << Token.new(char.to_s, position, 1)
        else
          current_start = position if current.empty?
          current += char
        end
        position += 1
      end

      flush_token(tokens, current, current_start)
      tokens
    end

    private def flush_token(tokens : Array(Token), text : String, start : Int32) : Nil
      return if text.empty?
      tokens << Token.new(text, start, text.bytesize)
    end

    private def read_dictionary_info : DictionaryInfo
      dictionary_addr = @header.dictionary_table.to_i
      separator_count = @memory.read_byte(dictionary_addr).to_i
      separators = Set(Char).new
      separator_count.times do |index|
        separators << @memory.read_byte(dictionary_addr + 1 + index).chr
      end

      entry_length_addr = dictionary_addr + 1 + separator_count
      entry_length = @memory.read_byte(entry_length_addr).to_i
      entry_count = @memory.read_word(entry_length_addr + 1).to_i
      entries_address = entry_length_addr + 3

      DictionaryInfo.new(
        separators: separators,
        entry_length: entry_length,
        entry_count: entry_count,
        entries_address: entries_address
      )
    end

    private def lookup_dictionary_entry(token : String, dictionary : DictionaryInfo) : Int32
      key = Parser.encode_dictionary_key(token, @header.version)
      key_length = key.size
      return 0 if dictionary.entry_length <= 0

      dictionary.entry_count.times do |entry_index|
        candidate_address = dictionary.entries_address + (entry_index * dictionary.entry_length)
        matches = true
        key_length.times do |offset|
          if @memory.read_byte(candidate_address + offset) != key[offset]
            matches = false
            break
          end
        end
        return candidate_address if matches
      end

      0
    end

    private def self.encode_char(char : Char) : Array(UInt8)
      code = char.ord
      if code >= 97 && code <= 122
        return [((code - 97) + 6).to_u8]
      end

      index = A2.index(char)
      return [] of UInt8 unless index
      [5_u8, (index + 6).to_u8]
    end
  end
end
