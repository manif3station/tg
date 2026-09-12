use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);

my $history_cli = File::Spec->catfile( $Bin, '..', 'cli', 'history.pl' );

use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );
$ENV{D2TG_CHAT_ID} = '999999';

# TGT-070: a bare trailing --since (no value) previously silently ran
# the query unscoped instead of erroring on the malformed invocation -
# live-verified before this fix ("No messages found." + exit 0).
{
    my $out = `$history_cli --since 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since (bare, no value) refuses instead of silently running unscoped' );
    like( $out, qr/--since.*requires a value|Usage/i, 'the message names the actual problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for a malformed invocation' );
}

# --since immediately followed by --until previously swallowed
# '--until' itself as the since value, silently mis-scoping the query.
{
    my $out = `$history_cli --since --until 2026-01-01 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since --until <date> refuses instead of swallowing --until as the since value' );
    like( $out, qr/--since.*requires a value|Usage/i, 'the message names the actual problem' );
}

# A normal --since/--until pair must be completely unaffected.
{
    my $out = `$history_cli --since 2026-01-01T00:00:00 --until 2026-02-01T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a normal --since <date> --until <date> pair still exits 0' );
    like( $out, qr/No messages found\./, 'a normal range with no matching messages still reports the expected clean message' );
}

# TGT-209 (found via a scheduled JOB-003 hourly bug hunt, reproduced
# live): a value that IS present but doesn't look like a date at all
# used to be accepted silently and passed straight into
# D2TG::Store::messages_in_range's own lexicographic SQL comparison -
# a malformed value like 'not-a-date' sorts lexicographically AFTER
# every real ISO8601 timestamp, so a >= comparison against it silently
# excludes every real message, producing the exact same misleading
# "No messages found." this project's own TGT-070 already fixed for
# the missing-value case, but for a wrong-shaped value instead.
{
    my $out = `$history_cli --since not-a-date 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since not-a-date refuses instead of silently running a wrong query' );
    like( $out, qr/--since.*(?:ISO8601|date|format)|Usage/i, 'the message names the actual problem (a malformed date), not a generic error' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for a malformed date value' );
}

{
    my $out = `$history_cli --until 2020/01/01 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --until 2020/01/01 (slashes, not dashes) refuses instead of silently misbehaving' );
    like( $out, qr/--until.*(?:ISO8601|date|format)|Usage/i, 'the message names the actual problem' );
}

# Regression: a date-only value (no time component) must still work,
# matching the solution's own documented ISO8601-date-or-datetime
# shape.
{
    my $out = `$history_cli --since 2026-01-01 --until 2026-02-01 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a date-only --since/--until pair (no time component) still exits 0' );
    like( $out, qr/No messages found\./, 'a date-only range with no matching messages still reports the expected clean message' );
}

done_testing();
