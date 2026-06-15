# frozen_string_literal: true

# Standalone test harness for the hgl_linear gem — no Rails / ActiveSupport.
#
# Provides just enough to run the lifted Linear::Client tests verbatim:
#   * Minitest as the runner, plus `minitest/mock` for the `.stub` helper the tests use.
#   * a tiny `test "description" do … end` class macro (the ActiveSupport::TestCase syntax the tests
#     were written in) implemented on a plain Minitest::Test subclass.
require "minitest/autorun"
require "minitest/mock"
require "hgl_linear"

module HglLinear
  # Base test case: plain Minitest plus the `test "..." do` declarative syntax.
  class TestCase < Minitest::Test
    # Define a test from a description string, mirroring ActiveSupport::TestCase#test. The body
    # becomes a `test_<slug>` instance method so Minitest discovers and runs it.
    def self.test(description, &block)
      method_name = "test_#{description.strip.gsub(/[^a-z0-9]+/i, "_").gsub(/_+/, "_")}"
      raise "duplicate test name: #{method_name}" if method_defined?(method_name)

      define_method(method_name, &(block || -> { skip "no implementation provided" }))
    end
  end
end
