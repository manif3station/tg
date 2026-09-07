use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Poller;

package Fake::Telegram;

sub new {
    my ( $class, @updates_batches ) = @_;
    return bless { batches => [@updates_batches] }, $class;
}

sub get_updates {
    my ( $self, %args ) = @_;
    my $batch = shift @{ $self->{batches} } || [];

    my $next_offset = $args{offset};
    for my $u (@$batch) {
        my $candidate = $u->{update_id} + 1;
        $next_offset = $candidate
          if !defined $next_offset || $candidate > $next_offset;
    }
    return ( $batch, $next_offset );
}

package Fake::Store;

sub new {
    my ( $class, %args ) = @_;
    return bless { allowed => { map { $_ => 1 } @{ $args{allowed} || [] } } }, $class;
}

sub is_allowed { my ( $self, $id ) = @_; return $self->{allowed}{$id} ? 1 : 0 }
sub add_pending { return 1; }

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    open my $err_fh, '>', \$err or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 200,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'ghi' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $transcribe_voice = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return 'hello there'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    is_deeply( \@calls, ['ghi'], 'transcribe_voice was called with the voice message file_id' );
    like( $out, qr/999/,          'stdout names the chat id' );
    like( $out, qr/hello there/,  'stdout carries the transcribed text' );
    is( $err, '', 'nothing is printed to stderr on success' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 201,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'jkl' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { die "whisper unavailable\n"; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    unlike( $out, qr/hello/, 'no transcript line appears on stdout when transcription fails' );
    like( $err, qr/whisper unavailable/, 'the failure is reported on stderr' );
    like( $err, qr/999/, 'the stderr line names the chat id' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 202,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'mno' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store );    # no transcribe_voice given
    } );

    like( $out, qr/voice/i, 'without transcribe_voice, the old MEDIA-line behavior is unchanged' );
}

done_testing();
