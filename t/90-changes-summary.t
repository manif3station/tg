use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Config;

# TGT-112 (user-supplied live-experienced feedback): the version-bump
# restart notice named the old/new version numbers but not what
# actually changed, leaving the operator to go look up the Changes file
# themselves to find out. changes_summary extracts the first bullet
# line of a given version's own Changes entry, so the restart notice
# can print it directly.

sub write_changes {
    my ( $dir, $content ) = @_;
    open my $fh, '>', File::Spec->catfile( $dir, 'Changes' ) or die $!;
    print {$fh} $content;
    close $fh;
    return $dir;
}

{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.01  2026-09-07
      - Initial scaffold (TGT-001): lib/, cli/, t/.

0.02  2026-09-08
      - Second entry (TGT-002): does the second thing.
      - A follow-up bullet, ignored - only the first bullet is used.
CHANGES

    is(
        D2TG::Config::changes_summary( version => '0.02', default_root => $skill_root ),
        'Second entry (TGT-002): does the second thing.',
        'changes_summary extracts the first bullet line of the named version\'s own entry'
    );

    is(
        D2TG::Config::changes_summary( version => '0.01', default_root => $skill_root ),
        'Initial scaffold (TGT-001): lib/, cli/, t/.',
        'changes_summary correctly picks the matching version, not just the first/last entry'
    );
}

# A bullet that wraps onto a continuation line: only the first physical
# line is returned (a "short summary", per this ticket's own solution -
# not a full multi-line reflow).
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.05  2026-09-08
      - A long bullet that wraps (TGT-005): onto a second
        physical line of prose here.
CHANGES

    is(
        D2TG::Config::changes_summary( version => '0.05', default_root => $skill_root ),
        'A long bullet that wraps (TGT-005): onto a second',
        'changes_summary returns only the first physical line of a wrapped bullet'
    );
}

# Codex review finding: the entry boundary must anchor on the next
# real version header, not just any unindented line - otherwise an
# unindented line inside a still-valid entry would truncate it early
# and miss a real bullet further down.
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.06  2026-09-08
      - First bullet (TGT-006): fine on its own.
Note: an unindented aside line that is not a new version header.
      - A second bullet, still part of 0.06's own entry.

0.07  2026-09-09
      - Unrelated later entry.
CHANGES

    is(
        D2TG::Config::changes_summary( version => '0.06', default_root => $skill_root ),
        'First bullet (TGT-006): fine on its own.',
        'an unindented non-header line inside a valid entry does not corrupt extraction of its own first bullet'
    );
}

# Codex review finding (round 2): the boundary must require the full
# header shape (version + whitespace + ISO date + end of line), not
# just "digits, dot, digits, whitespace" - a stray prose line like
# "1.2 notes on something" inside a still-valid entry must not be
# mistaken for the next version header either.
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.08  2026-09-08
      - First bullet (TGT-008): still fine.
      - 1.2 notes on something unrelated, not a real header.
      - A second real bullet, still part of 0.08's own entry.
CHANGES

    is(
        D2TG::Config::changes_summary( version => '0.08', default_root => $skill_root ),
        'First bullet (TGT-008): still fine.',
        'a bullet line merely starting with digits/dot/digits/whitespace is not mistaken for a version header'
    );
}

# No entry for the requested version at all.
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.01  2026-09-07
      - Initial scaffold (TGT-001).
CHANGES

    is(
        D2TG::Config::changes_summary( version => '9.99', default_root => $skill_root ),
        undef,
        'changes_summary returns undef, not a crash, when the version has no entry'
    );
}

# Changes file missing entirely.
{
    my $skill_root = tempdir( CLEANUP => 1 );

    is(
        D2TG::Config::changes_summary( version => '0.01', default_root => $skill_root ),
        undef,
        'changes_summary returns undef, not a crash, when Changes is missing entirely'
    );
}

# TGT-190 (filed from TGT-187's own investigation): a version-match
# miss silently returned undef with zero diagnostic - a genuine future
# .env/Changes drift (not just the already-investigated TGT-187
# incident) would leave the restart notice's missing summary
# unexplained in the log. Now logs a distinguishable STDERR diagnostic
# naming both the requested version and a recognizable header found in
# the file - the happy path (a real match) stays completely silent,
# unchanged. A Codex QA-stage review finding: an earlier draft of this
# assertion only checked for the version substring '0.05', which would
# still have passed even if the diagnostic dropped the header's own
# date - now checks for the exact, full header line '0.05  2026-09-07'
# to genuinely prove the whole header is named, not just its version.
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.05  2026-09-07
      - Only entry in this file.
CHANGES

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    local *STDERR = $stderr_fh;

    my $result = D2TG::Config::changes_summary( version => '9.99', default_root => $skill_root );

    close $stderr_fh;

    is( $result, undef, 'changes_summary still returns undef on a version-match miss - unchanged behavior' );
    like(
        $stderr,
        qr/\bD2TG::Config::changes_summary\b.*\b9\.99\b.*\Q0.05  2026-09-07\E/s,
        'a version-match miss logs a STDERR diagnostic naming both the requested version (9.99) and the full recognizable header found (0.05  2026-09-07), not just its version number'
    );
}

# The happy path (a real match) must NOT print anything to STDERR -
# the diagnostic above is only for the miss case.
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

0.11  2026-09-08
      - Matches fine (TGT-011).
CHANGES

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    my $result = do {
        local *STDERR = $stderr_fh;
        D2TG::Config::changes_summary( version => '0.11', default_root => $skill_root );
    };
    close $stderr_fh;

    is( $result, 'Matches fine (TGT-011).', 'changes_summary still returns the summary correctly on a real match' );
    is( $stderr, '', 'no diagnostic is printed on the happy path - the miss-only diagnostic does not fire here' );
}

# TGT-187 (investigating a live user report that this feature's own
# restart notice wasn't appearing in a real installed/dispatched
# poller): every scenario above only ever exercises the default_root
# fallback - none set $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}, which is
# what a real `d2 tg.poller` dispatch actually sets (confirmed live on
# this host's own installed, running poller process - its own environ
# carries DEVELOPER_DASHBOARD_SKILL_ROOT pointing at the real install
# directory, and its own restart notice DID include the Changes-line
# summary correctly, e.g. "d2tg poller detected version change
# (1.43 -> 1.49) - RELIABILITY FIX (TGT-184, ..." observed directly on
# this project's own bridge). This closes the one path in
# changes_summary's own priority order (env var checked before
# default_root, identical to state_db_path's own already-tested
# priority order in t/10-state-path.t) that had no test coverage at
# all, matching the live evidence rather than contradicting it. This
# test unit-tests changes_summary's own env-var-vs-default_root
# priority logic in isolation (a Codex documentation-stage review
# finding: it does not itself integration-test SkillDispatcher or
# exercise a real `d2 tg.poller` dispatch - that verification was done
# manually, live, in a developer-dashboard:latest container and on
# this host's own real installed poller, not captured as an automated
# test here).
{
    my $skill_root = write_changes( tempdir( CLEANUP => 1 ), <<'CHANGES');
Revision history for the tg skill

1.49  2026-09-11
      - RELIABILITY FIX (TGT-184): matches the real installed Changes
        file's own shape.
CHANGES
    local $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = $skill_root;

    is(
        D2TG::Config::changes_summary( version => '1.49', default_root => '/this/path/must/be/ignored' ),
        'RELIABILITY FIX (TGT-184): matches the real installed Changes',
        'changes_summary reads Changes under DEVELOPER_DASHBOARD_SKILL_ROOT when set, not the given default_root - the real d2-dispatch code path, matching state_db_path\'s own already-tested priority order'
    );
}

done_testing();
