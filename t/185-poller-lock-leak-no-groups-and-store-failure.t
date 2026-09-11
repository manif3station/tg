use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-185 (found via a Codex QA-stage review on TGT-184): lock_path
# and heartbeat_path succeed (so D2TG::Lock::acquire acquires the
# startup lock at .tira/telegram.pid), but a later exit 1 path -
# D2TG::Store->new's own TGT-183 failure branch - does not release
# that lock before exiting, leaving a stale lock file behind that
# blocks the next legitimate poller start until manually removed or
# TGT-084's staleness/eviction logic kicks in.
#
# The ticket's original second scenario (the "!@$groups" no-groups-
# configured check, cli/poller.pl around line 265) turned out, on
# inspection while writing this test, to be unreachable dead code:
# by the time that check runs, two earlier guards (the
# require_chat_id_or_warn call and the has_cli_groups/D2TG_CHAT_ID
# shape check) have already forced an exit for every combination that
# would leave D2TG::Config::bot_groups() returning an empty list -
# any --chat_id present in @ARGV, or a validly-shaped D2TG_CHAT_ID env
# var, always yields at least one group. Confirmed empirically below:
# the actual refusal message for a true no-groups run is
# "D2TG_CHAT_ID is not set..." from the earlier guard, never reaching
# lock_path/heartbeat_path/Lock::acquire at all - so no lock is ever
# held to leak in that case. Scope narrowed to the one reachable path.
#
# A second Codex QA-stage review round (on this ticket's own fix) found
# two MORE reachable exit paths sharing the identical gap: the "no bot
# tokens configured" exit (a --chat_id group with no --bot, and
# D2TG_TOKEN unset) and the exec()-restart-failure die further down in
# cli/poller.pl. Rather than adding a third/fourth explicit per-site
# D2TG::Lock::release() call, cli/poller.pl now has a single END block
# right after D2TG::Lock::acquire succeeds that releases the lock on
# any exit past that point - a structural fix for the whole bug class
# instead of another one-off patch. The no-bot-tokens scenario is
# covered below; the exec()-failure die is not independently exercised
# by a test in this file (triggering a real exec() failure
# deterministically would need environment sabotage this pass doesn't
# implement) but is covered by the same END-block mechanism as every
# other exit path.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

sub run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-185-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

{
    # Confirms the dead-code finding above: with no --chat_id/--bot
    # configured at all, the refusal comes from the earlier
    # require_chat_id_or_warn guard, well before lock_path/
    # heartbeat_path/D2TG::Lock::acquire ever run - so no lock file is
    # ever created for this case (nothing to leak).
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli);

    isnt( $rc, 0, 'a startup-time no-groups refusal exits non-zero' );
    like( $err, qr/D2TG_CHAT_ID is not set/, 'refuses via the earlier require_chat_id_or_warn guard, not the later !@$groups check' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, 'no lock file was ever created for this refusal (the guard fires before D2TG::Lock::acquire)' );
}

{
    # D2TG::Store->new fails (TGT-183's own root-proof technique: the
    # target db-file path pre-created as a directory) - lock_path/
    # heartbeat_path/D2TG::Lock::acquire all succeed first.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $blocking_db_path = File::Spec->catdir( $fake_db_dir, '.tira', 'telegram.messages.db' );
    make_path($blocking_db_path);

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli);

    isnt( $rc, 0, 'a startup-time D2TG::Store->new failure exits non-zero' );
    like( $err, qr/Failed to open local storage/, 'refuses with the expected storage-open message' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, 'the startup lock file does not survive a D2TG::Store->new failure' );
}

{
    # "No bot tokens configured" exit (a --chat_id group with no --bot,
    # D2TG_TOKEN unset) - lock_path/heartbeat_path/D2TG::Lock::acquire/
    # D2TG::Store->new all succeed first, then this check fires. A
    # second Codex QA-stage review round found this leaked the lock the
    # same way the Store->new branch above did - now covered by the
    # END-block backstop instead of a third explicit release() call.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) = run_capturing_stderr( $poller_cli, '--chat_id', '12345' );

    isnt( $rc, 0, 'a startup-time no-bot-tokens refusal exits non-zero' );
    like( $err, qr/No bot tokens configured/, 'refuses with the expected no-bot-tokens message' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, 'the startup lock file does not survive a no-bot-tokens refusal' );
}

done_testing();
