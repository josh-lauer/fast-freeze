# Times Fast::Freeze.deep_freeze against a walk written in Ruby, ice_nine and
# Ractor.make_shareable, on synthetic values.
#
#   bundle exec rake benchmark
#
# The contenders do not all do the same work. ice_nine and make_shareable also
# go into the instance variables of an object, and ice_nine does not look
# inside a Data. A row is marked when a contender returned without freezing
# an object deep inside the value.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "fast/freeze"

begin
  require "ice_nine"
rescue LoadError
  warn "ice_nine is not installed, so it is left out (bundle install adds it)"
end

# The same rules as Fast::Freeze.deep_freeze with its defaults, in Ruby. It
# keeps no record of what it has opened, so it would not end on a value that
# holds itself.
module RubyWalk
  MEMBERS_OF = ::Data.instance_method(:to_h)

  def self.deep_freeze(value)
    return members(value) if value.is_a?(::Data)

    walk(value)
    value
  end

  def self.members(data)
    MEMBERS_OF.bind_call(data).each_value { |member| walk(member) }
    data
  end

  def self.walk(value)
    case value
    when ::String then value.freeze
    when ::Array, ::Set
      value.freeze
      value.each { |element| walk(element) }
    when ::Hash
      value.freeze
      value.each do |key, held|
        walk(key)
        walk(held)
      end
    when ::Module then nil
    else value.freeze
    end
  end
end

def choices
  [{ "index" => 0, "delta" => { "content" => +"hello", "role" => nil }, "finish_reason" => nil, "logprobs" => nil }]
end

def document(number = 0)
  {
    "id" => +"doc-#{number}", "title" => +"A synthetic title number #{number}", "type" => +"article", "year" => 2020 + (number % 5),
    "authors" => Array.new(6) { |author| +"Author #{author}" }, "abstract" => +("lorem ipsum " * 40),
    "journal" => { "name" => +"Journal of Examples", "issn" => +"0000-0000", "volume" => 12, "pages" => +"1-10" },
    "terms" => Array.new(12) { |term| { "term" => +"Term #{term}", "major" => term.even? } },
    "scores" => { "lexical" => 12.5, "dense" => 0.83, "rerank" => 0.91 }, "url" => +"https://example.test/#{number}",
    "chunks" => Array.new(4) { |chunk| { "text" => +("chunk text " * 20), "offset" => chunk * 100, "tags" => [+"a", +"b"] } }
  }
end

Wide = Data.define(:id, :object, :created, :model, :choices, :usage, :a, :b, :c, :d, :e, :f, :g, :h, :i, :j)

def wide
  Wide.new(id: +"id-1", object: +"chunk", created: 1, model: +"m", choices:, usage: nil,
           a: nil, b: nil, c: nil, d: nil, e: nil, f: nil, g: nil, h: nil, i: nil, j: nil)
end

Holder = Data.define(:document, :scores)

def frozen_document = Fast::Freeze.deep_freeze(document)

CONTENDERS = {
  "fast-freeze" => ->(value) { Fast::Freeze.deep_freeze(value) },
  "fast-freeze, trust_frozen: true" => ->(value) { Fast::Freeze.deep_freeze(value, trust_frozen: true) },
  "walk in Ruby" => ->(value) { RubyWalk.deep_freeze(value) },
  "Ractor.make_shareable" => ->(value) { Ractor.make_shareable(value) }
}
if defined?(IceNine)
  CONTENDERS["ice_nine deep_freeze!"] = ->(value) { IceNine.deep_freeze!(value) }
  CONTENDERS["ice_nine deep_freeze"] = ->(value) { IceNine.deep_freeze(value) }
end

# Each shape: how to build it, how many to time, and one object deep inside
# it that a deep freeze must have frozen.
SHAPES = {
  "small nested value (4 containers, 1 String)" => [-> { choices }, 200_000, ->(value) { value[0]["delta"]["content"] }],
  "document (about 90 objects)" => [-> { document }, 20_000, ->(value) { value["chunks"][0]["tags"][0] }],
  "Array of 1,000 documents" => [-> { Array.new(1000) { |number| document(number) } }, 20, ->(value) { value[999]["chunks"][0]["tags"][0] }],
  "document that is already frozen" => [-> { frozen_document }, 20_000, ->(value) { value["chunks"][0]["tags"][0] }],
  "Data with 16 members" => [-> { wide }, 200_000, ->(value) { value.choices[0]["delta"]["content"] }],
  "Data holding a frozen document" => [-> { Holder.new(document: frozen_document, scores: { "a" => 1.0 }) }, 20_000, ->(value) { value.scores }]
}

# The best of three passes, each over values built fresh and with the collector off.
def nanoseconds_per_call(make, count, contender)
  Array.new(3) do
    values = Array.new(count) { make.call }
    GC.start
    GC.disable
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    index = 0
    while index < count
      contender.call(values[index])
      index += 1
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
    GC.enable
    elapsed.to_f / count
  end.min
end

puts "#{RUBY_DESCRIPTION}\nfast-freeze #{Fast::Freeze::VERSION}#{", ice_nine #{IceNine::VERSION}" if defined?(IceNine)}"

SHAPES.each_value { |(make, _)| CONTENDERS.each_value { |contender| 3000.times { contender.call(make.call) } } }

SHAPES.each do |shape, (make, count, deep_inside)|
  puts "\n#{shape}"
  rows = CONTENDERS.map do |name, contender|
    reached = deep_inside.call(make.call.tap { |value| contender.call(value) }).frozen?
    [name, nanoseconds_per_call(make, count, contender), reached]
  end
  fastest = rows.first[1]
  rows.each do |name, nanoseconds, reached|
    puts format("  %-34s %12.0f ns  %7.1fx%s", name, nanoseconds, nanoseconds / fastest, reached ? "" : "   left the inside unfrozen")
  end
end
