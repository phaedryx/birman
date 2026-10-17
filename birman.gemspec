# frozen_string_literal: true

require_relative "lib/birman/version"

Gem::Specification.new do |spec|
  spec.name = "birman"
  spec.version = Birman::VERSION
  spec.authors = ["Tad Thorley"]
  spec.email = ["phaedryx@gmail.com"]

  spec.summary = "A small PEG parser library for Ruby."
  spec.description = "Module-based grammars, immutable Data matchers and AST nodes with source spans, packrat memoization, commit points, labels, and Success/Failure results."
  spec.homepage = "https://github.com/phaedryx/birman"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Committed files only, and only what a user of the gem needs. An
  # allowlist, so new development files stay out without anyone
  # remembering to exclude them.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select do |f|
      f.start_with?("lib/", "sig/") || %w[README.md LICENSE.txt CHANGELOG.md].include?(f)
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
