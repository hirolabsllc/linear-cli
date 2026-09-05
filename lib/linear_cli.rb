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
require_relative "linear_cli/checkout"
require_relative "linear/client"

module LinearCli
  # --- exit codes (AGT-280) ------------------------------------------------------------------
  # A caller needs to tell three outcomes apart, and until AGT-280 the CLI had one failure code for
  # all of them. The distinction that matters is NOT "did it work" but "do I know":
  #
  #   0   success.
  #   1   REFUSED. The write did not happen: a validation error, a bad argument, a mistyped command
  #       (AGT-275), a missing issue, no API key. Safe to fix the input and run it again unchanged.
  #   75  UNKNOWN. The request left this client and Linear never answered, so the write MAY HAVE
  #       COMMITTED. Do NOT blindly retry — census first (see the README). 75 is sysexits' EX_TEMPFAIL,
  #       the conventional "transient, try again later", and it is the code AGT-280 was filed for:
  #       `linear create` reported a flat failure for an issue that existed (AKA-2787).
  #   76  PARTIAL. The primary object landed but a follow-up step did not — an issue created with
  #       none of its --related relations. stdout names the id that exists; stderr names the steps
  #       that are outstanding. Retry the STEPS, never the create.
  #
  # 1 keeps its meaning exactly, so nothing that already treats non-zero as failure changes; only
  # scripts that want to census-before-retrying need to read 75/76.
  EXIT_OK      = 0
  EXIT_REFUSED = 1
  EXIT_UNKNOWN = 75
  EXIT_PARTIAL = 76
end
