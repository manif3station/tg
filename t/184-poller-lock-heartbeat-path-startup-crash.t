use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
use Test::CaptureStdio qw(run_capturing_stderr);

# TGT-184 (found while building TGT-183's own fix, a related but
# distinct finding): cli/poller.pl's lock_path(...) and
# heartbeat_path(...) calls - both earlier in the same startup
# sequence than the D2TG::Store->new call TGT-183 already fixed - are
# each unwrapped. Both internally call D2TG::Config's own
# make_path($vault_dir) unless -d $vault_dir on the identical .tira
# directory, and die the same raw way TGT-183 already fixed for
# D2TG::Store->new if that directory cannot be created.
#
# Since both calls share the identical .tira-creation code and
# lock_path runs first, once .tira exists (created by lock_path
# succeeding) heartbeat_path's own make_path call is a no-op (its
# "-d $vault_dir" guard is already true) UNDER THIS TEST'S static
# filesystem setup - only lock_path's own failure is exercised here.
# This is a real gap in THIS PASS's own test coverage, not a claim
# that heartbeat_path's failure is impossible to reproduce (a Codex
# QA-stage review correctly caught an earlier draft overclaiming that)
# - a deterministic test would need to monkeypatch lock_path itself to
# sabotage .tira again right after it succeeds, or accept a genuine
# filesystem race, neither of which this pass implements. Both call
# sites are wrapped identically in the actual code either way.
#
# A second Codex QA-stage review finding on this same ticket: the
# heartbeat_path failure branch ran before D2TG::Lock::release($lock_path)
# - since heartbeat_path's own eval only runs after D2TG::Lock::acquire
# already succeeded above it, that exit path leaked the just-acquired
# lock file. Fixed directly in cli/poller.pl (the release call now runs
# before that branch's exit 1) - not independently exercised by a test
# in this file for the same reachability reason as above, but the fix
# mirrors the exact release-before-exit pattern already used elsewhere
# in the same script.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

{
    # Root-proof, same technique TGT-183's own test uses: pre-create
    # .tira as a plain FILE, not a directory - lock_path's own
    # make_path (called first, since "-d .tira" is false) then fails
    # to create a directory where a file already sits.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $blocking_path = File::Spec->catfile( $fake_db_dir, '.tira' );
    open my $fh, '>', $blocking_path or die $!;
    close $fh;

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli);

    isnt( $rc, 0, 'a startup-time lock_path failure exits non-zero, not a hang or a background start' );
    unlike( $err, qr/\Q$fake_db_dir\E/, 'the STDERR message never contains the raw base_dir path (TGT-133 precedent)' );
    unlike( $err, qr/at \S+\.pm line \d+/, 'the STDERR message is a clean refusal, not a raw uncaught Perl death with a file/line trace' );

    my @lines = split /\n/, $err;
    is( $lines[-1], 'Failed to prepare storage location (an unexpected error) - refusing to start.',
        'the LAST STDERR line is the exact fixed, scrubbed refusal text' );
}

{
    # Regression: a normal, working startup must be completely
    # unaffected.
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
    like( $first_line, qr/\S/, 'a well-formed startup with real storage still works normally (no regression)' );

    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );
}

done_testing();
