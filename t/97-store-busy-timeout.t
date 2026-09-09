use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);
use Time::HiRes qw(time);

require D2TG::Store;

sub fresh_db_path {
    my ( $fh, $path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $path;
    return $path;
}

{
    my $db    = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    my ($timeout) = $store->{dbh}->selectrow_array('PRAGMA busy_timeout');
    is( $timeout, 5000, 'D2TG::Store::new sets PRAGMA busy_timeout to 5000ms' );

    my ($journal_mode) = $store->{dbh}->selectrow_array('PRAGMA journal_mode');
    is( lc($journal_mode), 'wal', 'D2TG::Store::new sets PRAGMA journal_mode to WAL' );
}

{
    # The real-world scenario this ticket targets: two SEPARATE OS
    # processes (as two independently-invoked `d2 tg.*` commands would
    # be), each with their own D2TG::Store handle on the same db_path -
    # one holds a write lock while the other attempts a write. Without
    # busy_timeout, the second write fails instantly with a locked-
    # database error; with it, the second write waits (briefly) and
    # succeeds once the first process commits and exits.
    my $db = fresh_db_path();

    # Create the schema up front in this process, before forking, so
    # both sides connect to an already-initialized database.
    D2TG::Store->new( db_path => $db, admin_chat_id => 999 )->disconnect;

    # A Codex review finding: a fixed sleep before the parent's write is
    # a race - if the child hasn't actually acquired its write lock yet,
    # the parent's write would succeed immediately and the test would
    # pass without ever proving the wait/busy-timeout behavior at all.
    # A pipe lets the child signal readiness (lock genuinely held)
    # deterministically instead.
    pipe( my $ready_r, my $ready_w ) or die "pipe failed: $!";

    my $lock_holder_pid = fork();
    die "fork failed: $!" unless defined $lock_holder_pid;

    if ( $lock_holder_pid == 0 ) {
        close $ready_r;
        my $store = D2TG::Store->new( db_path => $db );
        $store->{dbh}->begin_work;
        $store->{dbh}->do("INSERT INTO meta (key, value) VALUES ('lock_holder_test', '1')");
        print {$ready_w} "1\n";    # lock genuinely held - safe for the parent to attempt its own write now
        close $ready_w;
        select( undef, undef, undef, 1 );    # hold the write lock briefly
        $store->{dbh}->commit;
        exit 0;
    }

    close $ready_w;
    my $signal = <$ready_r>;    # blocks until the child actually holds the lock
    close $ready_r;

    my $store_b = D2TG::Store->new( db_path => $db );

    my $started = time();
    my $error = eval {
        local $SIG{ALRM} = sub { die "test-level safety timeout - real busy_timeout did not bound the wait\n" };
        alarm(10);
        $store_b->{dbh}->do("INSERT INTO meta (key, value) VALUES ('waiting_writer_test', '1')");
        1;
    } ? undef : $@;
    alarm(0);    # a Codex review finding: clear unconditionally - the prior code only cleared it on success, leaving it armed if the write died
    my $elapsed = time() - $started;

    my $reaped = waitpid( $lock_holder_pid, 0 );
    is( $reaped, $lock_holder_pid, 'the lock-holder child process was actually reaped' );
    is( $?, 0, 'the lock-holder child exited cleanly (status 0), so its own write/commit did not silently fail' );

    ok( !$error, "the second store's write succeeded rather than dying with a locked-database error (error: @{[ $error // '' ]})" );
    ok( $elapsed < 5, "the write waited for the lock to clear rather than either failing instantly or exceeding busy_timeout (elapsed=${elapsed}s)" );

    my ($value) = $store_b->{dbh}->selectrow_array("SELECT value FROM meta WHERE key = 'waiting_writer_test'");
    is( $value, '1', "the waiting writer's data actually landed" );
}

done_testing();
