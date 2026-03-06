require "json"

module Zink
  struct WorldObject
    include JSON::Serializable

    getter number : UInt16
    getter name : String
    getter parent : UInt16
    getter children : Array(UInt16)
    getter attributes : Array(UInt8)
    getter properties : Hash(UInt8, UInt16)

    def initialize(
      @number : UInt16,
      @name : String,
      @parent : UInt16,
      @children : Array(UInt16),
      @attributes : Array(UInt8),
      @properties : Hash(UInt8, UInt16),
    )
    end
  end

  class Worldview
    include JSON::Serializable

    getter location : UInt16
    getter location_name : String
    getter objects : Array(WorldObject)

    def initialize(
      @location : UInt16,
      @location_name : String,
      @objects : Array(WorldObject),
    )
    end

    def [](object_number : UInt16) : WorldObject?
      @objects.find { |obj| obj.number == object_number }
    end

    def contents(object_number : UInt16) : Array(WorldObject)
      @objects.select { |obj| obj.parent == object_number }
    end

    def parent_of(object_number : UInt16) : WorldObject?
      obj = self[object_number]
      return nil unless obj
      return nil if obj.parent == 0_u16
      self[obj.parent]
    end
  end
end
