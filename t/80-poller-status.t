use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Lock;

# TGT-111 (user-supplied feature-gap analysis, /tmp/missing2.md item 5):
# the only way to know the poller is actually alive was to reach into
# Tira job metadata from outside. D2TG::Lock::is_held is a read-only
# liveness check - it must NEVER call acquire() (which would try to
# evict a live poller per TGT-084's own "last one wins" policy just to
# ANSWER a status question, a real danger this ticket must avoid).

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    is( D2TG::Lock::is_held($lock), undef, 'is_held returns undef when no lock file exists at all' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    open my $fh, '>', $lock or die $!;
    print {$fh} "$$\n";
    close $fh;

    is( D2TG::Lock::is_held($lock), $$, 'is_held returns the PID when the lock names a live process (our own, for this test)' );
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    # A PID essentially guaranteed not to exist.
    my $dead_pid = 999_999;
    open my $fh, '>', $lock or die $!;
    print {$fh} "$dead_pid\n";
    close $fh;

    is( D2TG::Lock::is_held($lock), undef, 'is_held returns undef when the lock names a dead PID' );
}

{
    # The critical safety property: is_held must never touch the lock
    # file at all - no unlink, no recreate, no kill signal beyond the
    # harmless kill(0,...) liveness probe.
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    open my $fh, '>', $lock or die $!;
    print {$fh} "$$\n";
    close $fh;

    my @stat_before = stat($lock);
    D2TG::Lock::is_held($lock);
    my @stat_after = stat($lock);

    is( $stat_after[1], $stat_before[1], 'is_held never touches the lock file - same inode before and after' );
    ok( kill( 0, $$ ), 'is_held never sent a real signal to the live PID either - this process is still very much alive' );
}

# CLI-level: d2 tg.status reports alive/not-running correctly.
{
    my $status_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'status.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my $lock_path = File::Spec->catfile( $fake_db_dir, '.tira', 'telegram.pid' );

    {
        my $out = `$status_cli`;
        my $rc  = $? >> 8;
        is( $rc, 0, 'd2 tg.status exits 0 when the poller is not running' );
        like( $out, qr/not running/i, 'd2 tg.status reports not running when no lock file exists' );
    }

    {
        mkdir File::Spec->catdir( $fake_db_dir, '.tira' );
        open my $fh, '>', $lock_path or die $!;
        print {$fh} "$$\n";
        close $fh;

        my $out = `$status_cli`;
        my $rc  = $? >> 8;
        is( $rc, 0, 'd2 tg.status exits 0 when the poller is running' );
        like( $out, qr/running/i, 'd2 tg.status reports the poller as alive' );
        like( $out, qr/\Q$$\E/, "d2 tg.status names the live PID ($$)" );

        unlink $lock_path;
    }
}

done_testing();
