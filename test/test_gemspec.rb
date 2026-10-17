# frozen_string_literal: true

require "test_helper"

# The gem's file list comes from `git ls-files`, so these only mean
# something in a checkout with the files committed.
class TestGemspec < Minitest::Test
  def files = Gem::Specification.load(File.expand_path("../birman.gemspec", __dir__)).files

  def test_version
    refute_nil Birman::VERSION
  end

  def test_ships_the_library
    assert_includes files, "lib/birman.rb"
    assert_includes files, "lib/birman/matchers.rb"
  end

  def test_leaves_out_development_files
    dev = files.grep(%r{\A(\.|bin/|test/|examples/|assets/|Gemfile|Rakefile)})
    assert_empty dev
  end
end
