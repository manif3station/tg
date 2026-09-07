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
    # Defense in depth: strip other control/escape characters too, not just
    # newlines - an ANSI escape sequence in inbound text could otherwise
    # manipulate a terminal displaying this stream directly.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 61,
                message   => {
                    chat => { id => 1 },
                    from => { username => 'mallory' },
                    text => "hello\e[31mRED\e[0mworld\x07",
                },
            },
        ],
    );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef );
    } );

    unlike( $out, qr/\e/, 'ESC control characters are stripped from message text before printing' );
    unlike( $out, qr/\x07/, 'other non-printable control characters are stripped too' );
    like( $out, qr/hello.*RED.*world/, 'the printable content survives the sanitization' );
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

{
    # Channel posts and anonymous admins carry no 'from' at all.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 70,
                message   => { chat => { id => 2 }, text => 'no sender here' },
            },
        ],
    );

    my $out;
    eval {
        $out = capture_stdout( sub {
            D2TG::Poller::run_once( $tg, undef );
        } );
    };

    is( $@, '', 'a message with no from field does not crash the poller' );
    like( $out, qr/unknown/, 'a missing sender is reported as unknown rather than dying' );
}

{
    package Undef::Telegram;
    sub new { return bless {}, shift }
    sub get_updates { return ( undef, 99 ) }
}

{
    my $tg = Undef::Telegram->new;

    my $out;
    eval {
        $out = capture_stdout( sub {
            D2TG::Poller::run_once( $tg, undef );
        } );
    };

    is( $@, '', 'a get_updates implementation returning undef instead of an arrayref does not crash' );
}

package Fake::Store;

sub new {
    my ( $class, %args ) = @_;
    return bless { allowed => { map { $_ => 1 } @{ $args{allowed} || [] } }, pending => [] }, $class;
}

sub is_allowed { my ( $self, $id ) = @_; return $self->{allowed}{$id} ? 1 : 0 }

sub add_pending {
    my ( $self, $id ) = @_;
    my $already = grep { $_ == $id } @{ $self->{pending} };
    push @{ $self->{pending} }, $id;
    return $already ? 0 : 1;
}

package main;

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 80,
                message   => { chat => { id => 999 }, from => { username => 'admin' }, text => 'allowed message' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    like( $out, qr/allowed message/, 'a message from an allow-listed chat id reaches stdout' );
    is_deeply( $store->{pending}, [], 'nothing was recorded pending for an allowed sender' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 81,
                message   => { chat => { id => 111 }, from => { username => 'stranger' }, text => 'let me in' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    unlike( $out, qr/let me in/, 'the message TEXT from a non-allow-listed sender never reaches stdout' );
    like( $out, qr/111/, 'but a pending-notification line does appear, naming the chat id (TGT-010)' );
    is_deeply( $store->{pending}, [111], 'the non-allow-listed chat id was recorded pending' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 90,
                message   => { chat => { id => 222 }, from => { username => 'newperson' }, text => 'hi there' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    like( $out, qr/222/, 'a genuinely new pending sender produces a pending-notification line naming the chat id' );
}

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 91,
                message   => { chat => { id => 333 }, from => { username => 'again' }, text => 'still waiting' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    $store->add_pending(333);    # already pending before this message arrives

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store );
    } );

    is( $out, '', 'a message from an already-pending sender produces no further notification' );
}

{
    # Backward compatibility: no store given at all means no gate (TGT-005's
    # own tests, above, rely on this - the gate is opt-in via the 3rd arg).
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 82,
                message   => { chat => { id => 5 }, from => { username => 'x' }, text => 'no gate here' },
            },
        ],
    );

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef );
    } );

    like( $out, qr/no gate here/, 'omitting the store argument entirely skips the access-control gate' );
}

done_testing();
