use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HTTP::Response;

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
    return bless { response => $args{response}, calls => [] }, $class;
}

sub get {
    my ( $self, $url ) = @_;
    push @{ $self->{calls} }, $url;
    return $self->{response};
}

package main;

{
    my $telegram = Fake::Telegram->new( file_path => 'voice/file_1.oga' );
    my $response = HTTP::Response->new( 200, 'OK' );
    $response->content('fake audio bytes');
    my $ua = Fake::UA->new( response => $response );

    my $local_path = D2TG::Download::download_file( $telegram, 'AABB123', ua => $ua );

    is( scalar @{ $ua->{calls} }, 1, 'exactly one HTTP GET was made' );
    is( $ua->{calls}[0], 'https://api.telegram.org/file/bottest-token/voice/file_1.oga', 'fetched the correct file URL' );
    like( $local_path, qr/\.oga$/, 'the local path preserves the original file extension' );

    open my $fh, '<', $local_path or die $!;
    local $/;
    is( <$fh>, 'fake audio bytes', 'the downloaded bytes were written to the local file' );
    close $fh;

    unlink $local_path;
}

{
    my $telegram = Fake::Telegram->new( file_path => undef );
    my $ua = Fake::UA->new;

    eval { D2TG::Download::download_file( $telegram, 'missing', ua => $ua ) };
    like( $@, qr/no file_path/, 'download_file dies clearly when Telegram has no file_path for this file_id' );
}

{
    my $telegram = Fake::Telegram->new( file_path => 'voice/file_2.oga' );
    my $response = HTTP::Response->new( 404, 'Not Found' );
    my $ua = Fake::UA->new( response => $response );

    eval { D2TG::Download::download_file( $telegram, 'AABB456', ua => $ua ) };
    like( $@, qr/404/, 'download_file dies naming the HTTP status on transport failure' );
}

done_testing();
