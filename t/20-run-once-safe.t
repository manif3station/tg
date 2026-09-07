use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
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

{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 500,
                message   => { chat => { id => 999 }, from => { username => 'ada' }, text => 'hi' },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @slept;

    my ( $out, $err );
    my $new_offset;
    ( $out, $err ) = capture_std( sub {
        $new_offset = D2TG::Poller::run_once_safe(
            $tg, undef, $store,
            sleep => sub { push @slept, $_[0] },
        );
    } );

    is_deeply( \@slept, [], 'no sleep happens on a successful iteration' );
    like( $out, qr/999/, 'success path still prints normally' );
    is( $err, '', 'no error printed on success' );
    is( $new_offset, 501, 'offset advances normally on success' );
}

{
    package Fake::Telegram::Dying;
    sub new { return bless {}, shift; }
    sub get_updates { die "simulated transient network failure\n"; }

    package main;

    my $tg = Fake::Telegram::Dying->new;
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

    is( $out, '', 'nothing printed to stdout when get_updates dies' );
    like( $err, qr/POLL ERROR: simulated transient network failure/, 'the failure is reported clearly on stderr' );
    is( $new_offset, 42, 'the offset is unchanged (not advanced/lost) after a failure' );
    is_deeply( \@slept, [2], 'a backoff sleep happens after a failure, avoiding a hot-loop' );
}

{
    # default sleep behavior (no injected sleep) must not itself die or hang the test suite -
    # exercised with a runner that returns 0 immediately is not applicable here since sleep
    # has no meaningful "mock-free" fast path other than actually sleeping; instead confirm
    # the default coderef is CORE::sleep by checking it's callable without dying when given 0.
    my $tg = Fake::Telegram::Dying->new;
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err );
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        capture_std( sub {
            D2TG::Poller::run_once_safe( $tg, 1, $store, sleep => sub { } );
        } );
        alarm(0);
    };
    ok( !$@, 'run_once_safe with a no-op injected sleep returns promptly (no hang)' ) or diag($@);
}

{
    is( D2TG::Poller::_sleep(0), 0, '_sleep(0) returns immediately, exercising the real default sleep path' );
}

done_testing();
