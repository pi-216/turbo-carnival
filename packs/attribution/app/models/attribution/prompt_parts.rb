# frozen_string_literal: true

module Attribution
  # The prompt as its NAMED parts, in order -- the value the creator of a run hands to
  # `Attribution::RecordRender`.
  #
  # WHY A COLLECTION AND NOT A STRING. An assembled prompt is an OUTCOME: it can be
  # re-guessed but not varied, which is why `renders` carries no prompt column and
  # `Attribution::Render` says so. This object is the input side of that rule -- whoever
  # CREATES a run knows which block it wrote and under which name *at the moment it wrote
  # it*, and that is the only trustworthy source of a part.
  #
  # `#assembled` exists because the graph still executes one string. It is DERIVED FROM the
  # parts and is never authoritative: nothing reads it back, and there is deliberately no
  # `from_string`/`parse`, because reconstructing parts out of an assembled prompt is a
  # guess -- and a guessed part silently poisons every later comparison.
  #
  # Names are validated here, at the boundary, so an unnamed or misspelled axis cannot reach
  # the spine at all (`Attribution::PromptPart` validates the same vocabulary; failing here
  # fails legibly instead of mid-render).
  class PromptParts
    SEPARATOR = "\n\n"

    # Accepts another PromptParts, a { name => text } Hash (symbol or string keys), or an
    # ordered list of [name, text] pairs.
    def self.from(source)
      source.is_a?(self) ? source : new(source)
    end

    def initialize(parts = {})
      @parts = normalize(parts)
      freeze
    end

    def names
      @parts.map(&:first)
    end

    def text_for(name)
      wanted = name.to_s
      pair = @parts.find { |part_name, _| part_name == wanted }
      pair&.last
    end

    def include?(name)
      names.include?(name.to_s)
    end

    def to_h
      @parts.to_h
    end

    # Yields (name, text, position) -- the shape a row needs, so ordering is decided once,
    # by the creator, rather than re-derived by each reader.
    def each_part
      return to_enum(:each_part) unless block_given?

      @parts.each_with_index { |(name, text), position| yield(name, text, position) }
    end

    def assembled(separator: SEPARATOR)
      @parts.filter_map(&:last).join(separator)
    end

    def empty?
      @parts.empty?
    end

    def size
      @parts.length
    end

    def ==(other)
      other.is_a?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end

    def inspect
      "#<#{self.class.name} #{to_h.inspect}>"
    end

    private

    def normalize(parts)
      pairs = parts.is_a?(Hash) ? parts.to_a : Array(parts)

      pairs.map do |entry|
        name, text = entry
        name = name.to_s
        validate_name!(name)
        unless text.nil? || text.is_a?(String)
          raise ArgumentError, "prompt part #{name.inspect} must carry text, got #{text.class}"
        end

        [ name, text ]
      end.tap { |normalized| validate_unique!(normalized) }
    end

    def validate_name!(name)
      if PromptPart::RESERVED_NAMES.include?(name)
        raise ArgumentError,
              "prompt part name #{name.inspect} is reserved: the negative prompt is a column on the render"
      end
      return if PromptPart::NAMES.include?(name)

      raise ArgumentError,
            "prompt part name #{name.inspect} is not a known part " \
            "(#{PromptPart::NAMES.join(', ')})"
    end

    def validate_unique!(pairs)
      duplicates = pairs.map(&:first).tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "prompt part name(s) given more than once: #{duplicates.join(', ')}"
    end
  end
end
