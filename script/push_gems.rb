# Pushes every gem in pkg/ to RubyGems, and skips any that RubyGems already
# has, so a release that failed partway can be run again and finish.
#
#   ruby script/push_gems.rb
#
# The release workflow runs this once it holds push credentials.
require "net/http"
require "open3"
require "rubygems/package"

module PushGems
  HOST = "https://rubygems.org".freeze

  module_function

  # The gems in a directory, as [path, spec]. The source gem comes first:
  # once it is published, every platform can install the version.
  def gems_in(directory)
    Dir[File.join(directory, "*.gem")]
      .map { |path| [path, Gem::Package.new(path).spec] }
      .sort_by { |path, spec| [spec.platform == Gem::Platform::RUBY ? 0 : 1, path] }
  end

  # Whether RubyGems already has this version of the gem for this platform.
  def published?(spec)
    uri = URI("#{HOST}/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json")
    uri.query = URI.encode_www_form(platform: spec.platform.to_s)

    case (response = Net::HTTP.get_response(uri))
    when Net::HTTPSuccess then true
    when Net::HTTPNotFound then false
    else abort "RubyGems answered #{response.code} when asked about #{spec.full_name}"
    end
  end

  def push(path, spec)
    output, status = Open3.capture2e("gem", "push", path)
    puts output
    return if status.success?

    # The lookup above can lag a push by a moment, so RubyGems may still say this.
    return puts("#{spec.full_name} is already published, skipping") if output.include?("Repushing of gem versions is not allowed")

    abort "pushing #{spec.full_name} failed"
  end

  def run(directory)
    gems = gems_in(directory)
    abort "no gems in #{directory}" if gems.empty?

    gems.each do |path, spec|
      if published?(spec)
        puts "#{spec.full_name} is already published, skipping"
      else
        puts "Pushing #{spec.full_name}"
        push(path, spec)
      end
    end
  end
end

PushGems.run("pkg") if $PROGRAM_NAME == __FILE__
