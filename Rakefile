require "bundler/gem_tasks"
require "rake/extensiontask"
require "rspec/core/rake_task"

GEMSPEC = Gem::Specification.load("fast-freeze.gemspec")

# The platforms a precompiled gem is published for. Any other platform
# installs the source gem and compiles it.
CROSS_PLATFORMS = %w[
  x86_64-linux-gnu
  aarch64-linux-gnu
  x86_64-linux-musl
  aarch64-linux-musl
  arm64-darwin
].freeze

Rake::ExtensionTask.new("freeze", GEMSPEC) do |ext|
  ext.ext_dir = "ext/fast/freeze"
  ext.lib_dir = "lib/fast/freeze"
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

RSpec::Core::RakeTask.new(:spec)
task spec: :compile

desc "Time fast-freeze against ice_nine, a walk in Ruby and Ractor.make_shareable"
task benchmark: :compile do
  ruby "benchmark/compare.rb"
end

# rake gem:x86_64-linux-gnu, and so on. Each runs in a rake-compiler-dock
# container, so it needs Docker. The release workflow runs one per platform.
namespace :gem do
  CROSS_PLATFORMS.each do |platform|
    desc "Build the precompiled gem for #{platform} into pkg/"
    task platform do
      require "rake_compiler_dock"

      # The Ruby versions to build for, as the patch releases the container holds.
      ruby_versions = RakeCompilerDock.ruby_cc_version("~> 4.0")
      gem_file = "pkg/#{GEMSPEC.full_name}-#{platform}.gem"

      RakeCompilerDock.sh(
        "bundle install && bundle exec rake native:#{platform} #{gem_file} RUBY_CC_VERSION=#{ruby_versions}",
        platform: platform
      )
    end
  end
end

task default: :spec
