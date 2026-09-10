use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Store;

package main;

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

# TGT-097 (live user request via Telegram): a known-transient poll
# failure (timeout / 5xx) should not print a POLL ERROR line at all -
# the retry loop already recovers on its own, and the repeated line was
# pure noise reaching the project's tira.policy.bridge. A genuinely
# unexpected/non-transient failure must still be reported.

{
    package Fake::Telegram::TimedOut;
    sub new { return bless {}, shift; }
    sub get_updates { die "D2TG::Telegram getUpdates: HTTP request failed (status 500 D2TG::Telegram getUpdates: request timed out after 50s)\n"; }

    package main;

    my $tg    = Fake::Telegram::TimedOut->new;
    my $store = Fake::Store->new( allowed => [999] );
    my @slept;

    my ( $out, $err );
    my $new_offset;
    ( $out, $err ) = capture_std( sub {
        $new_offset = D2TG::Poller::run_once_safe(
            $tg, 42, $store,
            sleep => sub { push @slept, $_[0] },
        );
    } );

    is( $out, '', 'nothing printed to stdout for a transient timeout' );
    is( $err, '', 'nothing printed to stderr for a transient timeout - silenced (TGT-097)' );
    is( $new_offset, 42, 'the offset is still unchanged (retry, not advance) after a silenced transient failure' );
    is_deeply( \@slept, [2], 'the retry/backoff sleep still happens even when the error is silenced' );
}

{
    package Fake::Telegram::BadGateway;
    sub new { return bless {}, shift; }
    sub get_updates { die "D2TG::Telegram getUpdates: HTTP request failed (status 502 Bad Gateway)\n"; }

    package main;

    my $tg    = Fake::Telegram::BadGateway->new;
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once_safe( $tg, 42, $store, sleep => sub { } );
    } );

    is( $err, '', 'nothing printed to stderr for a transient 502 either' );
}

{
    # TGT-160 (found via a scheduled hourly bug hunt): Telegram's own
    # Bot API documents 429 ("Too Many Requests") as a designed,
    # expected rate-limit signal, not an application error - it was
    # previously misclassified as non-transient (is_transient_error
    # only matched /timed out/i or /status 5\d\d/, never 429), so a
    # routine flood-control response got logged loudly as a genuine
    # POLL ERROR every time, adding noise to the monitored
    # tira.policy.bridge stream for something that isn't actually wrong.
    package Fake::Telegram::TooManyRequests;
    sub new { return bless {}, shift; }
    sub get_updates { die "D2TG::Telegram getUpdates: HTTP request failed (status 429 Too Many Requests)\n"; }

    package main;

    my $tg    = Fake::Telegram::TooManyRequests->new;
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once_safe( $tg, 42, $store, sleep => sub { } );
    } );

    is( $err, '', 'nothing printed to stderr for a transient 429 (rate-limit) either' );
}

{
    package Fake::Telegram::Malformed;
    sub new { return bless {}, shift; }
    sub get_updates { die "D2TG::Telegram getUpdates: response was not valid JSON\n"; }

    package main;

    my $tg    = Fake::Telegram::Malformed->new;
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once_safe( $tg, 42, $store, sleep => sub { } );
    } );

    like( $err, qr/POLL ERROR: D2TG::Telegram getUpdates: response was not valid JSON/,
        'a non-transient failure (malformed response) still prints POLL ERROR as before' );
}

done_testing();
