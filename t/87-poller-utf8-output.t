use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Store;

package main;

# TGT-117 (direct observation, live poller log): a real inbound message
# containing non-Latin-1 script (a Cantonese voice-note transcript)
# triggered "Wide character in print at .../D2TG/Poller.pm line 83" -
# D2TG::Poller::run_once prints message text to whatever filehandle is
# currently selected as STDOUT, and does nothing itself to open that
# filehandle with a UTF-8 layer; that's cli/poller.pl's job at process
# startup. A plain in-memory scalar filehandle (opened the same way
# t/73's own capture_std helper does, with no encoding layer at all) is
# exactly the same shape STDOUT has before cli/poller.pl's fix is
# applied, so it reproduces the warning without needing a real process.

sub capture_std_and_warnings {
    my ($code) = @_;
    my ( $out, $err, @warnings ) = ( '', '', () );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $code->();
    select $old_out;
    return ( $out, $err, \@warnings );
}

{
    package Fake::Telegram::Cantonese;
    sub new { return bless {}, shift; }
    sub get_updates {
        my $updates = [ {
            message => {
                message_id => 7,
                chat       => { id => 999 },
                from       => { username => 'owner' },
                text       => "\x{5ec9}\x{4ef7}\x{7269}\x{6599}", # real Cantonese text
            },
        } ];
        return ( $updates, 8 );
    }

    package main;
}

# RED (against a STDOUT filehandle with no UTF-8 layer, matching what
# cli/poller.pl leaves STDOUT as before this ticket's fix): printing the
# Cantonese message text triggers "Wide character in print".
{
    my $tg    = Fake::Telegram::Cantonese->new;
    my $store = Fake::Store->new( allowed => [999] );

    my ( $out, $err, $warnings ) = capture_std_and_warnings( sub {
        D2TG::Poller::run_once( $tg, 42, $store );
    } );

    ok( ( grep { /Wide character in print/ } @$warnings ),
        'printing non-Latin-1 text to a filehandle with no UTF-8 layer warns (reproduces TGT-117)' );
    like( $out, qr/NEW TG \[999\] owner:/, 'the message is still printed despite the warning' );
}

# GREEN (against a STDOUT filehandle with the ':encoding(UTF-8)' layer
# applied - exactly the fix cli/poller.pl now applies at startup): the
# same print produces no warning at all.
{
    my $tg    = Fake::Telegram::Cantonese->new;
    my $store = Fake::Store->new( allowed => [999] );

    my $out = '';
    open my $out_fh, '>:encoding(UTF-8)', \$out or die $!;
    my $old_out = select $out_fh;
    $| = 1;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    D2TG::Poller::run_once( $tg, 42, $store );
    select $old_out;
    close $out_fh;

    is_deeply( \@warnings, [], 'no warning at all once STDOUT carries a UTF-8 layer (the fix)' );
    like( $out, qr/NEW TG \[999\] owner:/, 'the message is still printed correctly with the layer applied' );
}

# Confirm cli/poller.pl itself actually applies the fix (the ticket's
# declared scope: cli/poller.pl's STDOUT encoding layer only).
{
    local $/;
    open my $fh, '<', "$Bin/../cli/poller.pl" or die $!;
    my $source = <$fh>;
    like( $source, qr/binmode\s+STDOUT\s*,\s*['"]:encoding\(UTF-8\)['"]/,
        'cli/poller.pl opens STDOUT with an explicit UTF-8 layer' );
}

done_testing();
