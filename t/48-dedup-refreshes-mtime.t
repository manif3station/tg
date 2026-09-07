use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HTTP::Response;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);

require D2TG::Download;

package Fake::Telegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { file_path => $args{file_path} }, $class;
}

sub get_file {
    my ( $self, $file_id ) = @_;
    return $self->{file_path};
}

sub file_download_url {
    my ( $self, $file_path ) = @_;
    return "https://api.telegram.org/file/bottest-token/$file_path";
}

package Fake::UA;

sub new {
    my ( $class, %args ) = @_;
    return bless { responses => $args{responses} || [] }, $class;
}

sub get {
    my ($self) = @_;
    return shift @{ $self->{responses} };
}

package main;

{
    # A dedup hit (re-download of content already present in the vault)
    # must refresh the existing file's mtime, not leave it frozen at its
    # original download time - otherwise prune_vault's oldest-mtime-first
    # eviction treats a frequently re-sent, still-wanted file as stale.
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::Telegram->new( file_path => 'photo/popular.jpg' );
    my $content  = 'popular content, re-sent many times';
    my $r1       = HTTP::Response->new( 200, 'OK' );
    $r1->content($content);
    my $r2 = HTTP::Response->new( 200, 'OK' );
    $r2->content($content);
    my $ua = Fake::UA->new( responses => [ $r1, $r2 ] );

    my $path = D2TG::Download::download_file( $telegram, 'AABB1', ua => $ua, dir => $dir );

    my $old_time = time() - 100_000;
    utime $old_time, $old_time, $path or die "utime failed: $!";

    D2TG::Download::download_file( $telegram, 'AABB2', ua => $ua, dir => $dir );

    my $mtime_after = ( stat $path )[9];
    cmp_ok( $mtime_after, '>', $old_time,
        'a dedup hit refreshes the existing file\'s mtime instead of leaving it frozen' );
}

{
    # End-to-end: a repeatedly re-sent (deduped) old file must survive
    # prune_vault ahead of a truly stale file that was only ever
    # downloaded once, even though the stale file's original download
    # happened more recently in wall-clock time.
    my $dir = tempdir( CLEANUP => 1 );

    my $popular_telegram = Fake::Telegram->new( file_path => 'popular.dat' );
    my $popular_content  = 'x' x 40;
    my $pr1 = HTTP::Response->new( 200, 'OK' );
    $pr1->content($popular_content);
    my $pr2 = HTTP::Response->new( 200, 'OK' );
    $pr2->content($popular_content);
    my $popular_ua = Fake::UA->new( responses => [ $pr1, $pr2 ] );

    my $popular_path = D2TG::Download::download_file(
        $popular_telegram, 'POP1', ua => $popular_ua, dir => $dir );

    my $very_old = time() - 100_000;
    utime $very_old, $very_old, $popular_path or die "utime failed: $!";

    my $stale_telegram = Fake::Telegram->new( file_path => 'stale.dat' );
    my $stale_content  = 'y' x 40;
    my $sr1 = HTTP::Response->new( 200, 'OK' );
    $sr1->content($stale_content);
    my $stale_ua = Fake::UA->new( responses => [$sr1] );

    my $stale_path = D2TG::Download::download_file(
        $stale_telegram, 'STALE1', ua => $stale_ua, dir => $dir );

    my $less_old = time() - 50_000;
    utime $less_old, $less_old, $stale_path or die "utime failed: $!";

    # Re-send the popular file (dedup hit) - this should count as fresh
    # use and refresh its mtime past the stale file's.
    D2TG::Download::download_file(
        $popular_telegram, 'POP2', ua => $popular_ua, dir => $dir );

    D2TG::Download::prune_vault( $dir, max_bytes => 40 );

    ok( -e $popular_path, 'the repeatedly re-sent (deduped) file survives pruning' );
    ok( !-e $stale_path, 'the truly stale, never-repeated file is pruned instead' );
}

done_testing();
