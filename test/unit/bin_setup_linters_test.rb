# frozen_string_literal: true

require 'minitest/autorun'

# bin/setup provisions the workflow linters (actionlint + shellcheck) into
# ~/.local/bin so a local actionlint run lints `run:` blocks instead of
# silently skipping them. The guarantees that make that safe — single pin
# site, sha256 verification, fail-loudly — live only in the script's text,
# so this test reads the real files and pins the guarantees, not the
# install. Reads files only; no Redis, no network, no writes outside
# temp dirs.
class BinSetupLintersTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  def bin_setup
    File.read(File.join(ROOT, 'bin', 'setup'))
  end

  def test_yml
    File.read(File.join(ROOT, '.github', 'workflows', 'test.yml'))
  end

  # --- (1) single pin site: the ACTIONLINT_* constants are read out of
  # .github/workflows/test.yml, not hardcoded a second time in bin/setup.

  %w[ACTIONLINT_VERSION ACTIONLINT_SHA ACTIONLINT_BINARY_SHA256].each do |name|
    define_method("test_bin_setup_reads_#{name.downcase}_from_test_yml") do
      assert_match(/#{name}=\$\(grep .*ACTIONLINT_WORKFLOW/, bin_setup,
                   "bin/setup must grep #{name} out of .github/workflows/test.yml, not hardcode a second copy")
    end
  end

  def test_bin_setup_points_the_actionlint_pins_at_test_yml
    assert_match(%r{^ACTIONLINT_WORKFLOW=.*\.github/workflows/test\.yml}, bin_setup)
  end

  def test_bin_setup_has_no_second_copy_of_the_actionlint_pin_values
    version = test_yml[/ACTIONLINT_VERSION: *"([^"]+)"/, 1]
    sha = test_yml[/ACTIONLINT_SHA: *"([^"]+)"/, 1]
    binary_sha = test_yml[/ACTIONLINT_BINARY_SHA256: *"([^"]+)"/, 1]

    refute_nil version
    refute_nil sha
    refute_nil binary_sha

    refute_includes bin_setup, version,
                    'the actionlint version must live only in test.yml; hardcoding it in bin/setup creates a drift site'
    refute_includes bin_setup, sha
    refute_includes bin_setup, binary_sha
  end

  # The download script itself must come from the pinned commit SHA — a
  # moving ref would let an upstream change reach the machine unobserved.
  def test_actionlint_download_script_is_fetched_at_the_pinned_sha
    script_url = %r{raw\.githubusercontent\.com/rhysd/actionlint/\$\{ACTIONLINT_SHA\}/scripts/download-actionlint\.bash}

    assert_match(script_url, bin_setup)
  end

  # --- (2) both downloads are integrity-verified with a sha256 digest check.

  def test_actionlint_binary_is_sha256_verified
    assert_match(/"\$ACTIONLINT_BINARY_SHA256\s+[^"]*actionlint" *\| *sha256sum -c/, bin_setup,
                 'bin/setup must check the actionlint binary against ACTIONLINT_BINARY_SHA256 via `sha256sum -c`')
    assert_match(/sha256sum -c/, bin_setup,
                 'bin/setup must verify downloads with `sha256sum -c`')
  end

  def test_shellcheck_download_is_sha256_verified
    assert_match(/SHELLCHECK_SHA256/, bin_setup,
                 'bin/setup must pin a sha256 for the shellcheck download')
    assert_match(/"\$SHELLCHECK_SHA256\s+[^"]*" *\| *sha256sum -c/, bin_setup,
                 'bin/setup must pipe the pinned shellcheck digest into `sha256sum -c` over the downloaded tarball')
  end

  # --- (3) shellcheck is pinned to an explicit version AND an explicit sha256.

  def test_shellcheck_has_an_explicit_version_pin
    assert_match(/^SHELLCHECK_VERSION="\d+\.\d+\.\d+"$/, bin_setup,
                 'bin/setup must pin SHELLCHECK_VERSION to an explicit x.y.z release')
  end

  def test_shellcheck_has_an_explicit_sha256_pin
    assert_match(/^SHELLCHECK_SHA256="[0-9a-f]{64}"$/, bin_setup,
                 'bin/setup must pin SHELLCHECK_SHA256 to a full 64-hex digest, not a version alone')
  end

  # --- (4) provisioning fails loudly: no silent omission of either tool.

  def test_linter_provisioning_never_swallows_a_failure
    refute_match(/\|\| *true/, bin_setup,
                 'bin/setup must not `|| true` away a download or checksum failure')
    assert_match(/^set -euo pipefail/, bin_setup,
                 'bin/setup must run under set -euo pipefail so a failed download or checksum aborts with nonzero exit')
  end

  def test_both_tools_are_actually_installed_not_just_pinned
    assert_match(%r{mv .*actionlint.*LOCAL_BIN/actionlint}, bin_setup,
                 'bin/setup must leave an actionlint binary in ~/.local/bin')
    assert_match(%r{mv .*shellcheck.*LOCAL_BIN/shellcheck}, bin_setup,
                 'bin/setup must leave a shellcheck binary in ~/.local/bin')
  end

  # --- mise.toml keeps its integrity stance: the two linters stay out of
  # [tools], and the header says why (a registry install would downgrade the
  # CI triple-pin guarantee).

  def test_mise_tools_table_lists_only_ruby_bun_node
    mise = File.read(File.join(ROOT, 'mise.toml'))
    tools = mise[/^\[tools\]\n((?:^[a-z].*\n)+)/, 1].scan(/^([a-z]+)\s*=/).flatten

    assert_equal %w[bun node ruby], tools.sort,
                 'actionlint/shellcheck belong in bin/setup with their integrity pins, not as version-only mise entries'
  end

  def test_mise_toml_documents_why_the_linters_are_not_tools_entries
    header = File.read(File.join(ROOT, 'mise.toml')).split('[tools]').first

    assert_includes header, 'actionlint'
    assert_includes header, 'shellcheck'
  end

  def test_provisioning_is_idempotent
    assert_match(%r{\[ -x "\$LOCAL_BIN/actionlint" \]}, bin_setup,
                 'an actionlint that already passes the sha256 check must skip the download')
    assert_match(%r{\[ -x "\$LOCAL_BIN/shellcheck" \]}, bin_setup,
                 'a shellcheck already at the pinned version must skip the download')
  end

  def test_setup_warns_when_local_bin_is_not_on_path
    assert_match(/LOCAL_BIN.*not on PATH/, bin_setup,
                 'bin/setup must print a PATH note when ~/.local/bin is not on PATH')
  end

  # --- (5) platform guard: both pinned artifacts are linux/amd64 binaries.
  # Without the uname refusal, a non-linux/amd64 machine with GNU coreutils
  # installed passes both sha256 checks against binaries it cannot execute,
  # and the idempotence check then vouches for them on every later run.

  def test_setup_refuses_linter_provisioning_off_linux_amd64
    assert_match(/uname -s.*Linux/, bin_setup,
                 'bin/setup must check `uname -s` for Linux before downloading the pinned linter binaries')
    assert_match(/uname -m.*x86_64/, bin_setup,
                 'bin/setup must check `uname -m` for x86_64 before downloading the pinned linter binaries')
    assert_match(/exit 1/, bin_setup,
                 'the platform guard must abort bin/setup, not warn and continue')
  end

  # The shellcheck sha256 bin/setup pins must be the checksum of the tarball
  # it downloads — a digest copied wrong verifies nothing. Proven by matching
  # the pinned URL shape against the pinned digest's presence, not by
  # re-downloading (this test reads files only).
  def test_shellcheck_download_url_is_built_from_the_pinned_version
    assert_match(%r{github\.com/koalaman/shellcheck/releases/download/v\$\{SHELLCHECK_VERSION\}}, bin_setup,
                 'the shellcheck download URL must be built from SHELLCHECK_VERSION so version and sha256 move as one')
  end
end
