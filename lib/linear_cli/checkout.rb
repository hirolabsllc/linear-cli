# frozen_string_literal: true

require_relative "version"

module LinearCli
  # "Am I the code that was released?" — a stderr warning when the checkout running this CLI is stale
  # or dirty (AGT-222).
  #
  # Tagging the gem does not ship it. `linear` reaches its callers as FOUR independent checkouts, each
  # with its own staleness: trader-ai's bundled copy (Gemfile tag → deploy), the shared main checkout,
  # the agent-ops box at `/opt/linear-cli`, and the plain clone at `~/Developer/linear-cli` that
  # cerails' `bin/linear` `exec`s DIRECTLY — working tree and all, with no Gemfile, no bundle and no
  # deploy gate between an edit and another team's ticketing. Two failure modes, both silent until now:
  #
  #   * STALE — measured during AGT-217: the plain clone sat one commit behind `origin/main` after
  #     v2.6.0 was tagged, so ORC kept getting comments newest-first long after the fix shipped and
  #     every other surface had moved. Nothing indicated it — no version banner, no drift warning.
  #   * DIRTY — a half-finished edit in that tree is executed live by everyone who calls it.
  #
  # So say so, once, on stderr, before the command runs. A visible staleness is a fixed staleness;
  # AGT-218's box ran four releases behind precisely because nothing ever mentioned it.
  #
  # LOCAL-ONLY, on purpose. The check costs at most three `git` invocations against the checkout we
  # were loaded from and never touches the network, so it cannot hang the CLI, cannot need credentials
  # and cannot slow a hot path. That still buys the cases that bite: a release tagged from a worktree
  # shares the clone's ref store, so the plain clone SEES the new tag the instant it exists, and the
  # ops box's update runbook opens with `git fetch --tags`. What it cannot see is a tag a checkout has
  # never fetched — closed from the other end by the release recipe, which fast-forwards the clone
  # immediately after `git push` (see README, "Releasing").
  #
  # CLI-only: `exe/linear` calls this, NOT `require "linear_cli"`, so a host app driving
  # Linear::Client from a web request (trader-ai's admin endpoint) never shells out to git mid-request.
  module Checkout
    # The checkout this file was loaded from — lib/linear_cli/ is two levels below the repo root.
    ROOT = File.expand_path("../..", __dir__)

    # Opt out (e.g. a box deliberately pinned behind, or a caller that parses stderr).
    SKIP_ENV = "LINEAR_CLI_SKIP_CHECKOUT_CHECK"

    # Only `lib/` and `exe/` count as "dirty": they are the code the CLI actually executes. Scoping the
    # status this way is also what keeps bundler's vendored copy quiet — bundler rewrites the gemspec of
    # a git-source gem in place, so `M linear_cli.gemspec` is permanent bookkeeping there rather than a
    # half-finished edit, and crying wolf on every trader-ai `bin/linear` would train the eye to ignore
    # the one line that matters.
    CODE_PATHS = %w[lib exe].freeze

    # Bundler's install layout for a git-source gem (`<bundle path>/bundler/gems/<name>-<shortsha>`).
    # Such a checkout is MANAGED: bundler re-clones it from Gemfile.lock, so a hand `git checkout`
    # inside it is clobbered by the next `bundle install` and desyncs the lock. Staleness there is
    # real and worth reporting — it means the Gemfile pin is behind — but the remedy is a different
    # command, so it gets its own. (Whether such a copy carries tags at all varies with how the bundle
    # was installed; both shapes are handled.)
    BUNDLER_LAYOUT = %r{/bundler/gems/[^/]+/?\z}

    class << self
      # Print any warnings to stderr. Never raises and never exits: a missing git, an odd checkout or a
      # malformed tag must not take ticketing down with it — this is an advisory, not a gate.
      def warn!(root: ROOT, version: LinearCli::VERSION)
        return if ENV[SKIP_ENV] == "1"

        warnings(root: root, version: version).each { |line| warn(line) }
      rescue StandardError
        nil
      end

      # The warning lines for `root` — empty when the checkout is fine, or when there is nothing to
      # compare it against. Split out from #warn! so tests can assert on real repositories rather than
      # on captured stderr.
      def warnings(root: ROOT, version: LinearCli::VERSION)
        # No `.git` at all: a packaged `gem install`, where the installed version IS the release.
        dot_git = File.join(root, ".git")
        return [] unless File.exist?(dot_git)

        # No release tags: nothing here defines "current", so there is no honest warning to give. This
        # is also what silences bundler's vendored checkout, which clones with a heads-only refspec —
        # and rightly so, since the Gemfile pin, not this file, is what fixes trader-ai's version.
        newest = newest_tag(root) or return []

        lines = []
        lines.concat(stale_lines(root, version, newest)) if behind?(version, newest)
        # A LINKED worktree is a session's own scratch space, where uncommitted work is the normal
        # state; the MAIN worktree is the one other projects exec directly, where it is a live defect.
        # `.git` is a directory in the main worktree and a file (`gitdir: …`) in a linked one, so the
        # two are told apart with a stat instead of a `git` process — the healthy path stays at two.
        lines.concat(dirty_lines(root)) if File.directory?(dot_git)
        lines
      end

      private

      # Newest `vX.Y.Z` tag KNOWN TO THIS CHECKOUT (no fetch — see the note above). Compared as
      # versions, not strings, so v2.10.0 sorts above v2.9.0; anything that isn't a release tag is
      # dropped rather than sorted alongside one.
      def newest_tag(root)
        out = git(root, "tag", "--list", "v[0-9]*") or return nil

        out.lines.map(&:strip).grep(/\Av\d+(?:\.\d+)*\z/).max_by { |t| version_of(t) }
      end

      # Behind means strictly older than the newest tag. A checkout that is AHEAD is a release in
      # progress (version.rb bumped, tag not cut yet) and is not stale.
      def behind?(version, newest)
        Gem::Version.new(version) < version_of(newest)
      end

      def version_of(tag)
        Gem::Version.new(tag.delete_prefix("v"))
      end

      # "You are running old code" plus the ONE command that fixes THIS shape of checkout — a remedy
      # that would be undone by the tool managing the directory is worse than none. Bundler owns its
      # install path (bump the pin instead); a detached HEAD is a pinned box (move the pin to the new
      # tag); anything else tracks a branch (fast-forward it). `--abbrev-ref HEAD` reports the literal
      # string "HEAD" when detached, and resolving it costs a `git` process — so it happens here, only
      # once we already know the checkout is behind.
      def stale_lines(root, version, newest)
        lines = ["  ! linear_cli #{version} is behind #{newest} — this checkout is serving old code (AGT-222)"]
        lines << if root.match?(BUNDLER_LAYOUT)
                   "    fix: bump the linear_cli tag to #{newest} in your Gemfile, then `bundle update linear_cli`"
                 elsif git(root, "rev-parse", "--abbrev-ref", "HEAD").to_s.strip == "HEAD"
                   "    fix: cd #{sh(root)} && git fetch --tags origin && git checkout --detach #{newest}"
                 else
                   "    fix: cd #{sh(root)} && git fetch origin main && git merge --ff-only origin/main"
                 end
        lines
      end

      # Uncommitted changes to executable code in the main worktree. Tracked files only: an untracked
      # scratch file sitting next to the code does not change what runs.
      def dirty_lines(root)
        out = git(root, "status", "--porcelain", "--untracked-files=no", "--", *CODE_PATHS)
        return [] if out.nil? || out.strip.empty?

        count = out.lines.count
        ["  ! linear_cli is running from a DIRTY checkout — #{count} uncommitted change(s) under " \
         "#{CODE_PATHS.join("/, ")}/ (AGT-222)",
         "    #{root} — every project that execs this tree is running them. Do gem work in a worktree."]
      end

      # Run git in `root`, returning stdout — or nil if git is absent or the command failed. Argument
      # array (no shell), so a path with spaces needs no quoting and nothing we pass can be re-parsed
      # as a command.
      def git(root, *args)
        out = IO.popen(["git", "-C", root, *args], err: File::NULL, &:read)
        $?.success? ? out : nil
      rescue SystemCallError
        nil
      end

      # Quote a path for the copy-pasteable fix line, but only when it actually needs it.
      def sh(path)
        path.match?(%r{\A[\w@%+=:,./-]+\z}) ? path : "'#{path.gsub("'", %q('"'"'))}'"
      end
    end
  end
end
