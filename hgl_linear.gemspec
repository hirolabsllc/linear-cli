# frozen_string_literal: true

require_relative "lib/hgl_linear/version"

Gem::Specification.new do |spec|
  spec.name     = "hgl_linear"
  spec.version  = HglLinear::VERSION
  spec.authors  = ["Hiro Labs"]
  spec.email    = ["tyler@hirolabs.com"]

  spec.summary  = "Standalone Linear ticketing library + CLI (Linear::Client + the `linear` command)."
  spec.description = <<~DESC
    hgl_linear is a project-agnostic Linear ticketing tool. It ships BOTH the reusable Linear::Client
    library (the single place all Linear GraphQL + lifecycle conventions live — multi-team, dedup
    search, relations, state transitions, rate-limit backoff) AND a `linear` CLI built on it. Config
    is env-only (LINEAR_API_KEY + LINEAR_DEFAULT_TEAM), so any project — trader-ai, the agent-ops
    Hermes bot, Orcaru — drives the same tool with zero app coupling.
  DESC

  spec.homepage = "https://github.com/hirolabsllc/linear-cli"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  # Git-source gem (pinned by tag) — not published to RubyGems. Block an accidental `gem push`.
  spec.metadata["allowed_push_host"] = "https://nonexistent.invalid"

  spec.files = Dir.glob(%w[
    lib/**/*.rb
    exe/*
    README.md
    CHANGELOG.md
    LICENSE
    .ruby-version
  ]).select { |f| File.file?(f) }

  spec.bindir      = "exe"
  spec.executables = ["linear"]
  spec.require_paths = ["lib"]

  # Pure stdlib at runtime (net/http, uri, json) — no runtime dependencies. `dotenv` is soft-required
  # by the CLI only when present (so `linear` auto-loads a project .env); it is intentionally NOT a
  # hard dependency so the gem stays minimal on servers that inject env vars directly.
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
