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
    my $too_big = 21 * 1024 * 1024;    # 21MB, over Telegram's 20MB getFile limit
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 400,
                message   => {
                    chat     => { id => 999 },
                    from     => { username => 'ada' },
                    document => { file_id => 'bigdoc', file_size => $too_big },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return '/tmp/bigdoc.bin'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is_deeply( \@calls, [], 'download_media is never called for a file over the 20MB getFile limit' );
    like( $err, qr/MEDIA DOWNLOAD ERROR.*too large/i, 'a clear, specific too-large error is reported on stderr' );
    like( $err, qr/20\s*MB/i, 'the error names the 20MB limit' );
}

{
    my $ok_size = 5 * 1024 * 1024;    # 5MB, well under the limit
    my $tg = Fake::Telegram->new(
        [
            {
                update_id => 401,
                message   => {
                    chat     => { id => 999 },
                    from     => { username => 'ada' },
                    document => { file_id => 'normaldoc', file_size => $ok_size },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my @calls;
    my $download_media = sub { my ( $telegram, $file_id ) = @_; push @calls, $file_id; return '/tmp/normaldoc.bin'; };

    my ( $out, $err ) = capture_std( sub {
        D2TG::Poller::run_once( $tg, undef, $store, download_media => $download_media );
    } );

    is_deeply( \@calls, ['normaldoc'], 'a normal-sized file is still downloaded as before' );
    is( $err, '', 'nothing is printed to stderr for a normal-sized file' );
}

done_testing();
