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
    return bless { responses => $args{responses} || [], calls => [] }, $class;
}

sub get {
    my ($self) = @_;
    push @{ $self->{calls} }, 1;
    return shift @{ $self->{responses} };
}

package main;

{
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::Telegram->new( file_path => 'photo/file_1.jpg' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('identical bytes');
    my $ua = Fake::UA->new( responses => [ $response, $response ] );

    my $path1 = D2TG::Download::download_file( $telegram, 'AABB1', ua => $ua, dir => $dir );
    my $path2 = D2TG::Download::download_file( $telegram, 'AABB2', ua => $ua, dir => $dir );

    is( $path1, $path2, 'two downloads of identical content resolve to the exact same local path (dedup)' );

    my $expected_hash = sha256_hex('identical bytes');
    like( $path1, qr/\Q$expected_hash\E\.jpg$/, 'the filename is the content\'s SHA256 hash, with the original extension preserved' );

    opendir my $dh, $dir or die $!;
    my @files = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
    is( scalar @files, 1, 'only one copy of the identical content exists on disk, not two' );
}

{
    my $dir      = tempdir( CLEANUP => 1 );
    my $telegram = Fake::Telegram->new( file_path => 'photo/file_2.jpg' );
    my $r1       = HTTP::Response->new( 200, 'OK' );
    $r1->content('first content');
    my $r2 = HTTP::Response->new( 200, 'OK' );
    $r2->content('second, different content');
    my $ua = Fake::UA->new( responses => [ $r1, $r2 ] );

    my $path1 = D2TG::Download::download_file( $telegram, 'AABB3', ua => $ua, dir => $dir );
    my $path2 = D2TG::Download::download_file( $telegram, 'AABB4', ua => $ua, dir => $dir );

    isnt( $path1, $path2, 'two downloads of DIFFERENT content get different (non-colliding) local paths' );
}

{
    # No dir given at all (unchanged behavior) - still works, defaults to OS tmpdir.
    my $telegram = Fake::Telegram->new( file_path => 'voice/file_3.oga' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('no dir given');
    my $ua = Fake::UA->new( responses => [$response] );

    my $local_path = D2TG::Download::download_file( $telegram, 'AABB5', ua => $ua );

    ok( -e $local_path, 'without an explicit dir, download_file still works (falls back to the OS tmpdir)' );
    unlink $local_path;
}

done_testing();
