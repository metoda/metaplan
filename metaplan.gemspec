# frozen_string_literal: true
$LOAD_PATH.push File.expand_path("../lib", __FILE__)

require "metaplan"

Gem::Specification.new do |s|
  s.name = "metaplan"
  s.version = MetaPlan::VERSION
  s.summary = "Recursive execution through a meta language"
  s.description = "Create results through executing multiple steps recursively"
  s.authors = ["Matthias Geier"]
  s.homepage = "https://github.com/metoda/metaplan"
  s.license = "BSD-2-Clause"
  s.files = Dir["lib/**/*"]
  s.test_files = Dir["spec/**/*"]
  s.add_dependency "activesupport", " > 3"
  s.add_development_dependency "minitest", "~> 5"
end
