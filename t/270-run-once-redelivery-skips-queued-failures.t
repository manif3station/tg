use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

# TGT-270 (a live report from Michael via the budget project, filed as
# /tmp/ask-for-more-from-d2tg/20260916T194918-budget-oldmessage-replay.md):
# a poller version-change restart re-emitted a stale MEDIA DOWNLOAD
# ERROR that read exactly like a fresh live failure, for a message that
# had actually already failed and been queued days earlier.
#
# Root cause: run_once's redelivery-dedup guard only checks
# D2TG::Store::get_message (the "messages" table) before re-announcing
# a redelivered update. A media-download failure never calls
# record_message - only record_failed_download, a DIFFERENT table -
# so the guard has no way to recognize an already-queued failure and
# legitimately re-processes it as brand new whenever Telegram
# redelivers that update_id (its own documented at-least-once
# delivery - record_failed_download's own TGT-219 comment already
# acknowledges this: "Telegram's own at-least-once delivery can still
# reprocess the same update under the SAME bot").

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
                message   => { message_id => 300, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-redelivered' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );

    # Simulate: this exact update already failed and was queued on an
    # earlier cycle (days ago, per the live report).
    $store->record_failed_download( 999, 300, 'doc-redelivered', sender => 'ada', media_kind => 'document', caption_note => '', error => 'earlier failure' );

    # A download attempt this cycle would succeed if it were even
    # tried - proves the guard skips it BEFORE reaching the download
    # call at all, not because the download itself failed again.
    my $download_attempted = 0;
    my $download_media = sub { $download_attempted = 1; return '/tmp/would-succeed.bin' };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    ok( !$download_attempted, 'a redelivered update already queued as a failed download is never re-attempted' );
    unlike( $out, qr/NEW TG MEDIA/, 'no NEW TG MEDIA / NEW TG MEDIA FAILED line is printed for a redelivered already-queued update' );
    unlike( $err, qr/MEDIA DOWNLOAD ERROR/, 'no fresh-looking MEDIA DOWNLOAD ERROR line is printed for a redelivered already-queued update' );

    my $queue = $store->failed_downloads;
    is( scalar @$queue, 1, 'still exactly one queued row - not duplicated by the redelivery' );
}

# Regression: a genuinely NEW media failure (never queued before) must
# still be announced and queued exactly as before.
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 501,
                message   => { message_id => 301, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-genuinely-new' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "HTTP request failed (status 500)\n" };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $err, qr/MEDIA DOWNLOAD ERROR \[999\] ada/, 'a genuinely new failure is still reported to STDERR' );
    like( $out, qr/NEW TG MEDIA FAILED \[999\] ada/, 'a genuinely new failure still produces the visible STDOUT event' );

    my $queue = $store->failed_downloads;
    is( scalar @$queue, 1, 'the new failure was genuinely queued' );
}

# The same redelivery-dedup gap, for a voice message whose
# transcription already failed and was queued.
{
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 502,
                message   => { message_id => 302, chat => { id => 999 }, from => { username => 'ada' }, voice => { file_id => 'voice-redelivered' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    $store->record_failed_transcription( 999, 302, 'voice-redelivered', sender => 'ada', error => 'earlier transcription failure' );

    my $transcribe_attempted = 0;
    my $transcribe_voice = sub { $transcribe_attempted = 1; return 'would succeed now'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    ok( !$transcribe_attempted, 'a redelivered update already queued as a failed transcription is never re-attempted' );
    unlike( $out, qr/NEW TG VOICE/, 'no NEW TG VOICE line is printed for a redelivered already-queued voice update' );

    my $queue = $store->failed_transcriptions;
    is( scalar @$queue, 1, 'still exactly one queued transcription row - not duplicated by the redelivery' );
}

done_testing();
