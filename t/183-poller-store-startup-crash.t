use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-183 (found via a scheduled JOB-003 hourly bug hunt, reproduced
# live in the perl-test Docker container): cli/poller.pl's startup
# sequence wraps every other fallible step (require_existing_base_dir,
# D2TG::Lock::acquire) in eval/print-STDERR/exit(1), refusing to start
# loudly and cleanly on failure - except the D2TG::Store->new(...)
# call, which was completely unwrapped. A startup-time DB-open failure
# crashed the poller with a raw, uncaught Perl death instead of the
# clean refusal every sibling startup check already produces, and the
# raw DBI/SQLite exception text can embed the real db_path - the exact
# information-disclosure surface TGT-133 already closed off at every
# OTHER call site, but not this one.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

sub run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-183-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

{
    # The test container runs as root, so a plain chmod-to-read-only
    # directory doesn't actually block anything (root bypasses
    # permission checks). Also: colliding .tira ITSELF (e.g. pre-
    # creating it as a plain file) fails earlier and differently than
    # intended - D2TG::Config::lock_path and ::heartbeat_path each
    # independently call make_path on that same .tira directory too,
    # both from unwrapped top-level calls earlier in cli/poller.pl's
    # own startup sequence (a real, related finding, but a wider fix
    # than this ticket's own scoped AC covers - not addressed here).
    # Force a failure specific to D2TG::Store->new's own DBI->connect
    # instead, root-proof and independent of those earlier calls:
    # pre-create the .tira directory normally (so lock_path/
    # heartbeat_path both succeed exactly as today), then pre-create
    # the DATABASE FILE PATH ITSELF as a directory rather than a file -
    # SQLite cannot open a directory as a database file, regardless of
    # permissions or root.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $blocking_path = File::Spec->catdir( $fake_db_dir, '.tira', 'telegram.messages.db' );
    require File::Path;
    File::Path::make_path($blocking_path);

    my ( $out, $rc, $err ) = run_capturing_stderr($poller_cli);

    isnt( $rc, 0, 'a startup-time storage failure exits non-zero, not a hang or a background start' );
    unlike( $err, qr/\Q$fake_db_dir\E/, 'the STDERR message never contains the raw db_path (TGT-133 precedent)' );
    unlike( $err, qr/at \S+\.pm line \d+/, 'the STDERR message is a clean refusal, not a raw uncaught Perl death with a file/line trace' );
    is( $err, "Failed to open local storage (an unexpected error) - refusing to start.\n",
        'the STDERR message is the exact fixed, scrubbed refusal text - not just a loose substring match' );
}

{
    # Regression: a normal, working startup must be completely
    # unaffected - this is a pure "wrap it in eval" fix, not a
    # behavior change on the success path.
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
