use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use lib "$Bin/lib";
use Test::CaptureStdio qw(run_capturing_stderr);

# TGT-071: a bare trailing --db/-d, or one immediately followed by
# another flag, must not silently swallow that flag's own name as the
# alias. Live-reproduced (JOB-003 bug-hunt, 2026-09-08):
#   cli/history --db --since 2026-01-01   -> "Unknown --db/-d alias '--since'"
#   cli/reply --db --bot sometoken ...    -> "Unknown --db/-d alias '--bot'"
#   cli/history --db --chat_id            -> "Unknown --db/-d alias '--chat_id'"
# D2TG::Config::extract_db_flag's own unit coverage lives in
# t/40-db-alias-resolution.t; this file adds CLI-process-level
# integration assurance across every cli/* script that parses --db,
# mirroring t/42-db-flag-cli-integration.t's own pattern (no hang risk
# here - every case exits immediately on the parse failure, well before
# any network call, so a plain backtick capture is safe).

my $history_cli = File::Spec->catfile( $Bin, '..', 'cli', 'history.pl' );
my $reply_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'reply.pl' );
my $approve_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' );
my $unread_cli   = File::Spec->catfile( $Bin, '..', 'cli', 'unread.pl' );
my $poller_cli   = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $history_cli, '--db', '--since', '2026-01-01' );
    is( $rc, 1, 'cli/history --db --since <date> (bare --db swallowing --since) exits 1' );
    like( $err, qr/--db\/-d requires a value/i, 'the STDERR message names --db/-d as requiring a value, not "Unknown alias --since"' );
    unlike( $out, qr/\[/, 'cli/history never prints message rows when --db was malformed' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $history_cli, '--db', '--chat_id' );
    is( $rc, 1, 'cli/history --db --chat_id (bare --db swallowing --chat_id) exits 1' );
    like( $err, qr/--db\/-d requires a value/i, 'the STDERR message correctly names --db/-d, not --chat_id' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( "timeout 3 $reply_cli", '--db', '--bot', 'sometoken', '12345', 'hello' );
    is( $rc, 1, 'cli/reply --db --bot <token> ... (bare --db swallowing --bot) exits 1, not a hang' );
    like( $err, qr/--db\/-d requires a value/i, 'cli/reply\'s own --db loop dies with the same clear message' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $approve_cli, '--db', '--bot' );
    is( $rc, 1, 'cli/approve --db --bot (bare --db swallowing --bot) exits 1' );
    like( $err, qr/--db\/-d requires a value/i, 'cli/approve refuses with a clear message' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $unread_cli, '--db' );
    is( $rc, 1, 'cli/unread --db (bare trailing --db, nothing after it) exits 1' );
    like( $err, qr/--db\/-d requires a value/i, 'cli/unread refuses with a clear message' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $poller_cli, '--db', '-d' );
    is( $rc, 1, 'cli/poller --db -d (bare --db swallowing -d itself) exits 1' );
    like( $err, qr/--db\/-d requires a value/i, 'cli/poller refuses with a clear message before ever contacting Telegram' );
}

SKIP: {
    # Regression: well-formed --db <alias> usage must still work exactly
    # as before (TGT-071 must not break the happy path it's hardening).
    # Requires a real Developer::Dashboard (host d2 framework) to reach
    # resolve_alias_dir's real-paths branch - same availability gate as
    # t/42-db-flag-cli-integration.t.
    skip 'real Developer::Dashboard not available in this test environment', 2
      unless eval { require Developer::Dashboard; Developer::Dashboard->can('d2') };

    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $history_cli, '--db', 'definitely-not-a-real-alias' );
    is( $rc, 1, 'a well-formed but unknown --db <alias> still fails at resolve_alias_dir, not at extract_db_flag' );
    like( $err, qr/Unknown --db\/-d alias 'definitely-not-a-real-alias'/i, 'the original "Unknown alias" message still fires for a real (if invalid) alias value' );
}

done_testing();
