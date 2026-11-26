require_relative "lib/fast/freeze/version"

Gem::Specification.new do |spec|
  spec.name = "fast-freeze"
  spec.version = Fast::Freeze::VERSION
  spec.authors = ["Josh Lauer"]

  spec.summary = "Deep freeze for Ruby values, written in C."
  spec.description = "Freezes a value and what it holds: Strings, Arrays, Hashes (keys and values), Sets, " \
                     "and the members of a Data or a Struct. One method, no monkey patches, no allocation."
  spec.homepage = "https://github.com/josh-lauer/fast-freeze"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "ext/**/*.{c,rb}", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/fast/freeze/extconf.rb"]

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/josh-lauer/fast-freeze/issues",
    "changelog_uri" => "https://github.com/josh-lauer/fast-freeze/blob/main/CHANGELOG.md",
    "homepage_uri" => "https://github.com/josh-lauer/fast-freeze",
    "source_code_uri" => "https://github.com/josh-lauer/fast-freeze",
    "rubygems_mfa_required" => "true"
  }
end
