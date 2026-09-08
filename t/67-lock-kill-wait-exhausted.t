use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

# TGT-084: if a target process refuses to die within the bounded wait
# after SIGKILL (kill(0,$pid) still true once _KILL_WAIT_RETRIES is
# exhausted), acquire() must die with a clear message naming the PID,
# rather than looping forever or silently reclaiming the lock out from
# under a process that's actually still alive.
#
# A real, genuinely unkillable process can't be constructed for a test
# (SIGKILL cannot be blocked or ignored), so CORE::GLOBAL::kill is
# stubbed - installed via BEGIN, before D2TG::Lock is required, so
# D2TG::Lock.pm's own unqualified kill(...) calls compile against this
# override - to always report the target as alive, deterministically
# exercising the "did not die" branch without any real process at all.
BEGIN {
    *CORE::GLOBAL::kill = sub { return 1; };
}

require D2TG::Lock;

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    open my $fh, '>', $lock or die $!;
    print {$fh} "424242\n";
    close $fh;

    eval { D2TG::Lock::acquire($lock) };

    like( $@, qr/PID 424242 did not die after SIGKILL/,
        'acquire() dies with a clear message when the target refuses to die within the bounded wait (TGT-084)' );
    like( $@, qr/\Q$lock\E/, 'the message names the lock path being contended for' );
}

done_testing();
