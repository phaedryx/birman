# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]

desc "Compile the generated example parsers with Spinel and diff them against the interpreter"
task :spinel do
  ruby "test/spinel/diff.rb"
end
