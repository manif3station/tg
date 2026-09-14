use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require D2TG::Config;
require Fake::Telegram;
require Fake::Store;

package main;

# TGT-220 (found via a scheduled JOB-003 hourly bug hunt): the NEW TG
# MEDIA FAILED line's own RETRY WITH hint is a hard-coded literal with
# no --bot flag, even though $bot_token is already in scope at that
# print site (threaded into record_failed_download's own bot_key
# argument two lines earlier, per TGT-219). In a multi-bot config,
# following the printed command literally for a non-default-bot
# failure retries nothing, since cli/retry-download.pl's own --all
# with no --bot only acts on the default-bot sentinel queue. This test
# proves the fix: the RETRY WITH line now carries a masked --bot flag
# whenever $bot_token is defined, matching _print_reply_template's own
# already-established convention exactly.

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
    # Multi-bot case: bot_token is defined, so RETRY WITH must include
    # a masked --bot flag.
    my $bot_token = '123456:ABC-DEF-multi-bot-token';
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 500,
                message   => { message_id => 300, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-fail-multi' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "HTTP request failed (status 500)\n" };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media, bot_token => $bot_token );
    } );

    my $masked = D2TG::Config::masked_token($bot_token);
    like(
        $out,
        qr/RETRY WITH: d2 tg\.retry-download --all --bot \Q$masked\E/,
        'a multi-bot media-download failure prints RETRY WITH with a masked --bot flag'
    );
    unlike( $out, qr/\Q$bot_token\E/, 'the raw token is never printed, only the masked form' );
}

{
    # Regression: single-bot mode (no bot_token) must be unchanged
    # from today - matches t/204's own existing case exactly.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 501,
                message   => { message_id => 301, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-fail-single' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "HTTP request failed (status 500)\n" };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $out, qr/RETRY WITH: d2 tg\.retry-download --all\n/, 'single-bot mode keeps the plain RETRY WITH line, no --bot flag' );
}

done_testing();
