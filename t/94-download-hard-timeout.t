use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);

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

package Fake::HangingUA;

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

sub get {
    my ( $self, $url ) = @_;

    # Simulates a connection that never returns - the exact failure
    # class TGT-126 targets (D2TG::Telegram's own _with_hard_timeout
    # exists to guard against precisely this on the sibling call path).
    sleep 30;
    die "Fake::HangingUA::get: should never reach here\n";
}

package main;

{
    my $telegram = Fake::Telegram->new( file_path => 'voice/hang.oga' );
    my $ua = Fake::HangingUA->new;

    my $started = time();
    eval { D2TG::Download::download_file( $telegram, 'AABB999', ua => $ua, timeout => 1 ) };
    my $error   = $@;
    my $elapsed = time() - $started;

    ok( $error, 'download_file died rather than hanging forever' );
    like( $error, qr/timed out/i, 'the error names a timeout, not a generic failure' );
    ok( $elapsed < 5, "died within the bounded timeout window, not after the fake's own 30s sleep (elapsed=${elapsed}s)" );
}

done_testing();
