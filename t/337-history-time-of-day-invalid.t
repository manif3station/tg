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

# TGT-337 (found via a live, user-requested adversarial bug hunt): the
# --since/--until shape regex and TGT-302's own calendar-date
# round-trip both validate only the DATE part of a full date+time
# value - the time-of-day component (HH:MM:SS) was never validated at
# all, so a syntactically well-formed but impossible value like
# 2026-01-01T99:99:99 reached D2TG::Store::messages_in_range's own
# lexicographic SQL comparison unvalidated, silently excluding every
# real message - the same misleading "No messages found." bug class
# TGT-209/TGT-302 already fixed for other malformed-value shapes, just
# never covering the time-of-day piece.

{
    my $out = `$history_cli --since 2026-01-01T99:99:99 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-01-01T99:99:99 (impossible time-of-day) refuses instead of silently running a wrong query' );
    like( $out, qr/--since.*(?:time|valid)|Usage/i, 'the message names the actual problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for an impossible time-of-day' );
}

{
    my $out = `$history_cli --until 2026-01-01T24:00:00 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --until 2026-01-01T24:00:00 (hour 24 does not exist) refuses' );
}

{
    my $out = `$history_cli --since 2026-01-01T12:60:00 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-01-01T12:60:00 (minute 60 does not exist) refuses' );
}

{
    my $out = `$history_cli --since 2026-01-01T12:00:60 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/history --since 2026-01-01T12:00:60 (second 60 does not exist) refuses' );
}

# Regression: the boundary values 00:00:00 and 23:59:59 must still be
# accepted - the fix must not reject any real time-of-day.
{
    my $out = `$history_cli --since 2026-01-01T00:00:00 --until 2026-01-01T23:59:59 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'boundary times 00:00:00/23:59:59 are still accepted' );
}

# Regression: a date-only value (no time component at all) must be
# completely unaffected by this fix.
{
    my $out = `$history_cli --since 2026-01-01 --until 2026-02-01 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a date-only --since/--until pair still exits 0, unaffected by the time-of-day check' );
}

done_testing();
