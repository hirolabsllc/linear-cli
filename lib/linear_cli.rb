# frozen_string_literal: true

# linear_cli — a standalone Linear ticketing gem.
#
# Ships BOTH the reusable {Linear::Client} library (the one place all Linear GraphQL + lifecycle
# conventions live) AND a `linear` CLI (the gem's `exe/linear`). Project-agnostic: configured by env
# only — `LINEAR_API_KEY` (required) and `LINEAR_DEFAULT_TEAM` (the CLI's default team key).
#
#   require "linear_cli"
#   client = Linear::Client.new                 # default team (from LINEAR_DEFAULT_TEAM)
#   client = Linear::Client.new(team_key: "ENG")
#
# The class is namespaced as `Linear::Client` so a host app can `require "linear_cli"` and drive the
# same conventions from its own code (e.g. an HTTP endpoint) without duplicating the GraphQL logic.
require_relative "linear_cli/version"
require_relative "linear/client"

module LinearCli
end
