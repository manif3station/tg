use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use POSIX qw(strftime);

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

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

my $known_date = 1_700_000_000;    # a fixed, known Unix epoch second
my $expected_ts = strftime( '%Y-%m-%d %H:%M:%S', localtime($known_date) );

# --- text message: timestamp sourced from Telegram's own message.date ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 700,
                message   => {
                    message_id => 1,
                    date       => $known_date,
                    chat       => { id => 111 },
                    from       => { username => 'ada' },
                    text       => 'hello',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [111] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/^\Q[$expected_ts]\E NEW TG \[111\] ada: hello/m,
        'NEW TG line is prefixed with a timestamp matching message.date exactly' );
}

# --- voice message ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 701,
                message   => {
                    message_id => 2,
                    date       => $known_date,
                    chat       => { id => 222 },
                    from       => { username => 'bob' },
                    voice      => { file_id => 'voicefile' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [222] );
    my $transcribe_voice = sub { return 'a transcript' };
    my $out = capture_stdout(
        sub { D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice ) } );

    like( $out, qr/^\Q[$expected_ts]\E NEW TG VOICE \[222\] bob: a transcript/m,
        'NEW TG VOICE line is prefixed with a timestamp matching message.date' );
}

# --- media message (no download_media coderef given: plain fallback line) ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 702,
                message   => {
                    message_id => 3,
                    date       => $known_date,
                    chat       => { id => 333 },
                    from       => { username => 'carl' },
                    document   => { file_id => 'docfile' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [333] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/^\Q[$expected_ts]\E NEW TG MEDIA \[333\] carl: document/m,
        'NEW TG MEDIA line is prefixed with a timestamp matching message.date' );
}

# --- pending notification ---
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 703,
                message   => {
                    message_id => 4,
                    date       => $known_date,
                    chat       => { id => 444 },
                    from       => { username => 'dan' },
                    text       => 'hi',
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [] );
    my $out = capture_stdout( sub { D2TG::Poller::run_once( $tg, undef, $store ) } );

    like( $out, qr/^\Q[$expected_ts]\E NEW TG PENDING \[444\] awaiting approval/m,
        'NEW TG PENDING line is prefixed with a timestamp matching message.date' );
}

done_testing();
