use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Lock;

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    ok( D2TG::Lock::acquire($lock), 'acquire succeeds when no lock file exists' );
    ok( -e $lock, 'the lock file was created' );

    open my $fh, '<', $lock or die $!;
    my $pid = <$fh>;
    close $fh;
    chomp $pid;
    is( $pid, $$, 'the lock file contains our own PID' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    # Fork a real, live-but-not-us process to simulate another poller
    # instance genuinely holding the lock (kill(0, $$) would wrongly
    # read as "not a conflict" per acquire()'s own-PID exemption).
    my $child_pid = fork();
    if ( !defined $child_pid ) {
        die "fork failed: $!";
    }
    elsif ( $child_pid == 0 ) {
        sleep 30;
        exit 0;
    }

    open my $fh, '>', $lock or die $!;
    print {$fh} "$child_pid\n";
    close $fh;

    # TGT-084 (live user request + live production incident): "last one
    # wins" - a second acquire() no longer refuses, it kills the
    # existing live holder and takes over.
    ok( D2TG::Lock::acquire($lock), 'a second acquire() takes over from an existing live holder instead of refusing (TGT-084)' );

    my $dead_tries = 0;
    while ( $dead_tries++ < 100 && kill( 0, $child_pid ) ) {
        select( undef, undef, undef, 0.01 );
    }
    ok( !kill( 0, $child_pid ), 'the existing live holder was actually killed' );

    open my $fh2, '<', $lock or die $!;
    my $pid = <$fh2>;
    close $fh2;
    chomp $pid;
    is( $pid, $$, 'the lock file now names our own PID' );

    waitpid( $child_pid, 0 );
    D2TG::Lock::release($lock);
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    # A PID that (almost certainly) does not exist, simulating a stale
    # lock left by an unclean death (e.g. kill -9).
    my $dead_pid = 999999;
    open my $fh, '>', $lock or die $!;
    print {$fh} "$dead_pid\n";
    close $fh;

    ok( D2TG::Lock::acquire($lock), 'a stale lock (dead PID) is reclaimed, not treated as a conflict' );

    open my $fh2, '<', $lock or die $!;
    my $pid = <$fh2>;
    close $fh2;
    chomp $pid;
    is( $pid, $$, 'the reclaimed lock file now contains our own PID' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    D2TG::Lock::acquire($lock);
    ok( D2TG::Lock::acquire($lock), 're-acquiring our own already-held lock succeeds (exec-restart case, TGT-036)' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    D2TG::Lock::acquire($lock);
    D2TG::Lock::release($lock);
    ok( !-e $lock, 'release removes a lock file naming our own PID' );

    ok( D2TG::Lock::acquire($lock), 'a fresh acquire after release succeeds immediately' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    D2TG::Lock::release($lock);
    pass( 'release on a non-existent lock file is a silent no-op' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    open my $fh, '>', $lock or die $!;
    print {$fh} "999999\n";
    close $fh;

    D2TG::Lock::release($lock);
    ok( -e $lock, 'release never removes a lock file naming a different PID' );
}

done_testing();
