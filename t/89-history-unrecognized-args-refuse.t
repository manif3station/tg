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

# TGT-122 (found via a scheduled hourly bug-hunt): cli/history.pl parsed
# --since/--until into $rest but never checked that nothing unrecognized
# remained afterward, unlike cli/send.pl (checks @extra, refuses) or
# cli/poller.pl (refuses on any unrecognized flag, TGT-107) - live
# reproduced before this fix: both cases below printed "No messages
# found." and exited 0 instead of refusing.

{
    my $out = `$history_cli --since 2020-01-01T00:00:00 --totally-bogus-flag 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 2, 'cli/history with an unrecognized flag refuses with exit 2' );
    like( $out, qr/Usage/i, 'the message names it as a usage problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for an unrecognized flag' );
}

{
    my $out = `$history_cli some garbage positional args 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 2, 'cli/history with leftover positional arguments refuses with exit 2' );
    like( $out, qr/Usage/i, 'the message names it as a usage problem' );
    unlike( $out, qr/^No messages found\.$/m, 'never silently claims a scoped-but-empty result for leftover args' );
}

# Every existing valid-usage case must be completely unaffected.
{
    my $out = `$history_cli 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'no arguments at all still exits 0' );
    like( $out, qr/No messages found\./, 'and still reports the expected clean message' );
}

{
    my $out = `$history_cli --since 2026-01-01T00:00:00 --until 2026-02-01T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, 'a normal --since <date> --until <date> pair still exits 0' );
    like( $out, qr/No messages found\./, 'a normal range with no matching messages still reports the expected clean message' );
}

# A Codex review raised whether the new check (placed after --since/
# --until parsing) could regress --db/-d, which is consumed earlier
# still (D2TG::Config::extract_db_flag, before the --since/--until
# loop even runs) - live-verified as a false alarm, but these cases
# make that verification a permanent regression test rather than a
# one-off manual check.
{
    my $out = `$history_cli --db testalias 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, '--db <alias> alone (already consumed before the new check runs) still exits 0' );
    like( $out, qr/No messages found\./, 'and still reports the expected clean message' );
}

{
    my $out = `$history_cli -d testalias --since 2026-01-01T00:00:00 2>&1`;
    my $rc  = $? >> 8;

    is( $rc, 0, '-d <alias> combined with --since still exits 0' );
    like( $out, qr/No messages found\./, 'and still reports the expected clean message' );
}

done_testing();
