# frozen_string_literal: true

require_relative "version"

module LinearCli
  # "Am I the code that was released?" — a stderr warning when the checkout running this CLI is stale
  # or dirty (AGT-222).
  #
  # Tagging the gem does not ship it. `linear` reaches its callers as FOUR independent checkouts, each
  # with its own staleness: a BUNDLED copy vendored by a consumer's Gemfile (tag → deploy), the shared
  # main checkout, a SHARED SERVER checkout under a system path such as `/opt/linear-cli`, and a plain
  # dev clone that another project's own `bin/linear` `exec`s DIRECTLY — working tree and all, with no
  # Gemfile, no bundle and no deploy gate between an edit and another team's ticketing. Two failure
  # modes, both silent until now:
  #
  #   * STALE — measured during AGT-217: the plain clone sat one commit behind `origin/main` after
  #     v2.6.0 was tagged, so ORC kept getting comments newest-first long after the fix shipped and
  #     every other surface had moved. Nothing indicated it — no version banner, no drift warning.
  #   * DIRTY — a half-finished edit in that tree is executed live by everyone who calls it.
  #
  # So say so, once, on stderr, before the command runs. A visible staleness is a fixed staleness;
  # AGT-218's box ran four releases behind precisely because nothing ever mentioned it.
  #
  # NEVER BLOCKING, on purpose. The check costs at most three `git` invocations against the checkout
  # we were loaded from, plus one `stat`+`read` of a cache file, so it cannot hang the CLI, cannot
  # need credentials and cannot slow a hot path.
  #
  # It used to be local-only too, comparing against the newest tag THIS CHECKOUT ALREADY HAS. That is
  # exactly right for a clone releases are tagged from — a worktree shares the ref store, so the tag
  # exists there the instant it is cut — and it was measured working there. It is BLIND on a checkout
  # nobody ever fetches, which is the one that needed it most (AGT-231). Measured during AGT-222's own
  # rollout: the ops box detached at v2.8.1, v2.8.2 already tagged on origin, `warnings` printed
  # nothing. A tag you have never fetched does not exist as far as `git tag` is concerned, and that is
  # how that box reached four releases / 45 days behind in AGT-218.
  #
  # So the newest tag is now the newer of the local one and a CACHED `git ls-remote --tags origin`:
  #
  #   * the lookup runs DETACHED, at most once per TTL, and nothing ever waits on it. Drift shows up
  #     on the NEXT invocation rather than the first — on a box calling `linear` dozens of times an
  #     hour that is seconds later, and it is the only shape that cannot tax the hot path. A 5 s
  #     network stall here would be a 5 s tax on every agent invocation;
  #   * the attempt is stamped BEFORE the spawn, so an offline box backs off a full TTL instead of
  #     piling up one hung `git` per invocation, and degrades silently to the local-only behaviour;
  #   * the cache lives in the checkout's git dir, so it is removed with the clone and needs no new
  #     global state;
  #   * `ls-remote` is read-only and takes no repo lock, so it is safe against the 3–6 concurrent
  #     sessions sharing a clone, and needs no credential (this repo is public over https). Credential
  #     helpers and terminal prompts are disabled for the call outright — an auth prompt is a hang, and
  #     a hang is the one thing this must never do.
  #
  # A BUNDLED copy is deliberately left out of the remote half: bundler's install path is governed by
  # the Gemfile pin, whose update already fails loudly through the lock and the deploy, so there is
  # nothing to buy there — and it is the highest-frequency caller, the last place to add a subprocess.
  #
  # CLI-only: `exe/linear` calls this, NOT `require "linear_cli"`, so a host app driving
  # Linear::Client from a WEB REQUEST — a consumer's admin endpoint, serving live traffic — never shells
  # out to git mid-request.
  module Checkout
    # The checkout this file was loaded from — lib/linear_cli/ is two levels below the repo root.
    ROOT = File.expand_path("../..", __dir__)

    # Opt out (e.g. a box deliberately pinned behind, or a caller that parses stderr).
    SKIP_ENV = "LINEAR_CLI_SKIP_CHECKOUT_CHECK"

    # Only `lib/` and `exe/` count as "dirty": they are the code the CLI actually executes. Scoping the
    # status this way is also what keeps bundler's vendored copy quiet — bundler rewrites the gemspec of
    # a git-source gem in place, so `M linear_cli.gemspec` is permanent bookkeeping there rather than a
    # half-finished edit, and crying wolf on every run of a HIGH-FREQUENCY caller — a consumer whose own
    # `bin/linear` shells out dozens of times an hour — would train the eye to ignore the one line that
    # matters.
    CODE_PATHS = %w[lib exe].freeze

    # Bundler's install layout for a git-source gem (`<bundle path>/bundler/gems/<name>-<shortsha>`).
    # Such a checkout is MANAGED: bundler re-clones it from Gemfile.lock, so a hand `git checkout`
    # inside it is clobbered by the next `bundle install` and desyncs the lock. Staleness there is
    # real and worth reporting — it means the Gemfile pin is behind — but the remedy is a different
    # command, so it gets its own. (Whether such a copy carries tags at all varies with how the bundle
    # was installed; both shapes are handled.)
    BUNDLER_LAYOUT = %r{/bundler/gems/[^/]+/?\z}

    # The cached `git ls-remote --tags origin` result, written into the checkout's git dir so it is
    # removed with the clone (and, in a linked worktree, with the worktree). Raw ls-remote output:
    # parsing it here rather than in the refresher keeps every version comparison in one place, and
    # makes a truncated or garbled cache indistinguishable from an empty one.
    REMOTE_CACHE = "linear_cli-remote-tags"

    # How long a cached answer is good for. 12 h is the low end of AGT-231's 12–24 h — releases here
    # have come three-in-a-day — and it is a floor on nothing: the lookup is detached, so a shorter
    # TTL costs the CLI no time at all, only requests to origin.
    REMOTE_TTL = 12 * 60 * 60

    # Opt out of the REMOTE half alone (an air-gapped box, or one that must make no outbound
    # connections at all). SKIP_ENV still disables the whole check, local half included.
    SKIP_REMOTE_ENV = "LINEAR_CLI_SKIP_REMOTE_CHECK"

    # Override REMOTE_TTL, in seconds (a box that wants to hear about a release sooner, or an
    # air-gapped one that wants to try less often than daily).
    REMOTE_TTL_ENV = "LINEAR_CLI_REMOTE_TTL"

    # Never read more than this from the cache. It is ~2 KB of ls-remote output for this repo; the cap
    # is there so a file that is somehow enormous cannot turn an advisory into a stall.
    MAX_CACHE_BYTES = 64 * 1024

    # The refresher, run DETACHED. Paths arrive as positional parameters, so nothing is re-parsed by
    # the shell and a path with spaces needs no quoting. Written to a temp file and renamed, so a
    # concurrent reader sees either the old answer or the new one, never half of one.
    #
    # `credential.helper=` / `core.askPass=` / `GIT_TERMINAL_PROMPT=0` are the load-bearing part: an
    # auth prompt is a hang, and this must never hang. The repo is public over https, so a call that
    # would need a credential is a call that should fail and stay silent. The low-speed knobs bound a
    # connection that opens and then stalls.
    REFRESH_SH = <<~SH
      if git -C "$1" -c credential.helper= -c core.askPass= \
             -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
             ls-remote --tags --refs origin >"$2" 2>/dev/null
      then mv -f "$2" "$3"
      else rm -f "$2"
      fi
    SH

    REFRESH_ENV = {
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes"
    }.freeze

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
        # and rightly so, since the Gemfile pin, not this file, is what fixes a BUNDLED consumer's
        # version.
        local = newest_tag(root) or return []

        # …and only THEN consult the remote cache. Gating the network half behind "this checkout has
        # release tags" is what keeps bundler's vendored copy exactly as silent as it was, and keeps
        # the subprocess off it entirely.
        remote = remote_tag(root, dot_git)
        origin = remote && version_of(remote) > version_of(local)
        newest = origin ? remote : local

        lines = []
        lines.concat(stale_lines(root, version, newest, origin)) if behind?(version, newest)
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
      def stale_lines(root, version, newest, origin = false)
        # Say WHERE the newer tag was seen. "behind v2.17.0 on origin" is the difference between a
        # confusing line and an actionable one on a box that does not have v2.17.0 locally — and it is
        # why both fix lines below open with a fetch.
        lines = ["  ! linear_cli #{version} is behind #{newest}#{" on origin" if origin} — this " \
                 "checkout is serving old code (#{origin ? "AGT-231" : "AGT-222"})"]
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

      # The newest release tag ORIGIN has, as of the last cached lookup — or nil when there is no usable
      # answer, which is every failure mode: no cache yet, an unreachable origin, no `origin` remote at
      # all, a truncated or garbled file, an unreadable git dir. Every one of them degrades to the
      # local-only behaviour in silence; none of them warns, delays, or raises.
      #
      # Reading is a `stat` plus a small `read`. The lookup itself is spawned at most once per TTL and
      # is never waited on, so this method's cost does not depend on the network being there.
      def remote_tag(root, dot_git)
        return nil if ENV[SKIP_REMOTE_ENV] == "1"
        # Bundler owns its install path and the pin that fixes its version; see the note above.
        return nil if root.match?(BUNDLER_LAYOUT)

        dir = git_dir(root, dot_git) or return nil
        cache = File.join(dir, REMOTE_CACHE)
        refresh_remote_cache(root, cache) if cache_stale?(cache)
        newest_in(File.read(cache, MAX_CACHE_BYTES))
      rescue StandardError
        nil
      end

      # Newest `vX.Y.Z` in raw `ls-remote` output. Only whole lines count — a cache truncated by
      # MAX_CACHE_BYTES ends mid-line, and half a tag name is not a tag.
      def newest_in(text)
        text.to_s.lines.select { |l| l.end_with?("\n") }
            .filter_map { |l| l[%r{refs/tags/(v\d+(?:\.\d+)*)\s*\z}, 1] }
            .max_by { |t| version_of(t) }
      end

      # Older than the TTL, or not there at all. mtime is the time of the last ATTEMPT, not of the last
      # success — see #refresh_remote_cache.
      def cache_stale?(cache)
        Time.now - File.mtime(cache) > ttl
      rescue SystemCallError
        true
      end

      def ttl
        seconds = ENV[REMOTE_TTL_ENV].to_i
        seconds.positive? ? seconds : REMOTE_TTL
      end

      # Kick off the lookup and return immediately. The ATTEMPT is stamped first, on purpose: a box
      # that cannot reach origin then backs off a full TTL instead of spawning one more hung `git` per
      # invocation — and a box invoking `linear` dozens of times an hour would pile those up fast.
      # The child writes the answer if it gets one; if it does not, the stamp is all that changes and
      # whatever the cache already held stays.
      def refresh_remote_cache(root, cache)
        stamp(cache)
        pid = Process.spawn(REFRESH_ENV, "sh", "-c", REFRESH_SH, "sh",
                            root, "#{cache}.#{Process.pid}.tmp", cache,
                            in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
        # Reap it if we outlive it; orphan it if we do not. Either way we never wait.
        Process.detach(pid)
      rescue StandardError
        nil
      end

      def stamp(cache)
        return File.binwrite(cache, "") unless File.exist?(cache)

        now = Time.now
        File.utime(now, now, cache)
      end

      # The git dir for `root`: `.git` itself in the main worktree, and the `.git/worktrees/<name>`
      # directory a LINKED worktree's `.git` FILE points at. Read, not `git rev-parse --git-dir` — the
      # healthy path stays at two git invocations.
      def git_dir(root, dot_git)
        return dot_git if File.directory?(dot_git)

        pointer = File.read(dot_git, 4096).to_s[/\Agitdir:\s*(.+?)\s*\z/m, 1] or return nil
        dir = File.expand_path(pointer, root)
        dir if File.directory?(dir)
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
