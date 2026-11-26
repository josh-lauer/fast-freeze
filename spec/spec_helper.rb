require "fast/freeze"

# CI runs the suite a second time with GC_STRESS set: a collection at every
# allocation, to catch an object read after it was freed or moved.
GC_STRESS = %w[1 true yes].include?(ENV["GC_STRESS"].to_s.downcase)
GC.stress = true if GC_STRESS

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
