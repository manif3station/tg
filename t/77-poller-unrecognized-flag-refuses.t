use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
use Test::CaptureStdio qw(run_capturing_stderr);

# TGT-107 (live-experienced incident, user-supplied /tmp/missing2.md,
# item 1): cli/poller.pl silently accepted ANY unrecognized flag
# (including --help) and proceeded to start a real poll loop - which,
# because D2TG::Lock's "last one wins" (TGT-084) SIGKILLs whichever
# process already holds the lock, meant a --help typo could take a live,
# legitimate poller offline. Both cases below must refuse (or, for
# --help, print usage and exit 0) BEFORE the lock file is ever created -
# not just before the poll loop starts, since acquiring the lock itself
# is the dangerous side effect.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli, '--help');

    is( $rc, 0, 'd2 tg.poller --help exits 0' );
    like( $out, qr/Usage/i, '--help prints a usage summary to stdout' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, '--help never creates the lock file - the poll loop never started' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli, '--some-unknown-flag');

    isnt( $rc, 0, 'an unrecognized flag exits non-zero' );
    like( $err, qr/--some-unknown-flag/, 'the STDERR message names the specific unrecognized flag' );
    is( $out, '', 'nothing printed to stdout on refusal' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, 'an unrecognized flag never creates the lock file - the poll loop never started' );
}

{
    # Codex review finding: an unrecognized flag must still be named
    # correctly even when D2TG_CHAT_ID is ALSO unset - otherwise the
    # D2TG_CHAT_ID-missing guard (which also refuses, correctly, but
    # for a different reason) fires first and masks the unrecognized-
    # flag error entirely, contradicting this ticket's own acceptance
    # criterion. Both are genuinely missing here; the unrecognized flag
    # must still be the one named.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli, '--some-unknown-flag');

    isnt( $rc, 0, 'an unrecognized flag exits non-zero even with D2TG_CHAT_ID also unset' );
    like( $err, qr/--some-unknown-flag/, 'the flag is still named, not masked by the D2TG_CHAT_ID guard' );

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );
    ok( !-e $lock_path, 'no lock file created in this case either' );
}

{
    # Regression: every currently-recognized flag combination must keep
    # working exactly as before - this ticket must not break TGT-049's
    # own multi-bot/--chat_id parsing.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    delete $ENV{D2TG_TOKEN};
    delete $ENV{D2TG_CHAT_ID};

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $pid = IPC::Open3::open3(
        my $in, $child_out, $child_err,
        $poller_cli, '--chat_id', '999', '--bot', 'sometoken'
    );

    my $first_line = <$child_out>;
    like( $first_line, qr/\S/, 'a well-formed --chat_id/--bot invocation still starts up normally (no regression)' );

    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );
}

done_testing();
