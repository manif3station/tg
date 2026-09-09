use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);
use File::Temp qw(tempfile);

require D2TG::Transcribe;

{
    local $D2TG::Transcribe::TIMEOUT = 1;

    my $started = time();
    eval { D2TG::Transcribe::_run( $^X, '-e', 'sleep 30' ) };
    my $error   = $@;
    my $elapsed = time() - $started;

    ok( $error, '_run died rather than waiting out the hung command' );
    like( $error, qr/timed out/i, 'the error names a timeout, not a generic failure' );
    ok( $elapsed < 5, "died within the bounded timeout window, not after the hung command's own 30s sleep (elapsed=${elapsed}s)" );
}

{
    # TGT-128: the whole process group - including a grandchild the
    # timed-out command itself spawns - must be terminated, not just the
    # immediate whisper-standin process.
    local $D2TG::Transcribe::TIMEOUT = 1;

    my ( $fh, $pidfile ) = tempfile( UNLINK => 0 );
    close $fh;

    my $script = <<'PERL';
my $gc = fork();
if ( $gc == 0 ) {
    exec( 'sleep', '30' );
    exit 1;
}
open my $out, '>', $ARGV[0] or exit 1;
print $out "$gc\n";
close $out;
sleep(30);
PERL

    eval { D2TG::Transcribe::_run( $^X, '-e', $script, $pidfile ) };
    my $error = $@;

    like( $error, qr/timed out/i, 'the group-kill test case also times out as expected' );

    open my $in, '<', $pidfile or die $!;
    my $grandchild_pid = <$in>;
    close $in;
    chomp $grandchild_pid if defined $grandchild_pid;
    unlink $pidfile;

    SKIP: {
        skip 'no /proc on this platform to inspect process state', 1 unless -d '/proc';
        skip 'grandchild pid was never written (process did not reach that far in time)', 1
          unless defined $grandchild_pid && length $grandchild_pid;

        # kill(0, $pid) is not a reliable liveness check here: a killed
        # child that nothing has waitpid()'d on becomes a zombie, and a
        # zombie still answers kill(0) truthfully (its PID slot exists)
        # even though it is not actually running - and this test process
        # is not the grandchild's parent, so it can never reap it itself.
        # /proc/<pid>/stat's state field distinguishes "actually still
        # running" (R/S/D) from "gone, or a killed-but-unreaped zombie"
        # (no entry at all, or state Z) - only the former means the fix
        # failed to reach it.
        my $actually_running = 1;
        for ( 1 .. 20 ) {
            if ( open my $fh, '<', "/proc/$grandchild_pid/stat" ) {
                my $line = <$fh>;
                close $fh;
                my ($state) = $line =~ /^\d+\s+\([^)]*\)\s+(\S)/;
                $actually_running = defined($state) && $state !~ /^[ZX]$/;
            }
            else {
                $actually_running = 0;    # /proc entry gone entirely - reaped, definitely not running
            }
            last unless $actually_running;
            select( undef, undef, undef, 0.1 );
        }

        ok( !$actually_running, "the grandchild process (pid $grandchild_pid) was also terminated (dead or zombie), not left actually running" );
    }
}

{
    # The KILL escalation path only fires when TERM alone doesn't reap
    # the process within the 1s grace period - a process that ignores
    # SIGTERM forces exactly that.
    local $D2TG::Transcribe::TIMEOUT = 1;

    my $started = time();
    eval { D2TG::Transcribe::_run( $^X, '-e', '$SIG{TERM} = "IGNORE"; sleep 30' ) };
    my $error   = $@;
    my $elapsed = time() - $started;

    like( $error, qr/timed out/i, '_run still dies with a timeout message when the command ignores TERM' );
    ok( $elapsed < 5, "the KILL escalation reaped the TERM-ignoring process well before its own 30s sleep (elapsed=${elapsed}s)" );
}

{
    # A Codex review finding: gating the KILL escalation on the group
    # LEADER's own reap status missed the case where the leader exits
    # cleanly on TERM but a descendant it spawned ignores TERM and
    # survives - that descendant would never receive a KILL. Here the
    # immediate child (the "leader") dies promptly on TERM (default
    # disposition), while its grandchild ignores TERM entirely - only an
    # unconditional group KILL reaches it.
    local $D2TG::Transcribe::TIMEOUT = 1;

    my ( $fh, $pidfile ) = tempfile( UNLINK => 0 );
    close $fh;

    my $script = <<'PERL';
my $gc = fork();
if ( $gc == 0 ) {
    $SIG{TERM} = 'IGNORE';
    exec( $^X, '-e', '$SIG{TERM} = "IGNORE"; sleep 30' );
    exit 1;
}
open my $out, '>', $ARGV[0] or exit 1;
print $out "$gc\n";
close $out;
sleep(30);    # the leader itself has no TERM handler - dies promptly on TERM
PERL

    eval { D2TG::Transcribe::_run( $^X, '-e', $script, $pidfile ) };
    my $error = $@;

    like( $error, qr/timed out/i, 'leader-exits-but-grandchild-survives-TERM case still times out as expected' );

    open my $in, '<', $pidfile or die $!;
    my $grandchild_pid = <$in>;
    close $in;
    chomp $grandchild_pid if defined $grandchild_pid;
    unlink $pidfile;

    SKIP: {
        skip 'no /proc on this platform to inspect process state', 1 unless -d '/proc';
        skip 'grandchild pid was never written (process did not reach that far in time)', 1
          unless defined $grandchild_pid && length $grandchild_pid;

        my $actually_running = 1;
        for ( 1 .. 20 ) {
            if ( open my $fh, '<', "/proc/$grandchild_pid/stat" ) {
                my $line = <$fh>;
                close $fh;
                my ($state) = $line =~ /^\d+\s+\([^)]*\)\s+(\S)/;
                $actually_running = defined($state) && $state !~ /^[ZX]$/;
            }
            else {
                $actually_running = 0;
            }
            last unless $actually_running;
            select( undef, undef, undef, 0.1 );
        }

        ok( !$actually_running,
            "the TERM-ignoring grandchild (pid $grandchild_pid) was still reached by the unconditional group KILL, even though the leader already exited on TERM" );
    }
}

done_testing();
