use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use D2TG::Telegram;

package Fake::UA;
sub new { return bless { calls => 0 }, shift }
sub timeout { return 5 }
sub request {
    my $self = shift;
    $self->{calls}++;
    die "Fake::UA::request should never be called for a rejected reply_to_message_id\n";
}

package main;

my $ua = Fake::UA->new;
my $telegram = D2TG::Telegram->new( token => '123:fake', ua => $ua );

eval { $telegram->send_message( 42, 'hi', undef, reply_to_message_id => 'not-a-number' ) };
like( $@, qr/sendMessage: reply_to_message_id must be numeric/, 'send_message dies on non-numeric reply_to_message_id' );
is( $ua->{calls}, 0, 'no HTTP request attempted when reply_to_message_id is invalid' );

done_testing();
