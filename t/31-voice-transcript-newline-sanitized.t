use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller;
require Fake::Telegram;
require Fake::Store;

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
                update_id => 210,
                message   => {
                    message_id => 900,
                    chat       => { id => 999 },
                    from       => { username => 'ada' },
                    voice      => { file_id => 'nl1' },
                },
            },
        ],
    );
    my $store = Fake::Store->new( allowed => [999] );
    my $transcribe_voice = sub { return "first sentence.\nsecond sentence." };

    my $out = capture_stdout( sub {
        D2TG::Poller::run_once( $tg, undef, $store, transcribe_voice => $transcribe_voice );
    } );

    my @lines = split /\n/, $out;
    is( scalar(@lines), 2, 'a transcript with an embedded newline still produces exactly one NEW TG VOICE line plus one REPLY WITH line' );
    like( $lines[0], qr/first sentence\.\\nsecond sentence\./, 'the embedded newline is escaped to a literal backslash-n, not left as a real newline' );

    my $stored = $store->get_message( 999, 900 );
    is( $stored->{summary}, 'first sentence.\nsecond sentence.', 'the stored summary is also sanitized (literal backslash-n), matching what was printed' );
}

done_testing();
