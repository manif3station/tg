use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

# TGT-102 (bug-hunt finding, JOB-003): acquire() re-entering with the
# caller's own already-held PID (exactly what cli/poller.pl's
# version-triggered self-restart does every time, since exec() preserves
# the PID) had no fast-path - it fell through into the fallback reclaim
# path (unconditional unlink+recreate for any readable PID that wasn't a
# live different-PID conflict) even though the PID was the caller's own,
# live process. That created a narrow race window where an
# independently-started second poller could land between the unlink and
# the recreate and SIGKILL the legitimately self-restarting process.
# acquire() must now short-circuit on $pid == $$ without ever touching
# the file on disk.
#
# The spy below must be installed via BEGIN, before D2TG::Lock is
# required - overriding CORE::GLOBAL::unlink only affects code compiled
# after the override exists, and D2TG::Lock's own compiled call to
# unlink() would otherwise never see it.

our $UNLINK_CALLS = 0;

BEGIN {
    no warnings 'redefine';
    *CORE::GLOBAL::unlink = sub { $UNLINK_CALLS++; return CORE::unlink(@_); };
}

require D2TG::Lock;

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    ok( D2TG::Lock::acquire($lock), 'first acquire succeeds' );
    is( $UNLINK_CALLS, 0, 'first acquire (fresh lock) never calls unlink' );

    my @stat_before  = stat($lock);
    my $inode_before = $stat_before[1];
    ok( defined $inode_before, 'lock file has a stat-able inode after first acquire' );

    ok( D2TG::Lock::acquire($lock), 'second acquire by the same PID (own-PID re-entry) succeeds' );
    is( $UNLINK_CALLS, 0, 'own-PID re-acquire never calls unlink at all' );

    my @stat_after  = stat($lock);
    my $inode_after = $stat_after[1];
    is( $inode_after, $inode_before,
        'own-PID re-acquire leaves the same inode - the file itself was never recreated, not just "no unlink() call observed"'
    );

    open my $fh, '<', $lock or die $!;
    my $pid = <$fh>;
    close $fh;
    chomp $pid;
    is( $pid, $$, 'the lock file still names our own PID' );
}

done_testing();
