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

# TGT-302 (found via a user-requested comprehensive bug/improvement
# sweep): the --since/--until shape regex
# ^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2})?$ accepts syntactically
# well-formed but calendrically invalid dates (e.g. 2026-13-45, a
# nonexistent month/day combination) - it never validates the
# resulting date is a real calendar date, only that it looks
# shape-correct, so a value like that reaches
# D2TG::Store::messages_in_range's SQL comparison unvalidated.

{
    my $out = `$history_cli --since 2026-13-45 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-13-45 (invalid month/day) refuses instead of silently running a wrong query' );
    like( $out, qr/--since.*(?:calendar|valid|date)|Usage/i, 'the message names the actual problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for a calendrically invalid date' );
}

{
    my $out = `$history_cli --until 2026-02-30 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --until 2026-02-30 (February has no 30th) refuses instead of silently running a wrong query' );
    like( $out, qr/--until.*(?:calendar|valid|date)|Usage/i, 'the message names the actual problem' );
}

{
    my $out = `$history_cli --since 2026-04-31T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-04-31T00:00:00 (April has only 30 days) refuses even with a time component' );
}

# A genuine leap day must still be accepted (2028 is a leap year).
{
    my $out = `$history_cli --since 2028-02-29 --until 2028-03-01 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a genuine leap-year Feb 29 is accepted, not rejected as invalid' );
}

# A non-leap-year Feb 29 must be rejected (2026 is not a leap year).
{
    my $out = `$history_cli --since 2026-02-29 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-02-29 (2026 is not a leap year) is rejected' );
}

# Regression: an ordinary valid date-only and date+time value must
# still work exactly as before.
{
    my $out = `$history_cli --since 2026-01-01 --until 2026-02-01 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a normal valid date-only --since/--until pair still exits 0' );
    like( $out, qr/No messages found\./, 'a normal range with no matching messages still reports the expected clean message' );
}

{
    my $out = `$history_cli --since 2026-01-01T00:00:00 --until 2026-02-01T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a normal valid date+time --since/--until pair still exits 0' );
}

done_testing();
