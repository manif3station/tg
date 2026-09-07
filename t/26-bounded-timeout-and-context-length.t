use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Telegram;
require D2TG::Poller;
require Fake::Telegram;

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
    my $tg = D2TG::Telegram->new( token => 'test-token' );
    ok( $tg->{ua}->isa('LWP::UserAgent'), 'default ua is an LWP::UserAgent' );
    ok( defined $tg->{ua}->timeout, 'default ua has an explicit timeout set' );
    cmp_ok( $tg->{ua}->timeout, '<=', 60, "default ua's timeout is bounded to a short value, not LWP's 180s default" );
}

{
    my $long_original = 'x' x 300;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 70,
                message   => {
                    chat              => { id => 999 },
                    from              => { username => 'ada' },
                    text              => 'ok',
                    reply_to_message  => { from => { username => 'bob' }, text => $long_original },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    my ($snippet) = $out =~ /replying to bob: (.*?)\)/;
    is( $snippet, $long_original, 'a 300-char original message is quoted in full, not truncated at the old 60-char limit' );
}

{
    my $huge_original = 'y' x 6000;

    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 71,
                message   => {
                    chat             => { id => 999 },
                    from             => { username => 'ada' },
                    text             => 'ok',
                    reply_to_message => { from => { username => 'bob' }, text => $huge_original },
                },
            },
        ],
    );

    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef ) } );

    like( $out, qr/replying to bob: y{5000}\.\.\./, 'an original message beyond 5000 chars is still truncated with an ellipsis' );
}

done_testing();
