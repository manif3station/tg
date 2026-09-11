use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

package main;

# TGT-204 (a real, live-reported incident from the budget project's own
# agent): a media download that fails and gets queued via
# record_failed_download produced NO stdout signal at all - only a
# STDERR "MEDIA DOWNLOAD ERROR" line, which never reaches the monitor
# job's own stdout-fed tira.policy.bridge notification stream. 4 real
# photo messages sat silently queued for over an hour before the owner
# noticed by asking directly. This test proves the fix: a queued
# failure now also prints a visible STDOUT event naming the recovery
# command, matching NEW TG MEDIA's own visibility.

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
                update_id => 400,
                message   => { message_id => 200, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-fail' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { die "HTTP request failed (status 500)\n" };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $err, qr/MEDIA DOWNLOAD ERROR \[999\] ada/, 'the existing STDERR error line is still printed (unchanged)' );

    like(
        $out,
        qr/NEW TG MEDIA FAILED \[999\] ada:.*queued for retry/i,
        'a queued failed download now also produces a visible STDOUT event'
    );
    like(
        $out,
        qr/RETRY WITH: d2 tg\.retry-download --all/,
        'the STDOUT event names the exact recovery command'
    );

    my $queue = $store->failed_downloads;
    is( scalar @$queue, 1, 'the download was genuinely queued (sanity check, not just a printed claim)' );
}

{
    # Regression: a SUCCESSFUL media download's own existing NEW TG
    # MEDIA line and behavior must be completely unaffected.
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 401,
                message   => { message_id => 201, chat => { id => 999 }, from => { username => 'ada' }, document => { file_id => 'doc-ok' } },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $download_media = sub { return '/tmp/doc-ok.bin' };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    like( $out, qr/NEW TG MEDIA \[999\] ada/, 'a successful download still prints the plain NEW TG MEDIA line' );
    unlike( $out, qr/NEW TG MEDIA FAILED/, 'a successful download never prints the new FAILED event' );
    is( $err, '', 'a successful download prints nothing to STDERR' );
}

done_testing();
