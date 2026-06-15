# frozen_string_literal: true

# hgl_linear — Hiro Labs' standalone Linear ticketing gem.
#
# Ships BOTH the reusable {Linear::Client} library (the one place all Linear GraphQL + lifecycle
# conventions live) AND a `linear` CLI (the gem's `exe/linear`). Project-agnostic: configured by env
# only — `LINEAR_API_KEY` (required) and `LINEAR_DEFAULT_TEAM` (the CLI's default team key).
#
#   require "hgl_linear"
#   client = Linear::Client.new                 # default team (LINEAR_DEFAULT_TEAM handled by the CLI)
#   client = Linear::Client.new(team_key: "AGT")
#
# The class name stays `Linear::Client` so host apps that already reference it (trader-ai's admin
# controller, etc.) keep working unchanged after switching to the gem.
require_relative "hgl_linear/version"
require_relative "linear/client"

module HglLinear
end
