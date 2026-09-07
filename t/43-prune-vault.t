use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Download;

sub write_file {
    my ( $dir, $name, $size, $mtime ) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die $!;
    print {$fh} 'x' x $size;
    close $fh;
    utime $mtime, $mtime, $path or die "utime failed: $!";
    return $path;
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $now = time();

    # Three files, 40 bytes each (120 bytes total), oldest to newest.
    write_file( $dir, 'oldest.dat', 40, $now - 300 );
    write_file( $dir, 'middle.dat', 40, $now - 200 );
    write_file( $dir, 'newest.dat', 40, $now - 100 );

    D2TG::Download::prune_vault( $dir, max_bytes => 80 );

    ok( !-e "$dir/oldest.dat", 'the oldest file is deleted once the vault exceeds the cap' );
    ok( -e "$dir/middle.dat", 'the middle file survives' );
    ok( -e "$dir/newest.dat", 'the newest file survives' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $now = time();

    write_file( $dir, 'a.dat', 40, $now - 300 );
    write_file( $dir, 'b.dat', 40, $now - 200 );
    write_file( $dir, 'c.dat', 40, $now - 100 );

    D2TG::Download::prune_vault( $dir, max_bytes => 1000 );

    ok( -e "$dir/a.dat", 'nothing is deleted when the vault is already under the cap (oldest survives)' );
    ok( -e "$dir/b.dat", 'nothing is deleted when the vault is already under the cap (middle survives)' );
    ok( -e "$dir/c.dat", 'nothing is deleted when the vault is already under the cap (newest survives)' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $now = time();

    write_file( $dir, 'a.dat', 40, $now - 300 );
    write_file( $dir, 'b.dat', 40, $now - 200 );
    write_file( $dir, 'c.dat', 40, $now - 100 );

    D2TG::Download::prune_vault( $dir, max_bytes => 50 );

    ok( !-e "$dir/a.dat", 'oldest deleted when pruning down to a small cap' );
    ok( !-e "$dir/b.dat", 'middle also deleted when still over the cap after removing the oldest' );
    ok( -e "$dir/c.dat", 'newest survives even when pruning down to a cap smaller than one file' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    eval { D2TG::Download::prune_vault( $dir, max_bytes => 100 ) };
    is( $@, '', 'prune_vault on an empty directory does not die' );
}

done_testing();
