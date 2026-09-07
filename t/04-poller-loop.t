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

package main;

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 55,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, text => 'hello there' },
            },
        ],
    );

    my $out;
    my $next_offset;
    $out = capture_stdout( sub {
        ( undef, $next_offset ) = D2TG::Poller::run_once( $tg, undef );
    } );

    like( $out, qr/999/,          'stdout names the chat id' );
    like( $out, qr/ada/,          'stdout names the sender' );
    like( $out, qr/hello there/,  'stdout carries the message text' );
    is( ( split /\n/, $out ), 1,  'exactly one line was printed for one message' );
    is( $next_offset, 56,         'offset advances past the processed update' );
}

{
    my $tg = Fake::Telegram->new( [] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, 10 );
    } );

    is( $out, '', 'no output when there are no updates' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 60,
                message   => { chat => { id => 1 }, from => { username => 'eve' }, text => "line one\nline two" },
            },
        ],
    );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef );
    } );

    is( ( split /\n/, $out ), 1,
        'a message containing a newline still produces exactly one stdout line' );
    like( $out, qr/line one.*line two/,
        'the embedded newline is escaped/replaced rather than splitting the line' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 1,
                message   => { chat => { id => 1 }, from => { username => 'x' } },   # no text - e.g. a sticker
            },
        ],
    );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef );
    } );

    is( $out, '', 'a non-text update produces no stdout line in this ticket\'s scope' );
}

done_testing();
