use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;
use File::Glob qw(bsd_glob);

require D2TG::Config;

# TGT-139 (self-review while completing TGT-138's pending-push gate):
# write_heartbeat's atomic-write fix (TGT-116) writes to $path.tmp.$$
# then rename()s over the real path, but never unlinks the staging file
# if rename() itself fails - a failed write leaves debris in the state
# directory, and every failed attempt (e.g. a persistently read-only
# target directory) adds another orphaned $path.tmp.$$ file.

{
    # Codex review findings: (1) the injected failing renamer must set
    # $! to a known value so the die message can be checked to still
    # carry it after the unlink cleanup (unlink itself can clobber $!);
    # (2) the renamer must observe the staging file actually existing
    # when it's called, proving this test exercises the real
    # after-rename-fails cleanup path, not a no-op.
    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $path    = File::Spec->catfile( $tempdir, 'heartbeat' );

    my $staging_existed_during_rename;
    my $failing_renamer = sub {
        my ($tmp_path) = @_;
        $staging_existed_during_rename = -e $tmp_path;
        $! = 13;    # EACCES, a stable/known errno for the die message
        return 0;
    };

    eval {
        D2TG::Config::write_heartbeat( $path, renamer => $failing_renamer );
    };
    like( $@, qr/cannot rename/, 'write_heartbeat dies when rename() fails' );
    like( $@, qr/Permission denied/,
        '$! survives the unlink cleanup and still reaches the die message' );

    ok( $staging_existed_during_rename,
        'the staging temp file genuinely existed when the (failing) renamer was called' );

    my @leftover = bsd_glob("$tempdir/*.tmp.*");
    is( scalar(@leftover), 0,
        'no staging temp file is left behind after a rename() failure' );
}

{
    # The normal (real rename) path is unchanged - the file lands at
    # the real path and no staging file is left behind either.
    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $path    = File::Spec->catfile( $tempdir, 'heartbeat' );

    D2TG::Config::write_heartbeat($path);

    ok( -e $path, 'write_heartbeat still writes the real path on success' );

    my @leftover = bsd_glob("$tempdir/*.tmp.*");
    is( scalar(@leftover), 0,
        'no staging temp file is left behind after a successful write either' );
}

done_testing();
