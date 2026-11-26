RSpec.describe Fast::Freeze do
  # An Array, a Hash and a String whose freeze is recorded, to show that a
  # subclass has its own freeze called.
  let(:counting) do
    Module.new do
      def freeze_calls = @freeze_calls ||= [0]

      def freeze
        freeze_calls[0] += 1
        super
      end
    end
  end

  def allocations
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end

  describe ".deep_freeze" do
    it "returns the value it was given" do
      value = [+"a"]

      expect(described_class.deep_freeze(value)).to equal(value)
    end

    it "accepts what is frozen by nature" do
      [nil, true, false, 1, 2**80, 1.5, 2r, 3i, :symbol, "dynamic #{rand}".to_sym].each do |value|
        expect(described_class.deep_freeze(value)).to equal(value)
      end
    end

    it "freezes a String" do
      value = +"text"

      described_class.deep_freeze(value)

      expect(value).to be_frozen
    end

    it "freezes an Array and what it holds, however deep" do
      value = [+"a", [+"b", [+"c"]]]

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(value[1]).to be_frozen
      expect(value[1][1]).to be_frozen
      expect([value[0], value[1][0], value[1][1][0]]).to all(be_frozen)
    end

    it "freezes a Hash and its values" do
      value = { "a" => +"text", "b" => { "c" => [+"deep"] } }

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(value["a"]).to be_frozen
      expect(value["b"]).to be_frozen
      expect(value["b"]["c"]).to be_frozen
      expect(value["b"]["c"][0]).to be_frozen
    end

    it "freezes the keys of a Hash and what they hold" do
      key = [+"part", [+"inner"]]
      value = { key => 1 }

      described_class.deep_freeze(value)

      expect(key).to be_frozen
      expect(key[0]).to be_frozen
      expect(key[1]).to be_frozen
      expect(key[1][0]).to be_frozen
      expect(value[["part", ["inner"]]]).to eq(1)
    end

    it "freezes a String key that Ruby did not copy" do
      key = +"by identity"
      value = {}.compare_by_identity
      value[key] = 1

      described_class.deep_freeze(value)

      expect(key).to be_frozen
    end

    it "freezes a Set and its elements" do
      element = [+"inner"]
      value = Set[+"a", element]

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(value.to_a).to all(be_frozen)
      expect(element[0]).to be_frozen
    end

    it "leaves a class and a module alone" do
      klass = Class.new
      mod = Module.new

      described_class.deep_freeze([klass, mod])

      expect(klass).not_to be_frozen
      expect(mod).not_to be_frozen
    end

    it "freezes any other object and does not look inside it" do
      inner = +"held by the object"
      object = Object.new
      object.instance_variable_set(:@inner, inner)

      described_class.deep_freeze([object])

      expect(object).to be_frozen
      expect(inner).not_to be_frozen
    end

    it "freezes a Range and does not look inside it" do
      first = +"a"
      range = Range.new(first, +"z")

      described_class.deep_freeze(range)
      described_class.deep_freeze([range], recurse_into_structs: true)

      expect(range).to be_frozen
      expect(first).not_to be_frozen
    end

    it "freezes an object that has no freeze method" do
      bare = BasicObject.new

      described_class.deep_freeze([bare])

      expect(Kernel.instance_method(:frozen?).bind_call(bare)).to be(true)
    end

    it "does not reach the default value of a Hash" do
      default = []
      value = Hash.new(default)

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(default).not_to be_frozen
    end

    it "calls the freeze of a subclass of String, Array or Hash" do
      string = Class.new(String).include(counting).new("text")
      array = Class.new(Array).include(counting).new([+"a"])
      hash = Class.new(Hash).include(counting).new
      hash["k"] = +"v"

      described_class.deep_freeze([string, array, hash])

      expect([string, array, hash].map { |object| object.freeze_calls[0] }).to eq([1, 1, 1])
      expect([string, array, hash]).to all(be_frozen)
      expect(array[0]).to be_frozen
      expect(hash["k"]).to be_frozen
    end

    it "calls a freeze defined on one object alone" do
      calls = 0
      value = [+"a"]
      value.define_singleton_method(:freeze) do
        calls += 1
        super()
      end

      described_class.deep_freeze(value)

      expect(calls).to eq(1)
      expect(value).to be_frozen
      expect(value[0]).to be_frozen
    end

    it "passes on an error raised by a freeze, leaving frozen what it had reached" do
      failing = Object.new
      def failing.freeze = raise(ArgumentError, "will not freeze")
      before = +"before"
      after = +"after"
      value = [before, failing, after]

      expect { described_class.deep_freeze(value) }.to raise_error(ArgumentError, "will not freeze")

      expect(value).to be_frozen
      expect(before).to be_frozen
      expect(after).not_to be_frozen
    end

    describe "allocation" do
      let(:pair) { Data.define(:left, :right) }
      let(:calls) do
        [
          ->(value) { described_class.deep_freeze(value) },
          ->(value) { described_class.deep_freeze(value, trust_frozen: false) },
          ->(value) { described_class.deep_freeze(value, trust_frozen: false, recurse_into_structs: true) }
        ]
      end

      # Counts what each way of calling allocates, on a fresh value and then on the same value frozen.
      def allocated_by(calls, fresh)
        # Ruby allocates once for a call site the first time it runs, so each is run before it is counted.
        calls.each { |call| call.call(fresh.call) }
        allocations {}

        calls.flat_map do |call|
          value = fresh.call
          [allocations { call.call(value) }, allocations { call.call(value) }]
        end
      end

      it "allocates nothing" do
        fresh = -> { pair.new(left: { "a" => [+"b", { [+"c"] => +"d" }] }, right: [Set[+"e"], pair.new(left: +"f", right: nil)]) }

        expect(allocated_by(calls, fresh)).to all(eq(0))
      end
    end
  end

  describe "a Data or a Struct passed in" do
    let(:pair) { Data.define(:left, :right) }
    let(:record) { Struct.new(:left, :right) }

    it "has the members of a Data walked, though a Data is always frozen" do
      value = pair.new(left: +"a", right: { "k" => [+"b"] })

      expect(described_class.deep_freeze(value)).to equal(value)

      expect(value.left).to be_frozen
      expect(value.right).to be_frozen
      expect(value.right["k"]).to be_frozen
      expect(value.right["k"][0]).to be_frozen
    end

    it "freezes a Struct and walks its members" do
      value = record.new(+"a", [+"b"])

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(value.left).to be_frozen
      expect(value.right).to be_frozen
      expect(value.right[0]).to be_frozen
    end

    it "walks the members of a Struct that was frozen already" do
      value = record.new(+"a", [+"b"]).freeze

      described_class.deep_freeze(value)

      expect(value.left).to be_frozen
      expect(value.right[0]).to be_frozen
    end

    it "reads members held outside the object, as a wide Struct's are" do
      wide = Struct.new(*Array.new(40) { |i| :"m#{i}" })
      value = wide.new(*Array.new(40) { |i| +"member #{i}" })

      described_class.deep_freeze(value)

      expect(value.to_a).to all(be_frozen)
    end

    it "reads the members and not the readers" do
      shadowed = Data.define(:text) do
        def text = "from the reader"
      end
      held = +"from the member"
      value = shadowed.new(text: held)

      described_class.deep_freeze(value)

      expect(held).to be_frozen
    end
  end

  describe "a Data or a Struct found inside the value" do
    let(:pair) { Data.define(:left, :right) }
    let(:record) { Struct.new(:left, :right) }

    it "is frozen and not looked inside" do
      data = pair.new(left: +"a", right: [+"b"])
      struct = record.new(+"c", [+"d"])

      described_class.deep_freeze([data, struct])

      expect(struct).to be_frozen
      expect([data.left, data.right, struct.left, struct.right]).to all(satisfy { |member| !member.frozen? })
    end

    it "is not looked inside when it is a member of the Data passed in" do
      inner = pair.new(left: +"a", right: nil)
      outer = pair.new(left: inner, right: [inner])

      described_class.deep_freeze(outer)

      expect(outer.right).to be_frozen
      expect(inner.left).not_to be_frozen
    end

    it "has its members walked with recurse_into_structs" do
      data = pair.new(left: +"a", right: [+"b"])
      struct = record.new(+"c", pair.new(left: +"d", right: nil))

      described_class.deep_freeze([data, { "k" => struct }], recurse_into_structs: true)

      expect(struct).to be_frozen
      expect([data.left, data.right, data.right[0], struct.left, struct.right.left]).to all(be_frozen)
    end

    it "is opened with recurse_into_structs whatever trust_frozen says" do
      struct = record.new(+"a", [+"b"]).freeze
      data = pair.new(left: +"c", right: nil)

      described_class.deep_freeze([struct, data], trust_frozen: true, recurse_into_structs: true)

      expect([struct.left, struct.right, struct.right[0], data.left]).to all(be_frozen)
    end
  end

  describe "trust_frozen" do
    it "by default takes a frozen container as frozen throughout" do
      inner = +"reached only without trust"
      value = { "list" => [inner].freeze, "set" => Set[[inner]].freeze, "hash" => { "k" => inner }.freeze }

      described_class.deep_freeze(value)

      expect(inner).not_to be_frozen
    end

    it "by default returns a frozen value at once" do
      inner = +"unfrozen"
      value = [inner].freeze

      described_class.deep_freeze(value)

      expect(inner).not_to be_frozen
    end

    it "when false walks a frozen Array, Hash and Set" do
      in_array = +"a"
      in_hash = +"b"
      in_set = [+"c"]
      value = [[in_array].freeze, { "k" => in_hash }.freeze, Set[in_set].freeze].freeze

      described_class.deep_freeze(value, trust_frozen: false)

      expect([in_array, in_hash, in_set, in_set[0]]).to all(be_frozen)
    end

    it "when false still does not look inside a Data found in the value" do
      data = Data.define(:text).new(text: +"a")

      described_class.deep_freeze([data].freeze, trust_frozen: false)

      expect(data.text).not_to be_frozen
    end
  end

  describe "a value that holds one object in several places" do
    # Each level holds the level below twice: 2**60 paths lead to the String.
    def doubled(levels, bottom)
      levels.times.reduce(bottom) { |below, _| yield(below) }
    end

    it "walks shared frozen containers once each, not once per path" do
      bottom = +"bottom"
      value = doubled(60, [bottom].freeze) { |below| [below, below].freeze }

      described_class.deep_freeze(value, trust_frozen: false)

      expect(bottom).to be_frozen
    end

    it "walks shared unfrozen containers a bounded number of times" do
      bottom = +"bottom"
      value = doubled(60, [bottom]) { |below| [below, below] }

      described_class.deep_freeze(value, trust_frozen: false)

      expect(bottom).to be_frozen
    end

    it "walks shared structs once each" do
      pair = Data.define(:left, :right)
      bottom = +"bottom"
      value = doubled(60, pair.new(left: bottom, right: nil)) { |below| pair.new(left: below, right: below) }

      described_class.deep_freeze(value, recurse_into_structs: true)

      expect(bottom).to be_frozen
    end

    it "keeps its record when it outgrows the stack" do
      strings = Array.new(500) { |i| +"string #{i}" }
      containers = strings.map { |string| [string].freeze }
      value = [containers, containers.reverse, { "again" => containers }].freeze

      described_class.deep_freeze(value, trust_frozen: false)

      expect(strings).to all(be_frozen)
    end
  end

  describe "a value that holds itself" do
    it "ends on an Array that holds itself" do
      value = [+"a"]
      value << value

      described_class.deep_freeze(value)

      expect(value).to be_frozen
      expect(value[0]).to be_frozen
    end

    it "ends on frozen containers that hold each other, without trust" do
      first = []
      second = { "first" => first, "text" => +"reached" }
      first << second
      first.freeze
      second.freeze

      described_class.deep_freeze(first, trust_frozen: false)

      expect(second["text"]).to be_frozen
    end

    it "ends on unfrozen containers that hold each other, without trust" do
      first = [+"a"]
      second = [first, +"b"]
      first << second

      described_class.deep_freeze(first, trust_frozen: false)

      expect([first, second, first[0], second[1]]).to all(be_frozen)
    end

    it "ends on a Data that holds itself through an Array, in every mode" do
      node = Data.define(:name, :links)

      [true, false].product([true, false]).each do |trust, recurse|
        links = []
        first = node.new(name: +"first", links:)
        second = node.new(name: +"second", links: [first])
        links << second

        described_class.deep_freeze(first, trust_frozen: trust, recurse_into_structs: recurse)

        expect(first.name).to be_frozen
        expect(links).to be_frozen
        expect(second.name.frozen?).to be(recurse)
      end
    end

    it "ends on a container whose freeze does not freeze it" do
      stubborn = Class.new(Array) { def freeze = self }.new
      text = +"inside"
      stubborn << text << stubborn

      described_class.deep_freeze(stubborn)

      expect(stubborn).not_to be_frozen
      expect(text).to be_frozen
    end
  end

  describe "a value nested very deep" do
    # The walk goes 128 levels down the C stack and continues from a list
    # after that. These nest far past it: 100,000 levels, or 2,000 when every
    # allocation collects, where building 100,000 would take hours.
    LEVELS = GC_STRESS ? 2_000 : 100_000

    # A Set, and a Hash keyed by what it nests, are built to compare by
    # identity here: Ruby cannot hash a key nested this deep.
    def nested(levels)
      bottom = +"bottom"
      value = levels.times.reduce(bottom) { |below, level| yield(below, level) }
      [value, bottom]
    end

    it "freezes Arrays nested far past what the stack would hold" do
      value, bottom = nested(LEVELS) { |below, _| [below] }

      described_class.deep_freeze(value)

      expect(bottom).to be_frozen
    end

    it "freezes a mix of containers nested as deep, without trust" do
      pair = Struct.new(:held)
      value, bottom = nested(LEVELS) do |below, level|
        case level % 4
        when 0 then [below].freeze
        when 1 then { "k" => below }
        when 2 then Set.new.compare_by_identity.add(below)
        else pair.new(below)
        end
      end

      described_class.deep_freeze(value, trust_frozen: false, recurse_into_structs: true)

      expect(bottom).to be_frozen
    end

    it "does so inside a Fiber, whose stack is small" do
      value, bottom = nested(LEVELS) do |below, level|
        level.even? ? {}.compare_by_identity.tap { |hash| hash[below] = 1 } : Set.new.compare_by_identity.add(below)
      end

      Fiber.new { described_class.deep_freeze(value) }.resume

      expect(bottom).to be_frozen
    end
  end

  describe "under garbage collection" do
    it "freezes a shared, deep value while every allocation collects and moves objects" do
      pair = Data.define(:left, :right)
      strings = Array.new(120) { |i| +"string #{i}" }
      shared = strings.map { |string| [string].freeze }
      deep = 200.times.reduce(+"bottom") { |below, _| [below] }
      value = pair.new(left: [shared, shared, deep], right: { "k" => pair.new(left: Set[+"s"], right: shared) })

      stressed = GC.stress
      compacting = GC.respond_to?(:auto_compact=) && GC.auto_compact
      GC.auto_compact = true if GC.respond_to?(:auto_compact=)
      GC.stress = true
      begin
        described_class.deep_freeze(value, trust_frozen: false, recurse_into_structs: true)
      ensure
        GC.stress = stressed
        GC.auto_compact = compacting if GC.respond_to?(:auto_compact=)
      end

      expect(strings).to all(be_frozen)
      expect(value.right["k"].left.to_a).to all(be_frozen)
    end
  end
end
