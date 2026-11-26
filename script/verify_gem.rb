# Run against an installed precompiled gem, not the checkout:
#
#   gem install --local pkg/fast-freeze-<version>-<platform>.gem
#   ruby script/verify_gem.rb
#
# The release workflow runs this on each platform before anything is
# published, to confirm that the binary inside the gem loads and works there.
require "fast/freeze"

spec = Gem.loaded_specs.fetch("fast-freeze") { abort "fast-freeze was loaded from somewhere other than an installed gem" }
abort "expected a precompiled gem, and this one compiles on install" unless spec.extensions.empty?

Pair = Data.define(:left, :right)
inside = [+"key"]
value = Pair.new(left: { inside => Set[+"element"] }, right: [+"text", Pair.new(left: +"inner", right: nil)])

Fast::Freeze.deep_freeze(value, trust_frozen: false, recurse_into_structs: true)

reached = [value.left, inside, inside[0], value.left[inside], value.left[inside].first, value.right, value.right[0], value.right[1].left]
abort "deep_freeze left something unfrozen" unless reached.all?(&:frozen?)

puts "fast-freeze #{spec.version} (#{spec.platform}) works on #{RUBY_DESCRIPTION}"
