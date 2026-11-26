require "fast/freeze/version"

# A precompiled gem built for several Ruby versions keeps one build of the
# extension for each, in a directory named for the version. A gem compiled on
# install, or built for one version, has a single build beside this file.
begin
  require "fast/freeze/#{RUBY_VERSION[/\d+\.\d+/]}/freeze"
rescue LoadError
  require "fast/freeze/freeze"
end

module Fast
  # Deep freeze for Ruby values, written in C.
  module Freeze
    # Freezes +value+ and what it holds, and returns it.
    #
    # A String is frozen. An Array, a Hash and a Set are frozen and walked: the
    # elements of an Array or a Set, the keys and the values of a Hash. A class
    # or a module is left alone. Any other object has +freeze+ called on it and
    # is not looked inside.
    #
    # A Data or a Struct passed as +value+ is frozen and its members are walked.
    # One found inside +value+ is frozen and not looked inside, unless
    # +recurse_into_structs+ says otherwise.
    #
    # [trust_frozen]
    #   When false, an Array, a Hash or a Set found already frozen is walked
    #   like any other. When true it is taken to be frozen all the way down and
    #   is not walked.
    # [recurse_into_structs]
    #   When true, the members of every Data and Struct found inside +value+ are
    #   walked too, whether or not it was found frozen.
    #
    # If a +freeze+ raises, the error is passed on and what was frozen before it
    # stays frozen.
    def self.deep_freeze(value, trust_frozen: false, recurse_into_structs: false)
      __deep_freeze__(value, trust_frozen, recurse_into_structs)
    end

    # The walk reads the members of a Data from its slots. This confirms at load
    # that it finds them on this Ruby.
    probe = Data.define(:first, :second).new(first: +"a", second: [+"b"])
    deep_freeze(probe)
    unless probe.first.frozen? && probe.second.frozen? && probe.second.first.frozen?
      raise LoadError, "fast-freeze cannot read the members of a Data on #{RUBY_DESCRIPTION}"
    end
  end
end
